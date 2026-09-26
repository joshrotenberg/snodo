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
  fail with -32000. Server-to-client requests are answered with -32601, and
  server notifications are dropped.

  `close/1` closes the server's stdin. An MCP stdio server exits at EOF after
  finishing admitted requests; this transport does not signal or kill it.
  """

  @behaviour Snodo.Client.Transport
  use GenServer

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

    with {:ok, executable} <- find_executable(command) do
      port_options = port_options(args, opts)
      init_arg = {executable, port_options, self(), max_line_bytes}

      case GenServer.start(__MODULE__, init_arg) do
        {:ok, pid} -> {:ok, pid}
        {:error, %Error{} = error} -> {:error, error}
      end
    end
  end

  @impl Transport
  def request(pid, message, opts) when is_pid(pid) and is_map(message) do
    GenServer.call(pid, {:request, message, Keyword.fetch!(opts, :timeout)}, :infinity)
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
  def init({executable, port_options, owner, max_line_bytes}) do
    port = Port.open({:spawn_executable, executable}, port_options)

    {:ok,
     %{
       port: port,
       owner: Process.monitor(owner),
       pending: %{},
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
  def handle_call({:request, _message, _timeout}, _from, %{closed: %Error{} = error} = state) do
    {:reply, {:error, error}, state}
  end

  def handle_call({:request, %{"id" => id} = message, timeout}, from, state) do
    case write(state.port, message) do
      :ok ->
        timer = start_timer(id, timeout)
        {:noreply, put_in(state, [:pending, id], {from, timer, timeout})}

      {:error, error} ->
        {:reply, {:error, error}, state}
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

    for {_id, {from, timer, _timeout}} <- state.pending do
      cancel_timer(timer)
      GenServer.reply(from, {:error, error})
    end

    {:noreply, %{state | pending: %{}, closed: error}}
  end

  def handle_info({:request_timeout, id}, state) do
    case Map.pop(state.pending, id) do
      {nil, _pending} ->
        {:noreply, state}

      {{from, _timer, timeout}, pending} ->
        GenServer.reply(from, {:error, Transport.timeout_error(timeout)})
        _result = write(state.port, cancellation(id))
        {:noreply, %{state | pending: pending}}
    end
  end

  def handle_info({:DOWN, ref, :process, _owner, _reason}, %{owner: ref} = state) do
    {:stop, :normal, state}
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
      {:ok, %{"id" => id, "method" => method}} ->
        _result = write(state.port, method_not_found(id, method))
        state

      {:ok, %{"id" => id} = response} ->
        complete(state, id, response)

      # Notifications and lines that are not JSON-RPC are dropped.
      _other ->
        state
    end
  end

  defp complete(state, id, response) do
    case Map.pop(state.pending, id) do
      {nil, _pending} ->
        state

      {{from, timer, _timeout}, pending} ->
        cancel_timer(timer)
        GenServer.reply(from, {:ok, response})
        %{state | pending: pending}
    end
  end

  defp write(port, message) do
    true = Port.command(port, Framing.encode_message(message))
    :ok
  rescue
    ArgumentError ->
      {:error, Transport.connection_error("The stdio server is not accepting input", :closed)}
  end

  defp cancellation(id) do
    %{
      "jsonrpc" => "2.0",
      "method" => "notifications/cancelled",
      "params" => %{"requestId" => id, "reason" => "Request timed out"}
    }
  end

  defp method_not_found(id, method) do
    %{
      "jsonrpc" => "2.0",
      "id" => id,
      "error" => Error.to_json_rpc(Error.method_not_found(method))
    }
  end

  defp start_timer(_id, :infinity), do: nil
  defp start_timer(id, timeout), do: Process.send_after(self(), {:request_timeout, id}, timeout)

  defp cancel_timer(nil), do: :ok

  defp cancel_timer(timer) do
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
