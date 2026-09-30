defmodule Snodo.Transport.StreamableHTTP.Server do
  @moduledoc """
  Small dependency-free HTTP/1.1 listener for `Snodo.Transport.StreamableHTTP`.

  It is intentionally a binding, not a web framework. Each accepted connection
  carries one request and closes after one response. Header admission happens in
  the connection process; admitted MCP work runs through the reusable bounded
  `Snodo.Server.Executor`. A peer disconnect while work is pending cancels that
  execution and tears down its reply owner.

  `:request_timeout` bounds queue wait plus execution after HTTP admission; the
  transport's default ceiling is 30 seconds, including with an application-owned
  executor. Progress does not extend the deadline. Explicit `:infinity` disables
  this ceiling. Body reads and socket writes have their own transport bounds.

  Connection and stream bounds, each a positive integer:

    * `:max_connections` - the most connections open at once, default 1,024. A
      connection accepted at the limit is closed without being read.
    * `:head_timeout` - milliseconds from accept until the request head must be
      complete, default 10,000. `:read_timeout` (default 5,000) still bounds
      each read; this deadline bounds the whole head, so a client that sends it
      a byte at a time is closed when the deadline passes.
    * `:body_timeout` - milliseconds from the end of the head until the request
      body must be complete, default 10,000. Each body read returns what has
      arrived and waits at most `:read_timeout`; this deadline bounds the whole
      body, so a client that sends it a little at a time is closed when the
      deadline passes.
    * `:max_subscriptions` - the most `subscriptions/listen` streams open at
      once, default 256. The executor holds one count per listener and returns
      a slot when the connection serving that stream exits. A stream over the
      limit is closed at its source and the request gets 503.
    * `:drain_timeout` - milliseconds the listener waits on shutdown for open
      connections to finish, default 5,000.

  ## Shutdown

  The listener drains when it terminates, including when its supervisor stops
  it:

    1. The listening socket closes, so new connections are refused.
    2. A connection whose request head or body is still arriving gets 503 and
       closes. A request read in full before the drain began is admitted and
       runs to its response.
    3. Each open `subscriptions/listen` stream gets its successful completion
       response, its source is closed with reason `:shutdown`, and the
       connection closes.
    4. Connections still open when `:drain_timeout` passes are killed, which
       cancels their executor work and closes their subscription sources.
    5. An executor the listener started is stopped. An application-owned
       executor keeps running.

  `child_spec/1` sets the child's `:shutdown` to `:drain_timeout` plus 5,000
  ms, the default worker shutdown, so the supervisor does not kill the
  listener during the drain. A child spec that overrides `:shutdown` must keep
  it above `:drain_timeout`. A listener that is killed does not drain.

  Applications that already run Plug, Bandit, or Cowboy can translate their
  request into `Snodo.Transport.StreamableHTTP.Request` and use the pure adapter
  directly instead of starting this listener.
  """

  @behaviour Snodo.Transport
  use GenServer

  alias Snodo.Error
  alias Snodo.Progress
  alias Snodo.Server.Executor
  alias Snodo.Subscription
  alias Snodo.Transport.StreamableHTTP
  alias Snodo.Transport.StreamableHTTP.Request
  alias Snodo.Transport.StreamableHTTP.Response
  alias Snodo.Transport.StreamableHTTP.StreamResponse

  @default_ip {127, 0, 0, 1}
  @default_path "/mcp"
  @default_read_timeout 5_000
  @default_max_header_bytes 32_768
  @default_max_body_bytes 2_000_000
  @default_subscription_keepalive_ms 15_000
  @default_request_timeout 30_000
  @default_max_connections 1_024
  @default_head_timeout 10_000
  @default_body_timeout 10_000
  @default_max_subscriptions 256
  @default_drain_timeout 5_000
  # The supervisor's default worker shutdown, kept for the work after a drain.
  @shutdown_margin 5_000

  @impl true
  def start_link(opts) when is_list(opts) do
    GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))
  end

  @doc """
  Returns a worker child spec whose `:shutdown` exceeds `:drain_timeout` by
  5,000 ms. An invalid `:drain_timeout` is rejected when the listener starts.
  """
  def child_spec(opts) do
    drain_timeout =
      case Keyword.get(opts, :drain_timeout, @default_drain_timeout) do
        timeout when is_integer(timeout) and timeout > 0 -> timeout
        _invalid -> 0
      end

    %{
      id: Keyword.get(opts, :id, __MODULE__),
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      shutdown: drain_timeout + @shutdown_margin
    }
  end

  @doc "Returns the bound IP, actual port, and configured MCP endpoint path."
  @spec address(GenServer.server()) :: {:inet.ip_address(), :inet.port_number(), String.t()}
  def address(server), do: GenServer.call(server, :address)

  @doc "Returns a URL for a listener bound to a local IPv4 or IPv6 address."
  @spec url(GenServer.server()) :: String.t()
  def url(server) do
    {ip, port, path} = address(server)
    host = ip |> :inet.ntoa() |> to_string() |> bracket_ipv6()
    "http://#{host}:#{port}#{path}"
  end

  @impl true
  def init(opts) do
    _previous_trap_exit = Process.flag(:trap_exit, true)
    runtime = Keyword.fetch!(opts, :runtime)
    ip = normalize_ip(Keyword.get(opts, :ip, @default_ip))
    port = Keyword.get(opts, :port, 0)
    path = validate_path!(Keyword.get(opts, :path, @default_path))
    validate_port!(port)

    max_connections = positive_option!(opts, :max_connections, @default_max_connections)
    head_timeout = positive_option!(opts, :head_timeout, @default_head_timeout)
    body_timeout = positive_option!(opts, :body_timeout, @default_body_timeout)
    max_subscriptions = positive_option!(opts, :max_subscriptions, @default_max_subscriptions)
    drain_timeout = positive_option!(opts, :drain_timeout, @default_drain_timeout)

    listen_opts = [
      :binary,
      packet: :raw,
      active: false,
      send_timeout: 5_000,
      send_timeout_close: true,
      reuseaddr: true,
      ip: ip,
      backlog: Keyword.get(opts, :backlog, 128)
    ]

    with {:ok, listen_socket} <- :gen_tcp.listen(port, listen_opts),
         {:ok, {bound_ip, bound_port}} <- :inet.sockname(listen_socket),
         {:ok, connection_supervisor} <- Task.Supervisor.start_link(),
         {:ok, executor, owns_executor?} <- start_executor(opts) do
      executor_monitor = Process.monitor(executor)
      server_ref = make_ref()

      connection_opts = %{
        runtime: runtime,
        executor: executor,
        path: path,
        server_ref: server_ref,
        request_timeout: Keyword.get(opts, :request_timeout, :default),
        deadline_timeout: deadline_timeout!(Keyword.get(opts, :request_timeout, :default)),
        read_timeout: Keyword.get(opts, :read_timeout, @default_read_timeout),
        head_timeout: head_timeout,
        body_timeout: body_timeout,
        max_subscriptions: max_subscriptions,
        max_header_bytes: Keyword.get(opts, :max_header_bytes, @default_max_header_bytes),
        max_body_bytes: Keyword.get(opts, :max_body_bytes, @default_max_body_bytes),
        subscription_keepalive_ms:
          validate_keepalive!(
            Keyword.get(opts, :subscription_keepalive_ms, @default_subscription_keepalive_ms)
          ),
        adapter_opts:
          Keyword.take(opts, [
            :allowed_origin_hosts,
            :allowed_hosts
          ])
      }

      acceptor_state = %{
        listen_socket: listen_socket,
        supervisor: connection_supervisor,
        max_connections: max_connections,
        connections: 0,
        opts: connection_opts
      }

      acceptor = spawn_link(fn -> accept_loop(acceptor_state) end)

      {:ok,
       %{
         address: {bound_ip, bound_port, path},
         acceptor: acceptor,
         connection_supervisor: connection_supervisor,
         drain_timeout: drain_timeout,
         executor: executor,
         executor_monitor: executor_monitor,
         listen_socket: listen_socket,
         owns_executor?: owns_executor?,
         server_ref: server_ref
       }}
    end
  end

  @impl true
  def handle_call(:address, _from, state), do: {:reply, state.address, state}

  @impl true
  def handle_info(
        {:DOWN, monitor, :process, executor, reason},
        %{executor: executor, executor_monitor: monitor} = state
      ) do
    {:stop, {:executor_down, reason}, state}
  end

  def handle_info({:EXIT, acceptor, reason}, %{acceptor: acceptor} = state) do
    {:stop, {:acceptor_down, reason}, state}
  end

  def handle_info({:EXIT, executor, _reason}, %{executor: executor} = state),
    do: {:noreply, state}

  def handle_info({:EXIT, supervisor, _reason}, %{connection_supervisor: supervisor} = state),
    do: {:noreply, state}

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    _closed = :gen_tcp.close(state.listen_socket)
    deadline = System.monotonic_time(:millisecond) + state.drain_timeout
    :ok = drain_connections(state, deadline)
    Process.demonitor(state.executor_monitor, [:flush])

    if state.owns_executor?, do: stop_executor(state.executor)
    :ok
  end

  # Closing the listening socket ends the acceptor. Once it has exited no
  # connection can start, so the supervisor's children are every connection
  # left to drain. Connections still open at the deadline are killed; the
  # executor cancels work whose submitter died, and a subscription worker
  # closes its source when its owner dies.
  defp drain_connections(state, deadline) do
    :ok = await_acceptor(state.acceptor, deadline)
    connections = connection_pids(state.connection_supervisor)
    monitors = Map.new(connections, fn pid -> {Process.monitor(pid), pid} end)
    Enum.each(connections, &send(&1, {:mcp_http_drain, state.server_ref}))
    await_connections(monitors, deadline)
  end

  defp await_acceptor(acceptor, deadline) do
    monitor = Process.monitor(acceptor)

    receive do
      {:DOWN, ^monitor, :process, ^acceptor, _reason} -> :ok
    after
      remaining(deadline) ->
        Process.exit(acceptor, :kill)

        receive do
          {:DOWN, ^monitor, :process, ^acceptor, _reason} -> :ok
        end
    end
  end

  defp connection_pids(supervisor) do
    Task.Supervisor.children(supervisor)
  catch
    :exit, _reason -> []
  end

  defp await_connections(monitors, _deadline) when map_size(monitors) == 0, do: :ok

  defp await_connections(monitors, deadline) do
    receive do
      {:DOWN, monitor, :process, _pid, _reason} when is_map_key(monitors, monitor) ->
        await_connections(Map.delete(monitors, monitor), deadline)
    after
      remaining(deadline) -> kill_connections(monitors)
    end
  end

  defp kill_connections(monitors) do
    Enum.each(monitors, fn {monitor, pid} ->
      Process.exit(pid, :kill)

      receive do
        {:DOWN, ^monitor, :process, ^pid, _reason} -> :ok
      end
    end)
  end

  defp remaining(deadline), do: max(deadline - System.monotonic_time(:millisecond), 0)

  defp accept_loop(state) do
    case :gen_tcp.accept(state.listen_socket) do
      {:ok, socket} ->
        accepted_at = System.monotonic_time(:millisecond)
        state = reap_connections(state)
        accept_loop(admit_connection(state, socket, accepted_at))

      {:error, :closed} ->
        :ok

      {:error, reason} ->
        exit({:accept_failed, reason})
    end
  end

  # The acceptor monitors every connection process it starts, so the DOWN
  # messages waiting in its mailbox are exactly the connections that ended.
  defp reap_connections(state) do
    receive do
      {:DOWN, _monitor, :process, _pid, _reason} ->
        reap_connections(%{state | connections: state.connections - 1})
    after
      0 -> state
    end
  end

  defp admit_connection(%{connections: count, max_connections: max} = state, socket, _at)
       when count >= max do
    _closed = :gen_tcp.close(socket)
    state
  end

  defp admit_connection(state, socket, accepted_at) do
    case start_connection(state.supervisor, socket, accepted_at, state.opts) do
      {:ok, worker} ->
        _monitor = Process.monitor(worker)
        %{state | connections: state.connections + 1}

      :error ->
        state
    end
  end

  defp start_connection(supervisor, socket, accepted_at, opts) do
    opts = Map.put(opts, :head_deadline, accepted_at + opts.head_timeout)

    result =
      Task.Supervisor.start_child(supervisor, fn ->
        receive do
          {:serve_socket, accepted_socket} -> serve_socket(accepted_socket, opts)
        end
      end)

    case result do
      {:ok, worker} ->
        case :gen_tcp.controlling_process(socket, worker) do
          :ok ->
            send(worker, {:serve_socket, socket})
            {:ok, worker}

          {:error, _reason} ->
            _closed = :gen_tcp.close(socket)
            Process.exit(worker, :kill)
            :error
        end

      {:error, _reason} ->
        _closed = :gen_tcp.close(socket)
        :error
    end
  end

  defp serve_socket(socket, opts) do
    peer = peer_name(socket)
    connection_ref = make_ref()

    response =
      with {:ok, request} <- read_request(socket, peer, connection_ref, opts),
           :ok <- validate_endpoint(request, opts.path) do
        execute_request(socket, request, opts)
      else
        {:response, response} -> response
      end

    _send_result = maybe_send_response(socket, response, opts)
    _closed = :gen_tcp.close(socket)
    :ok
  catch
    _kind, _reason ->
      _closed = :gen_tcp.close(socket)
      :ok
  end

  defp execute_request(socket, request, opts) do
    case StreamableHTTP.prepare(opts.runtime, request, opts.adapter_opts) do
      {:response, response} ->
        response

      {:ok, prepared} ->
        sink = Progress.sink(self())
        prepared = put_in(prepared.transport.metadata[:progress_sink], sink)
        opts = Map.merge(opts, %{progress: Progress.state(sink), progress_started?: false})

        work = fn cancellation ->
          try do
            StreamableHTTP.execute(opts.runtime, prepared, cancellation)
          after
            Progress.close(sink)
          end
        end

        key = {:streamable_http, opts.server_ref, request.connection_ref}
        timer = start_request_timer(key, opts.deadline_timeout)

        try do
          case submit_execution(opts.executor, key, work, opts.request_timeout) do
            {:ok, execution_ref} ->
              await_execution(socket, opts.executor, execution_ref, key, prepared, opts)

            {:error, :overloaded} ->
              StreamableHTTP.reject(
                opts.runtime,
                prepared,
                Error.internal("Server execution capacity exhausted"),
                503
              )

            {:error, :duplicate_key} ->
              StreamableHTTP.reject(
                opts.runtime,
                prepared,
                Error.invalid_request("Duplicate in-flight HTTP request"),
                400
              )

            {:error, {:executor_unavailable, reason}} ->
              StreamableHTTP.reject(
                opts.runtime,
                prepared,
                Error.internal("Request executor unavailable", reason),
                500
              )
          end
        after
          Progress.close(sink)
          cancel_request_timer(timer, key)
        end
    end
  end

  defp await_execution(socket, executor, execution_ref, key, prepared, opts) do
    case :inet.setopts(socket, active: :once) do
      :ok ->
        await_execution_message(socket, executor, execution_ref, key, prepared, opts)

      {:error, reason} ->
        cancel_execution(executor, key, {:peer_unavailable, reason}, opts.progress.sink)
    end
  end

  defp await_execution_message(socket, executor, execution_ref, key, prepared, opts) do
    receive do
      {:mcp_execution, ^executor, ^execution_ref, ^key, outcome} ->
        :ok = Progress.close(opts.progress.sink)
        finish_execution(socket, execution_response(outcome, prepared, opts), opts)

      {:mcp_http_deadline, ^key} ->
        _cancelled = cancel_execution(executor, key, :request_timeout, opts.progress.sink)
        response = execution_response({:timed_out, opts.deadline_timeout}, prepared, opts)
        finish_execution(socket, response, opts)

      {:"$gen_call", from, {:mcp_progress, reference, report}} ->
        case receive_progress(socket, opts, reference, from, report) do
          {:ok, opts} ->
            await_execution_message(socket, executor, execution_ref, key, prepared, opts)

          {:error, reason} ->
            cancel_execution(executor, key, {:progress_write_failed, reason}, opts.progress.sink)
        end

      {:tcp_closed, ^socket} ->
        cancel_execution(executor, key, :peer_closed, opts.progress.sink)

      {:tcp_error, ^socket, reason} ->
        cancel_execution(executor, key, {:peer_error, reason}, opts.progress.sink)

      {:tcp, ^socket, _unexpected_data} ->
        await_execution(socket, executor, execution_ref, key, prepared, opts)
    end
  end

  defp receive_progress(socket, opts, reference, from, report) do
    result =
      if opts.progress.sink.reference == reference,
        do: Progress.accept(opts.progress, from, report),
        else: {:error, :wrong_sink}

    case result do
      {:ok, notification, progress} ->
        with :ok <- maybe_start_progress(socket, opts.progress_started?),
             :ok <- send_sse_message(socket, notification) do
          :ok = Progress.reply(from, report, :ok)
          {:ok, %{opts | progress: progress, progress_started?: true}}
        else
          {:error, reason} ->
            :ok = Progress.close(opts.progress.sink)
            :ok = Progress.reply(from, report, {:error, :closed})
            {:error, reason}
        end

      {:error, reason} ->
        :ok = Progress.reply(from, report, {:error, reason})
        {:ok, opts}
    end
  end

  defp maybe_start_progress(_socket, true), do: :ok

  defp maybe_start_progress(socket, false) do
    send_stream_headers(socket, 200, [
      {"content-type", "text/event-stream"},
      {"cache-control", "no-cache"},
      {"x-accel-buffering", "no"}
    ])
  end

  defp finish_execution(socket, %Response{body: body}, %{progress_started?: true}) do
    _send_result = :gen_tcp.send(socket, ["data: ", body, "\r\n\r\n"])
    nil
  end

  defp finish_execution(_socket, response, _opts), do: response

  defp execution_response({:completed, %Response{} = response}, _prepared, _opts), do: response

  defp execution_response({:completed, %StreamResponse{} = response}, prepared, opts) do
    case acquire_subscription_slot(opts) do
      :ok ->
        %{response | keepalive_ms: opts.subscription_keepalive_ms}

      {:error, :exhausted} ->
        :ok = Subscription.close(response.subscription, {:error, :overloaded})

        StreamableHTTP.reject(
          opts.runtime,
          prepared,
          Error.internal("Server subscription capacity exhausted"),
          503
        )

      {:error, {:executor_unavailable, reason}} ->
        :ok = Subscription.close(response.subscription, {:error, :executor_unavailable})

        StreamableHTTP.reject(
          opts.runtime,
          prepared,
          Error.internal("Request executor unavailable", reason),
          500
        )
    end
  end

  defp execution_response({:timed_out, _timeout}, prepared, opts) do
    StreamableHTTP.reject(
      opts.runtime,
      prepared,
      Error.internal("Request execution timed out"),
      504
    )
  end

  defp execution_response({:failed, reason}, prepared, opts) do
    StreamableHTTP.reject(
      opts.runtime,
      prepared,
      Error.internal("Request worker failed", reason),
      500
    )
  end

  # Matches the Plug adapter. After a disconnect the write simply fails.
  defp execution_response({:cancelled, _reason}, _prepared, _opts), do: %Response{status: 204}

  defp execution_response(_invalid, prepared, opts) do
    StreamableHTTP.reject(
      opts.runtime,
      prepared,
      Error.internal("Request worker returned an invalid result"),
      500
    )
  end

  defp read_request(socket, peer, connection_ref, opts) do
    with {:ok, head, rest} <- recv_head(socket, "", opts),
         body_deadline = System.monotonic_time(:millisecond) + opts.body_timeout,
         {:ok, method, target, headers, content_length} <-
           parse_request_head(head, opts.max_body_bytes),
         {:ok, body} <- recv_body(socket, rest, content_length, body_deadline, opts) do
      {:ok,
       %Request{
         method: method,
         path: request_path(target),
         headers: headers,
         body: body,
         peer: peer,
         connection_ref: connection_ref
       }}
    else
      {:error, status, message} ->
        {:response, basic_error(status, message)}

      {:error, :draining} ->
        {:response, basic_error(503, "Server is shutting down", -32_603)}

      {:error, _socket_reason} ->
        {:response, basic_error(400, "Failed to read HTTP request")}
    end
  end

  defp recv_head(_socket, acc, opts) when byte_size(acc) > opts.max_header_bytes,
    do: {:error, 431, "HTTP request headers are too large"}

  defp recv_head(socket, acc, opts) do
    case :binary.match(acc, "\r\n\r\n") do
      {index, 4} ->
        head = binary_part(acc, 0, index)
        rest_start = index + 4
        rest = binary_part(acc, rest_start, byte_size(acc) - rest_start)
        {:ok, head, rest}

      :nomatch ->
        with {:ok, chunk} <- recv_head_chunk(socket, opts) do
          recv_head(socket, acc <> chunk, opts)
        end
    end
  end

  # The head deadline covers the whole head, so a client cannot extend it by
  # sending one byte per `:read_timeout`.
  defp recv_head_chunk(socket, opts) do
    remaining = opts.head_deadline - System.monotonic_time(:millisecond)

    if remaining > 0,
      do: recv_chunk(socket, min(remaining, opts.read_timeout), opts.server_ref),
      else: {:error, :timeout}
  end

  # Request reads are active-once rather than blocking `recv` calls, so the
  # drain signal reaches a connection whose request has not fully arrived.
  defp recv_chunk(socket, timeout, server_ref) do
    case arm_socket(socket) do
      :ok -> await_chunk(socket, timeout, server_ref)
      {:error, reason} -> {:error, reason}
    end
  end

  defp await_chunk(socket, timeout, server_ref) do
    receive do
      {:tcp, ^socket, data} -> {:ok, data}
      {:tcp_closed, ^socket} -> {:error, :closed}
      {:tcp_error, ^socket, reason} -> {:error, reason}
      {:mcp_http_drain, ^server_ref} -> {:error, :draining}
    after
      timeout -> disarm_socket(socket)
    end
  end

  # Data that arrived as the timer fired is still a completed read.
  defp disarm_socket(socket) do
    _result = :inet.setopts(socket, active: false)

    receive do
      {:tcp, ^socket, data} -> {:ok, data}
    after
      0 -> {:error, :timeout}
    end
  end

  @doc false
  # Parses a request head, without its final blank line, into the method,
  # target, headers, and body length, or a 4xx status and message. The
  # property tests call it directly, because a raise here reaches the peer only
  # as a closed connection.
  @spec parse_request_head(binary(), non_neg_integer()) ::
          {:ok, String.t(), String.t(), [{String.t(), String.t()}], non_neg_integer()}
          | {:error, 400..499, String.t()}
  def parse_request_head(head, max_body_bytes) do
    with {:ok, method, target, headers} <- parse_head(head),
         {:ok, content_length} <- content_length(method, headers, max_body_bytes) do
      {:ok, method, target, headers, content_length}
    end
  end

  defp parse_head(head) do
    case :binary.split(head, "\r\n", [:global]) do
      [request_line | header_lines] ->
        with {:ok, method, target} <- parse_request_line(request_line),
             {:ok, headers} <- parse_headers(header_lines) do
          {:ok, method, target, headers}
        end

      _invalid ->
        {:error, 400, "Malformed HTTP request"}
    end
  end

  defp parse_request_line(line) do
    case String.split(line, " ", trim: true) do
      [method, target, version] when version in ["HTTP/1.1", "HTTP/1.0"] ->
        {:ok, String.upcase(method), target}

      _invalid ->
        {:error, 400, "Malformed HTTP request line"}
    end
  end

  defp parse_headers(lines) do
    Enum.reduce_while(lines, {:ok, []}, fn line, {:ok, headers} ->
      case :binary.split(line, ":") do
        [name, value] when byte_size(name) > 0 ->
          normalized_name = name |> String.trim() |> String.downcase()
          normalized_value = String.trim(value)
          {:cont, {:ok, [{normalized_name, normalized_value} | headers]}}

        _invalid ->
          {:halt, {:error, 400, "Malformed HTTP header"}}
      end
    end)
    |> case do
      {:ok, headers} -> {:ok, Enum.reverse(headers)}
      error -> error
    end
  end

  defp content_length("POST", headers, max_body_bytes) do
    case header_values(headers, "content-length") do
      [value] -> parse_content_length(value, max_body_bytes)
      [] -> {:error, 411, "Content-Length is required"}
      _duplicates -> {:error, 400, "Repeated Content-Length header"}
    end
  end

  defp content_length(_method, headers, max_body_bytes) do
    case header_values(headers, "content-length") do
      [] -> {:ok, 0}
      [value] -> parse_content_length(value, max_body_bytes)
      _duplicates -> {:error, 400, "Repeated Content-Length header"}
    end
  end

  defp parse_content_length(value, max_body_bytes) do
    case Integer.parse(value) do
      {length, ""} when length >= 0 and length <= max_body_bytes ->
        {:ok, length}

      {length, ""} when length > max_body_bytes ->
        {:error, 413, "HTTP request body is too large"}

      _invalid ->
        {:error, 400, "Invalid Content-Length header"}
    end
  end

  defp recv_body(_socket, acc, length, _deadline, _opts) when byte_size(acc) >= length,
    do: {:ok, binary_part(acc, 0, length)}

  # Each read returns whatever has arrived, so `:read_timeout` bounds each read
  # and the body deadline bounds the whole body, as for the head.
  defp recv_body(socket, acc, length, deadline, opts) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining > 0 do
      with {:ok, chunk} <- recv_chunk(socket, min(remaining, opts.read_timeout), opts.server_ref) do
        recv_body(socket, acc <> chunk, length, deadline, opts)
      end
    else
      {:error, :timeout}
    end
  end

  defp validate_endpoint(%Request{path: path}, path), do: :ok
  defp validate_endpoint(%Request{}, _configured), do: {:response, %Response{status: 404}}

  defp request_path(target) do
    target
    |> String.split("?", parts: 2)
    |> hd()
  end

  defp send_response(socket, %Response{} = response) do
    body = response.body

    headers =
      response.headers ++
        [
          {"content-length", Integer.to_string(byte_size(body))},
          {"connection", "close"}
        ]

    lines =
      Enum.map(headers, fn {name, value} ->
        [canonical_header_name(name), ": ", value, "\r\n"]
      end)

    :gen_tcp.send(socket, [
      "HTTP/1.1 ",
      Integer.to_string(response.status),
      " ",
      reason_phrase(response.status),
      "\r\n",
      lines,
      "\r\n",
      body
    ])
  end

  defp maybe_send_response(socket, %Response{} = response, _opts),
    do: send_response(socket, response)

  defp maybe_send_response(socket, %StreamResponse{} = response, opts) do
    serve_subscription(socket, response, opts.server_ref)
  end

  defp maybe_send_response(_socket, _cancelled, _opts), do: :ok

  defp serve_subscription(
         socket,
         %StreamResponse{subscription: subscription} = response,
         server_ref
       ) do
    # The worker closes the source if this process exits, so it starts before
    # the first write, which can block for the socket's send timeout.
    {worker, monitor} = Subscription.start_worker(subscription, self())

    case Subscription.acknowledgement(subscription) do
      {:ok, acknowledgement} ->
        with :ok <- send_stream_headers(socket, response),
             :ok <- send_sse_message(socket, acknowledgement),
             :ok <- arm_socket(socket) do
          :ok = Subscription.continue(worker)
          stream = %{keepalive_ms: response.keepalive_ms, server_ref: server_ref}
          stream_subscription(socket, subscription, worker, monitor, stream)
        else
          # Each step is a socket operation, so a failure here means the
          # client went away. A client that closes right after reading the
          # acknowledgement can fail `setopts` with `:einval` before
          # `tcp_closed` arrives.
          {:error, reason} ->
            stop_subscription(subscription, worker, monitor, {:disconnected, reason})
        end

      {:error, reason} ->
        stop_subscription(subscription, worker, monitor, {:error, reason})
    end
  end

  defp stream_subscription(socket, subscription, worker, monitor, stream) do
    server_ref = stream.server_ref

    receive do
      {:mcp_subscription, ^worker, outcome} ->
        handle_stream_outcome(socket, subscription, worker, monitor, stream, outcome)

      {:DOWN, ^monitor, :process, ^worker, reason} ->
        _send_result = send_sse_message(socket, Subscription.failure(subscription, reason))
        :ok = Subscription.close(subscription, {:error, reason})

      {:tcp_closed, ^socket} ->
        stop_subscription(subscription, worker, monitor, :disconnected)

      {:tcp_error, ^socket, reason} ->
        stop_subscription(subscription, worker, monitor, {:disconnected, reason})

      {:tcp, ^socket, _unexpected_data} ->
        continue_stream(arm_socket(socket), socket, subscription, worker, monitor, stream)

      {:mcp_http_drain, ^server_ref} ->
        _send_result = send_subscription_completion(socket, subscription)
        stop_subscription(subscription, worker, monitor, :shutdown)
    after
      stream.keepalive_ms ->
        result = :gen_tcp.send(socket, ": keepalive\r\n\r\n")
        continue_stream(result, socket, subscription, worker, monitor, stream)
    end
  end

  defp handle_stream_outcome(
         socket,
         subscription,
         worker,
         monitor,
         stream,
         {:ok, event}
       ) do
    case Subscription.notification(subscription, event) do
      {:ok, notification} ->
        result = send_sse_message(socket, notification)
        continue_source(result, socket, subscription, worker, monitor, stream)

      :drop ->
        continue_source(:ok, socket, subscription, worker, monitor, stream)

      {:error, error} ->
        _send_result = send_sse_message(socket, Subscription.failure(subscription, error))
        stop_subscription(subscription, worker, monitor, {:error, error})
    end
  end

  defp handle_stream_outcome(
         socket,
         subscription,
         worker,
         monitor,
         _stream,
         :closed
       ) do
    _send_result = send_subscription_completion(socket, subscription)
    stop_subscription(subscription, worker, monitor, :complete)
  end

  defp handle_stream_outcome(
         socket,
         subscription,
         worker,
         monitor,
         _stream,
         {:error, reason}
       ) do
    _send_result = send_sse_message(socket, Subscription.failure(subscription, reason))
    stop_subscription(subscription, worker, monitor, {:error, reason})
  end

  defp continue_source(:ok, socket, subscription, worker, monitor, stream) do
    :ok = Subscription.continue(worker)
    stream_subscription(socket, subscription, worker, monitor, stream)
  end

  defp continue_source({:error, reason}, _socket, subscription, worker, monitor, _stream) do
    stop_subscription(subscription, worker, monitor, {:disconnected, reason})
  end

  defp continue_stream(:ok, socket, subscription, worker, monitor, stream) do
    stream_subscription(socket, subscription, worker, monitor, stream)
  end

  defp continue_stream({:error, reason}, _socket, subscription, worker, monitor, _stream) do
    stop_subscription(subscription, worker, monitor, {:disconnected, reason})
  end

  defp send_subscription_completion(socket, subscription) do
    case Subscription.completion(subscription) do
      {:ok, completion} -> send_sse_message(socket, completion)
      {:error, error} -> send_sse_message(socket, Subscription.failure(subscription, error))
    end
  end

  defp stop_subscription(subscription, worker, monitor, reason) do
    :ok = Subscription.close(subscription, reason)
    :ok = Subscription.stop_worker(worker, monitor)
    :ok
  end

  defp send_stream_headers(socket, %StreamResponse{} = response) do
    send_stream_headers(socket, response.status, response.headers)
  end

  defp send_stream_headers(socket, status, headers) do
    headers = headers ++ [{"connection", "close"}]

    lines =
      Enum.map(headers, fn {name, value} ->
        [canonical_header_name(name), ": ", value, "\r\n"]
      end)

    :gen_tcp.send(socket, [
      "HTTP/1.1 ",
      Integer.to_string(status),
      " ",
      reason_phrase(status),
      "\r\n",
      lines,
      "\r\n"
    ])
  end

  defp send_sse_message(socket, message) when is_map(message) do
    :gen_tcp.send(socket, ["data: ", JSON.encode!(message), "\r\n\r\n"])
  end

  defp arm_socket(socket), do: :inet.setopts(socket, active: :once)

  defp basic_error(status, message, code \\ -32_600) do
    body = %{
      "jsonrpc" => "2.0",
      "id" => nil,
      "error" => %{"code" => code, "message" => message}
    }

    headers = if status == 405, do: [{"allow", "POST"}], else: []

    %Response{
      status: status,
      headers: [{"content-type", "application/json"} | headers],
      body: JSON.encode!(body)
    }
  end

  defp canonical_header_name(name) do
    name
    |> String.split("-")
    |> Enum.map_join("-", &String.capitalize/1)
  end

  defp reason_phrase(200), do: "OK"
  defp reason_phrase(202), do: "Accepted"
  defp reason_phrase(400), do: "Bad Request"
  defp reason_phrase(403), do: "Forbidden"
  defp reason_phrase(404), do: "Not Found"
  defp reason_phrase(405), do: "Method Not Allowed"
  defp reason_phrase(406), do: "Not Acceptable"
  defp reason_phrase(411), do: "Length Required"
  defp reason_phrase(413), do: "Content Too Large"
  defp reason_phrase(415), do: "Unsupported Media Type"
  defp reason_phrase(431), do: "Request Header Fields Too Large"
  defp reason_phrase(500), do: "Internal Server Error"
  defp reason_phrase(503), do: "Service Unavailable"
  defp reason_phrase(504), do: "Gateway Timeout"
  defp reason_phrase(_status), do: "Response"

  defp header_values(headers, name) do
    wanted = String.downcase(name)
    for {^wanted, value} <- headers, do: value
  end

  defp peer_name(socket) do
    case :inet.peername(socket) do
      {:ok, peer} -> peer
      {:error, _reason} -> nil
    end
  end

  defp submit_execution(executor, key, work, timeout) do
    Executor.submit(executor, key, work, timeout: timeout)
  catch
    :exit, reason -> {:error, {:executor_unavailable, reason}}
  end

  # The connection process holds the slot, so the executor returns it when the
  # connection ends, whether the stream completed, the client left, or the
  # process crashed.
  defp acquire_subscription_slot(opts) do
    pool = {__MODULE__, opts.server_ref}
    Executor.acquire_slot(opts.executor, pool, opts.max_subscriptions)
  catch
    :exit, reason -> {:error, {:executor_unavailable, reason}}
  end

  defp start_request_timer(_key, :infinity), do: nil

  defp start_request_timer(key, timeout),
    do: Process.send_after(self(), {:mcp_http_deadline, key}, timeout)

  defp cancel_request_timer(nil, _key), do: :ok

  defp cancel_request_timer(timer, key) do
    _remaining = Process.cancel_timer(timer)

    receive do
      {:mcp_http_deadline, ^key} -> :ok
    after
      0 -> :ok
    end
  end

  defp deadline_timeout!(:default), do: @default_request_timeout
  defp deadline_timeout!(:infinity), do: :infinity
  defp deadline_timeout!(timeout) when is_integer(timeout) and timeout >= 0, do: timeout

  defp deadline_timeout!(_invalid),
    do: raise(ArgumentError, ":request_timeout must be non-negative, :default, or :infinity")

  defp cancel_execution(executor, key, reason, sink) do
    # Executor cancellation can kill the worker before this call returns. Close
    # the transport-owned sink first; worker :kill bypasses its try/after.
    :ok = Progress.close(sink)
    _result = Executor.cancel(executor, key, reason)
    nil
  catch
    :exit, _exit_reason -> nil
  end

  defp start_executor(opts) do
    case Keyword.get(opts, :executor) do
      executor when is_pid(executor) ->
        {:ok, executor, false}

      nil ->
        with {:ok, executor} <- Executor.start_link(executor_options(opts)) do
          {:ok, executor, true}
        end

      _invalid ->
        {:error, :invalid_executor}
    end
  end

  defp executor_options(opts) do
    options = Keyword.take(opts, [:max_concurrency, :max_queue])

    case Keyword.get(opts, :request_timeout, :default) do
      :default -> options
      timeout -> Keyword.put(options, :default_timeout, timeout)
    end
  end

  defp stop_executor(executor) do
    if Process.alive?(executor), do: GenServer.stop(executor, :normal)
    :ok
  catch
    :exit, _reason -> :ok
  end

  defp normalize_ip(ip) when is_tuple(ip), do: ip

  defp normalize_ip(ip) when is_binary(ip) do
    case :inet.parse_address(String.to_charlist(ip)) do
      {:ok, parsed} -> parsed
      {:error, _reason} -> raise ArgumentError, ":ip must be a valid IP address"
    end
  end

  defp normalize_ip(_invalid), do: raise(ArgumentError, ":ip must be an IP tuple or string")

  defp validate_port!(port) when is_integer(port) and port in 0..65_535, do: :ok
  defp validate_port!(_port), do: raise(ArgumentError, ":port must be an integer from 0 to 65535")

  defp validate_path!("/" <> _rest = path), do: path
  defp validate_path!(_path), do: raise(ArgumentError, ":path must begin with /")

  defp bracket_ipv6(host) do
    if String.contains?(host, ":"), do: "[#{host}]", else: host
  end

  defp positive_option!(opts, key, default) do
    case Keyword.get(opts, key, default) do
      value when is_integer(value) and value > 0 -> value
      _invalid -> raise ArgumentError, "#{inspect(key)} must be a positive integer"
    end
  end

  defp validate_keepalive!(value) when is_integer(value) and value > 0, do: value

  defp validate_keepalive!(_invalid) do
    raise ArgumentError, ":subscription_keepalive_ms must be a positive integer"
  end
end
