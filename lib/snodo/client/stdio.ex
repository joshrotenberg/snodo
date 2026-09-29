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
    * `:on_server_request` - a function of one argument that answers a
      request the server sends to the client, as `Snodo.Client.Transport`
      describes. The connection process runs it in a process it owns, one per
      request, and writes the response it returns; a function that raises is
      answered with -32603. Without it, server-to-client requests are
      answered with -32601.

  The connection process monitors the process that called `connect/2` and
  closes when it exits. When a request times out, the transport answers the
  caller with a -32001 error and sends the server `notifications/cancelled` for
  that request ID. When the server exits, requests in flight and later requests
  fail with -32000. `notify/3` writes a notification and returns once the
  line is in the port.

  A `notifications/progress` whose token belongs to a request made with
  `progress:` is forwarded to the process waiting on that request, which calls
  the progress function; with `reset_timeout_on_progress: true` the connection
  process also restarts the request's timer. Other server notifications are
  dropped. If the progress function raises, the request is cancelled on the
  server.

  `close/1` closes the server's stdin. An MCP stdio server exits at EOF after
  finishing admitted requests; this transport does not signal or kill it.
  """

  @behaviour Snodo.Client.Transport
  use GenServer

  alias Snodo.Client.Deadline
  alias Snodo.Client.Transport
  alias Snodo.Error
  alias Snodo.Transport.Stdio.Framing

  @line_bytes 65_536
  @default_max_line_bytes 16 * 1024 * 1024

  @impl Transport
  def connect({command, args}, opts) when is_binary(command) and is_list(args) do
    max_line_bytes = Keyword.get(opts, :max_line_bytes, @default_max_line_bytes)

    unless is_integer(max_line_bytes) and max_line_bytes > 0 do
      raise ArgumentError, ":max_line_bytes must be a positive integer"
    end

    responder = Keyword.get(opts, :on_server_request)

    unless is_nil(responder) or is_function(responder, 1) do
      raise ArgumentError, ":on_server_request must be a function of one argument"
    end

    with {:ok, executable} <- find_executable(command) do
      port_options = port_options(args, opts)
      init_arg = {executable, port_options, self(), max_line_bytes, responder}

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
      case submit(pid, message, reply_to, opts) do
        :ok -> await(pid, message["id"], reply_to, monitor, on_progress)
        {:error, %Error{}} = error -> error
      end
    after
      Process.unalias(reply_to)
      Process.demonitor(monitor, [:flush])
    end
  end

  @impl Transport
  def notify(pid, message, _opts) when is_pid(pid) and is_map(message) do
    GenServer.call(pid, {:notify, message}, :infinity)
  catch
    :exit, reason ->
      {:error, Transport.connection_error("The stdio connection is closed", reason)}
  end

  @impl Transport
  def close(pid) when is_pid(pid) do
    GenServer.stop(pid, :normal)
  catch
    :exit, _reason -> :ok
  end

  @impl GenServer
  def init({executable, port_options, owner, max_line_bytes, responder}) do
    port = Port.open({:spawn_executable, executable}, port_options)

    {:ok,
     %{
       port: port,
       owner: Process.monitor(owner),
       pending: %{},
       tokens: %{},
       buffer: [],
       buffer_bytes: 0,
       discarding?: false,
       max_line_bytes: max_line_bytes,
       responder: responder,
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

  def handle_call({:notify, _message}, _from, %{closed: %Error{}} = state) do
    {:reply, {:error, state.closed}, state}
  end

  def handle_call({:notify, message}, _from, state) do
    {:reply, write(state.port, message), state}
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

    {:noreply, %{state | pending: %{}, tokens: %{}, closed: error}}
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

  def handle_info({:DOWN, ref, :process, _owner, _reason}, %{owner: ref} = state) do
    {:stop, :normal, state}
  end

  # The answer to a server request, from the process that ran the responder.
  # After the server exited there is nowhere to write it.
  def handle_info({:server_response, response}, state) do
    if is_nil(state.closed), do: _result = write(state.port, response)
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl GenServer
  def terminate(_reason, state) do
    if is_nil(state.closed), do: close_port(state.port)
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
      {:ok, %{"id" => id, "method" => method} = request} when is_binary(method) ->
        answer_server_request(state, id, request)

      {:ok, %{"id" => id} = response} ->
        complete(state, id, response)

      {:ok,
       %{"method" => "notifications/progress", "params" => %{"progressToken" => token} = params}}
      when is_map_key(state.tokens, token) ->
        progress(state, state.tokens[token], params)

      # Other notifications and lines that are not JSON-RPC are dropped.
      _other ->
        state
    end
  end

  # The responder runs a handler the application installed, so it runs in its
  # own process: a slow handler must not stall the reader, and one that raises
  # must not take the connection down. The process is linked to the
  # connection, so it does not outlive it.
  defp answer_server_request(%{responder: nil} = state, id, %{"method" => method}) do
    _result = write(state.port, method_not_found(id, method))
    state
  end

  defp answer_server_request(%{responder: responder} = state, id, request) do
    connection = self()

    _pid =
      spawn_link(fn ->
        response =
          try do
            responder.(request)
          rescue
            exception -> handler_failed(id, Exception.message(exception))
          catch
            kind, reason -> handler_failed(id, Exception.format_banner(kind, reason))
          end

        send(connection, {:server_response, response})
      end)

    state
  end

  defp handler_failed(id, detail) do
    %{
      "jsonrpc" => "2.0",
      "id" => id,
      "error" => Error.to_json_rpc(Error.internal("Input handler failed: " <> detail))
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

  defp submit(pid, message, reply_to, opts) do
    GenServer.call(pid, {:request, message, reply_to, opts}, :infinity)
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
