defmodule Snodo.Client.Stdio do
  @moduledoc """
  Stdio transport for `Snodo.Client.connect({:stdio, command, args}, opts)`.

  A process owns a `Port` running `command`. It writes one JSON-RPC message per
  line to the server's stdin and reads newline-delimited messages from its
  stdout. The server's stderr is not captured. Responses are correlated by ID,
  so any number of processes can share one client and have requests in flight
  at once.

  Options:

    * `:env` - extra environment variables, as `{name, value}` string pairs.
      A `nil` value unsets the variable.
    * `:cd` - the working directory for the command.
    * `:max_line_bytes` - the largest response line to accept, default 16 MiB.
      The rest of a longer line is discarded as it arrives, so the request it
      answered times out; later responses are unaffected.

  The connection process monitors the process that called `connect/2` and
  closes when it exits. When a request times out, the transport answers the
  caller with a -32001 error and sends the server `notifications/cancelled` for
  that request ID. When the server exits, requests in flight and later requests
  fail with -32000. Server-to-client requests are answered with -32601.

  A `notifications/progress` whose token belongs to a request made with
  `progress:` is forwarded to the process waiting on that request, which calls
  the progress function; with `reset_timeout_on_progress: true` the connection
  process also restarts the request's timer. Other server notifications are
  dropped. If the progress function raises, the request is cancelled on the
  server.

  A `subscriptions/listen` request opened with `Snodo.Client.listen/3` shares
  the connection with ordinary requests. The connection process correlates
  the acknowledgement, the events, and the terminal response by the
  subscription ID (the request ID, carried in each notification's
  `_meta["io.modelcontextprotocol/subscriptionId"]`), delivers the events to
  the owner (see `Snodo.Client.Subscription`), and monitors the owner. Closing
  the subscription, or the owner's exit, sends `notifications/cancelled` for
  the request. When the server exits, or `close/1` stops the connection, open
  subscriptions end with a -32000 error.

  `close/1` closes the server's stdin. An MCP stdio server exits at EOF after
  finishing admitted requests; this transport does not signal or kill it.
  """

  @behaviour Snodo.Client.Transport
  use GenServer

  alias Snodo.Client.Deadline
  alias Snodo.Client.Response
  alias Snodo.Client.Subscription.Buffer
  alias Snodo.Client.Transport
  alias Snodo.Error
  alias Snodo.Transport.Stdio.Framing

  @line_bytes 65_536
  @default_max_line_bytes 16 * 1024 * 1024
  @subscription_id_key "io.modelcontextprotocol/subscriptionId"
  @acknowledgement "notifications/subscriptions/acknowledged"
  @closed_by_client "Closed by the client"

  @impl Transport
  def connect({command, args}, opts) when is_binary(command) and is_list(args) do
    max_line_bytes = Keyword.get(opts, :max_line_bytes, @default_max_line_bytes)

    unless is_integer(max_line_bytes) and max_line_bytes > 0 do
      raise ArgumentError, ":max_line_bytes must be a positive integer"
    end

    with {:ok, executable} <- find_executable(command) do
      port_options = port_options(args, opts)
      init_arg = {executable, port_options, self(), max_line_bytes}

      case GenServer.start(__MODULE__, init_arg) do
        {:ok, pid} -> {:ok, pid}
        {:error, %Error{} = error} -> {:error, error}
      end
    end
  end

  # The caller waits for its response in its own receive loop rather than in
  # GenServer.call, so that it can run the progress function as notifications
  # arrive. Replies go to a process alias, which is removed when the request
  # returns, so a late message cannot reach the caller's mailbox.
  @impl Transport
  def request(pid, message, opts) when is_pid(pid) and is_map(message) do
    on_progress = Keyword.get(opts, :on_progress)
    reply_to = Process.alias()
    monitor = Process.monitor(pid)

    try do
      case submit(pid, {:request, message, reply_to, opts}) do
        :ok -> await(pid, message["id"], reply_to, monitor, on_progress)
        {:error, %Error{}} = error -> error
      end
    after
      Process.unalias(reply_to)
      Process.demonitor(monitor, [:flush])
    end
  end

  # The acknowledgement is awaited the way a response is. Once it arrives the
  # connection process delivers the stream to the owner on its own.
  @impl Transport
  def listen(pid, message, opts) when is_pid(pid) and is_map(message) do
    reply_to = Process.alias()
    monitor = Process.monitor(pid)

    try do
      case submit(pid, {:listen, message, reply_to, opts}) do
        :ok ->
          receive do
            {^reply_to, {:acknowledged, accepted}} ->
              {:ok, accepted, pid}

            {^reply_to, {:response, {:error, %Error{} = error}}} ->
              {:error, error}

            {:DOWN, ^monitor, :process, _pid, reason} ->
              {:error, Transport.connection_error("The stdio connection is closed", reason)}
          end

        {:error, %Error{}} = error ->
          error
      end
    after
      Process.unalias(reply_to)
      Process.demonitor(monitor, [:flush])
    end
  end

  @impl Transport
  def close(pid) when is_pid(pid) do
    GenServer.stop(pid, :normal)
  catch
    :exit, _reason -> :ok
  end

  @impl GenServer
  def init({executable, port_options, owner, max_line_bytes}) do
    port = Port.open({:spawn_executable, executable}, port_options)

    {:ok,
     %{
       port: port,
       owner: Process.monitor(owner),
       pending: %{},
       tokens: %{},
       subscriptions: %{},
       subscription_refs: %{},
       subscription_owners: %{},
       buffer: [],
       buffer_bytes: 0,
       discarding?: false,
       max_line_bytes: max_line_bytes,
       closed: nil
     }}
  rescue
    exception ->
      {:stop, Transport.connection_error("Could not start the stdio server", exception)}
  end

  @impl GenServer
  def handle_call({:request, _message, _reply_to, _opts}, _from, %{closed: %Error{}} = state) do
    {:reply, {:error, state.closed}, state}
  end

  def handle_call({:listen, _message, _reply_to, _opts}, _from, %{closed: %Error{}} = state) do
    {:reply, {:error, state.closed}, state}
  end

  def handle_call({:listen, %{"id" => id} = message, reply_to, opts}, _from, state) do
    case write(state.port, message) do
      :ok ->
        owner = Keyword.fetch!(opts, :owner)
        ref = Keyword.fetch!(opts, :ref)
        owner_monitor = Process.monitor(owner)

        entry = %{
          ref: ref,
          owner_monitor: owner_monitor,
          buffer: Buffer.new(owner, ref, opts),
          awaiting:
            start_timer(%{reply_to: reply_to, deadline: Deadline.new(opts)}, {:listen, id})
        }

        state =
          state
          |> put_in([:subscriptions, id], entry)
          |> put_in([:subscription_refs, ref], id)
          |> put_in([:subscription_owners, owner_monitor], id)

        {:reply, :ok, state}

      {:error, error} ->
        {:reply, {:error, error}, state}
    end
  end

  def handle_call({:mcp_client_close, ref}, _from, state) do
    case Map.fetch(state.subscription_refs, ref) do
      {:ok, id} -> {:reply, :ok, cancel_subscription(state, id)}
      :error -> {:reply, :ok, state}
    end
  end

  def handle_call({:request, %{"id" => id} = message, reply_to, opts}, _from, state) do
    case write(state.port, message) do
      :ok ->
        token =
          if Keyword.has_key?(opts, :on_progress),
            do: get_in(message, ["params", "_meta", "progressToken"])

        entry =
          %{reply_to: reply_to, token: token, deadline: Deadline.new(opts)}
          |> start_timer(id)

        state = put_in(state, [:pending, id], entry)
        state = if token, do: put_in(state, [:tokens, token], id), else: state
        {:reply, :ok, state}

      {:error, error} ->
        {:reply, {:error, error}, state}
    end
  end

  @impl GenServer
  def handle_cast({:abandon, id, reply_to}, state) do
    case state.pending do
      %{^id => %{reply_to: ^reply_to}} ->
        _result = write(state.port, cancellation(id, "The client stopped waiting"))
        {_entry, state} = pop_pending(state, id)
        {:noreply, state}

      _other ->
        {:noreply, state}
    end
  end

  @impl GenServer
  def handle_info({port, {:data, {:noeol, chunk}}}, %{port: port} = state) do
    {:noreply, append(state, chunk)}
  end

  def handle_info({port, {:data, {:eol, chunk}}}, %{port: port} = state) do
    state = append(state, chunk)
    line = IO.iodata_to_binary(state.buffer)
    discarded? = state.discarding?
    state = %{state | buffer: [], buffer_bytes: 0, discarding?: false}

    {:noreply, if(discarded?, do: state, else: handle_line(state, line))}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    error = Transport.connection_error("The stdio server exited", {:exit_status, status})

    for {_id, entry} <- state.pending do
      cancel_timer(entry)
      deliver(entry, {:response, {:error, error}})
    end

    state =
      Enum.reduce(Map.keys(state.subscriptions), state, fn id, state ->
        end_subscription(state, id, {:error, error})
      end)

    {:noreply, %{state | pending: %{}, tokens: %{}, closed: error}}
  end

  def handle_info({:request_timeout, {:listen, id}, tag}, state) do
    case state.subscriptions do
      %{^id => %{awaiting: %{timer: {_timer, ^tag}} = awaiting}} ->
        deliver(awaiting, {:response, {:error, Deadline.error(awaiting.deadline)}})
        _result = write(state.port, cancellation(id, "Request timed out"))
        {:noreply, remove_subscription(state, id)}

      _other ->
        {:noreply, state}
    end
  end

  # A timer that was restarted may already have fired, so the tag must match.
  def handle_info({:request_timeout, id, tag}, state) do
    case state.pending do
      %{^id => %{timer: {_timer, ^tag}} = entry} ->
        deliver(entry, {:response, {:error, Deadline.error(entry.deadline)}})
        _result = write(state.port, cancellation(id, "Request timed out"))
        {_entry, state} = pop_pending(state, id)
        {:noreply, state}

      _other ->
        {:noreply, state}
    end
  end

  def handle_info({:mcp_client_demand, ref, n}, state) do
    case Map.fetch(state.subscription_refs, ref) do
      {:ok, id} ->
        entry = Map.fetch!(state.subscriptions, id)
        {:noreply, put_subscription(state, id, %{entry | buffer: Buffer.demand(entry.buffer, n)})}

      :error ->
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, ref, :process, _owner, _reason}, %{owner: ref} = state) do
    {:stop, :normal, state}
  end

  def handle_info({:DOWN, monitor, :process, _owner, _reason}, state)
      when is_map_key(state.subscription_owners, monitor) do
    {:noreply, cancel_subscription(state, Map.fetch!(state.subscription_owners, monitor))}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl GenServer
  def terminate(_reason, state) do
    if is_nil(state.closed), do: close_port(state.port)
    error = Transport.connection_error("The stdio connection is closed", :closed)

    for {_id, entry} <- state.subscriptions do
      if entry.awaiting, do: deliver(entry.awaiting, {:response, {:error, error}})
      _buffer = Buffer.abort(entry.buffer, {:error, error})
    end

    :ok
  end

  # Once a line passes the limit, its remaining chunks are dropped as they
  # arrive instead of being held until the newline.
  defp append(%{discarding?: true} = state, _chunk), do: state

  defp append(state, chunk) do
    bytes = state.buffer_bytes + byte_size(chunk)

    if bytes > state.max_line_bytes,
      do: %{state | buffer: [], buffer_bytes: 0, discarding?: true},
      else: %{state | buffer: [state.buffer, chunk], buffer_bytes: bytes}
  end

  defp handle_line(state, line) do
    case Framing.decode_line(line) do
      {:ok, %{"id" => id, "method" => method}} ->
        _result = write(state.port, method_not_found(id, method))
        state

      {:ok, %{"id" => id} = response} when is_map_key(state.subscriptions, id) ->
        subscription_response(state, id, response)

      {:ok, %{"id" => id} = response} ->
        complete(state, id, response)

      {:ok,
       %{"method" => method, "params" => %{"_meta" => %{@subscription_id_key => id}} = params}}
      when is_map_key(state.subscriptions, id) ->
        subscription_notification(state, id, method, params)

      {:ok,
       %{"method" => "notifications/progress", "params" => %{"progressToken" => token} = params}}
      when is_map_key(state.tokens, token) ->
        progress(state, state.tokens[token], params)

      # Other notifications and lines that are not JSON-RPC are dropped.
      _other ->
        state
    end
  end

  # The acknowledgement answers the waiting listen/3 call; anything else on
  # the stream after it is an event. An event before the acknowledgement is
  # queued for the owner all the same.
  defp subscription_notification(state, id, @acknowledgement, params) do
    entry = Map.fetch!(state.subscriptions, id)

    case {entry.awaiting, params} do
      {nil, _params} ->
        state

      {awaiting, %{"notifications" => accepted}} when is_map(accepted) ->
        cancel_timer(awaiting)
        deliver(awaiting, {:acknowledged, accepted})
        put_subscription(state, id, %{entry | awaiting: nil})

      {awaiting, _invalid} ->
        cancel_timer(awaiting)

        error =
          Transport.connection_error(
            "The server sent an invalid subscription acknowledgement",
            params
          )

        deliver(awaiting, {:response, {:error, error}})
        _result = write(state.port, cancellation(id, "Invalid acknowledgement"))
        remove_subscription(state, id)
    end
  end

  defp subscription_notification(state, id, method, params) do
    entry = Map.fetch!(state.subscriptions, id)
    buffer = Buffer.push(entry.buffer, {:notification, method, params})
    put_subscription(state, id, %{entry | buffer: buffer})
  end

  defp subscription_response(state, id, response) do
    case Map.fetch!(state.subscriptions, id) do
      %{awaiting: nil} ->
        end_subscription(state, id, Response.terminal(response))

      %{awaiting: awaiting} ->
        cancel_timer(awaiting)

        error =
          case Response.terminal(response) do
            {:error, error} ->
              error

            :complete ->
              Transport.connection_error(
                "The server ended the subscription before acknowledging it",
                response
              )
          end

        deliver(awaiting, {:response, {:error, error}})
        remove_subscription(state, id)
    end
  end

  # The server has finished; the entry stays until the owner has taken the
  # queued events and the terminal message.
  defp end_subscription(state, id, close_reason) do
    entry = Map.fetch!(state.subscriptions, id)

    if entry.awaiting do
      cancel_timer(entry.awaiting)
      deliver(entry.awaiting, {:response, {:error, closed_before_acknowledgement(close_reason)}})
      remove_subscription(state, id)
    else
      put_subscription(state, id, %{entry | buffer: Buffer.close(entry.buffer, close_reason)})
    end
  end

  defp closed_before_acknowledgement({:error, error}), do: error

  defp closed_before_acknowledgement(:complete) do
    Transport.connection_error("The server ended the subscription before acknowledging it", nil)
  end

  # A cancellation from this side: the owner closed the subscription or went
  # away. A stream the server has already ended needs no cancellation.
  defp cancel_subscription(state, id) do
    entry = Map.fetch!(state.subscriptions, id)

    unless Buffer.terminal?(entry.buffer) do
      if entry.awaiting, do: cancel_timer(entry.awaiting)
      _result = write(state.port, cancellation(id, @closed_by_client))
    end

    remove_subscription(state, id)
  end

  defp put_subscription(state, id, entry) do
    if Buffer.done?(entry.buffer),
      do: remove_subscription(state, id),
      else: put_in(state, [:subscriptions, id], entry)
  end

  defp remove_subscription(state, id) do
    {entry, subscriptions} = Map.pop!(state.subscriptions, id)
    Process.demonitor(entry.owner_monitor, [:flush])

    %{
      state
      | subscriptions: subscriptions,
        subscription_refs: Map.delete(state.subscription_refs, entry.ref),
        subscription_owners: Map.delete(state.subscription_owners, entry.owner_monitor)
    }
  end

  defp complete(state, id, response) do
    case pop_pending(state, id) do
      {nil, state} ->
        state

      {entry, state} ->
        deliver(entry, {:response, {:ok, response}})
        state
    end
  end

  defp progress(state, id, params) do
    entry = Map.fetch!(state.pending, id)
    deliver(entry, {:progress, params})
    deadline = Deadline.extend(entry.deadline)

    if deadline.at == entry.deadline.at do
      state
    else
      cancel_timer(entry)
      put_in(state, [:pending, id], start_timer(%{entry | deadline: deadline}, id))
    end
  end

  defp pop_pending(state, id) do
    case Map.pop(state.pending, id) do
      {nil, _pending} ->
        {nil, state}

      {entry, pending} ->
        cancel_timer(entry)
        {entry, %{state | pending: pending, tokens: Map.delete(state.tokens, entry.token)}}
    end
  end

  defp deliver(%{reply_to: reply_to}, message), do: send(reply_to, {reply_to, message})

  defp submit(pid, call) do
    GenServer.call(pid, call, :infinity)
  catch
    :exit, reason ->
      {:error, Transport.connection_error("The stdio connection is closed", reason)}
  end

  defp await(pid, id, reply_to, monitor, on_progress) do
    receive do
      {^reply_to, {:progress, params}} ->
        run_progress(pid, id, reply_to, on_progress, params)
        await(pid, id, reply_to, monitor, on_progress)

      {^reply_to, {:response, response}} ->
        response

      {:DOWN, ^monitor, :process, _pid, reason} ->
        {:error, Transport.connection_error("The stdio connection is closed", reason)}
    end
  end

  defp run_progress(pid, id, reply_to, on_progress, params) do
    on_progress.(params)
  catch
    kind, reason ->
      GenServer.cast(pid, {:abandon, id, reply_to})
      :erlang.raise(kind, reason, __STACKTRACE__)
  end

  defp write(port, message) do
    true = Port.command(port, Framing.encode_message(message))
    :ok
  rescue
    ArgumentError ->
      {:error, Transport.connection_error("The stdio server is not accepting input", :closed)}
  end

  defp cancellation(id, reason) do
    %{
      "jsonrpc" => "2.0",
      "method" => "notifications/cancelled",
      "params" => %{"requestId" => id, "reason" => reason}
    }
  end

  defp method_not_found(id, method) do
    %{
      "jsonrpc" => "2.0",
      "id" => id,
      "error" => Error.to_json_rpc(Error.method_not_found(method))
    }
  end

  defp start_timer(entry, id) do
    case Deadline.remaining(entry.deadline) do
      :infinity ->
        Map.put(entry, :timer, nil)

      remaining ->
        tag = make_ref()
        timer = Process.send_after(self(), {:request_timeout, id, tag}, remaining)
        Map.put(entry, :timer, {timer, tag})
    end
  end

  defp cancel_timer(%{timer: nil}), do: :ok

  defp cancel_timer(%{timer: {timer, _tag}}) do
    _remaining = Process.cancel_timer(timer)
    :ok
  end

  defp close_port(port) do
    Port.close(port)
  rescue
    ArgumentError -> true
  end

  defp find_executable(command) do
    path =
      if Path.type(command) == :absolute,
        do: command,
        else: System.find_executable(command)

    if is_binary(path) and File.regular?(path) do
      {:ok, path}
    else
      {:error, Transport.connection_error("Executable not found: #{command}", :enoent)}
    end
  end

  defp port_options(args, opts) do
    base = [:binary, :exit_status, :use_stdio, :hide, {:line, @line_bytes}, {:args, args}]

    base
    |> maybe_add(:cd, Keyword.get(opts, :cd), &String.to_charlist/1)
    |> maybe_add(:env, Keyword.get(opts, :env), &port_env/1)
  end

  defp maybe_add(options, _key, nil, _convert), do: options
  defp maybe_add(options, key, value, convert), do: [{key, convert.(value)} | options]

  defp port_env(env) do
    Enum.map(env, fn
      {name, nil} -> {String.to_charlist(name), false}
      {name, value} -> {String.to_charlist(name), String.to_charlist(value)}
    end)
  end
end
