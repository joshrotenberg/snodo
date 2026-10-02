defmodule Snodo.Transport.Plug do
  @moduledoc """
  Optional Plug binding for the stateless Streamable HTTP adapter.

  The application supplies an immutable `:runtime` and a supervised `:executor`.
  This Plug starts no listener or global runtime. Install it before body parsers,
  after the application's authentication Plug. Only `conn.assigns[:mcp_auth]`
  supplies `Snodo.Context.auth`; request headers and JSON never supply identity.

  Requests are admitted before entering the bounded executor. Valid cancellation
  notifications bypass that queue. Cross-request cancellation is opt-in through
  the trusted `:mcp_cancellation_scope` assign, combined with the complete auth
  value; applications must distinguish authenticated client instances in this
  scope. Anonymous requests cannot cancel each other by guessing request IDs.

  Portable Plug APIs only reveal a disconnect when a write fails. So that a
  client disconnect cancels a silent handler, as the 2026-07-28 cancellation
  rules require, a request still running after `:disconnect_probe_ms` (default
  5,000) turns its response into an event stream and sends a keepalive comment
  every interval; a failed write cancels the work, and the result arrives as
  the stream's final event. `:infinity` keeps plain JSON responses. A finite
  total `:request_timeout` bounds pending work and queue wait.

  At most `:max_subscriptions` (default 256) `subscriptions/listen` streams are
  open at once. `init/1` can run at compile time, so the count is held in the
  executor, which lives as long as the runtime; Plugs that share an executor
  share the count. A stream over the limit is closed at its source and the
  request gets 503.

  The request body must arrive within `:body_timeout` (default 10,000 ms from
  when this Plug starts reading it) or the request gets 408. The Plug reads the
  body in slices of at most 64 KiB and checks the deadline between them; each
  read waits at most `:read_timeout` (default 5,000) and never past the
  deadline. Under Bandit a `Content-Length` body is one socket read per slice,
  so the deadline bounds the whole body. A request that declares
  `Transfer-Encoding` gets 411 without its body being read: an adapter returns
  from a chunked read only once it has the requested bytes, however many
  socket reads that takes, so no deadline checked between reads can bound it.
  Over HTTP/2, Bandit returns from a read after a slice of DATA, at the end of
  the stream, or after `:read_timeout` without a frame, and each DATA frame
  restarts that wait, so a client that keeps sending small or empty frames can
  hold the request process past the deadline. After a body error over HTTP/1.x
  the response closes the connection, so the adapter does not read the rest of
  the body.
  """

  @behaviour Plug

  alias Plug.Conn
  alias Snodo.Error
  alias Snodo.Progress
  alias Snodo.Server
  alias Snodo.Server.Executor
  alias Snodo.Server.Runtime
  alias Snodo.Transport.Plug.Lease
  alias Snodo.Transport.Plug.Stream
  alias Snodo.Transport.StreamableHTTP
  alias Snodo.Transport.StreamableHTTP.Request
  alias Snodo.Transport.StreamableHTTP.Response
  alias Snodo.Transport.StreamableHTTP.StreamResponse

  # Bytes requested per body read. A Content-Length read of this size is one
  # socket read under Bandit, so the deadline is checked after each read.
  @body_slice 65_536
  @http1 [:"HTTP/1", :"HTTP/1.0", :"HTTP/1.1"]

  @impl true
  def init(opts) do
    runtime = Keyword.fetch!(opts, :runtime)

    unless match?(%Runtime{}, runtime),
      do: raise(ArgumentError, ":runtime must be an Snodo.Server.Runtime")

    path = Keyword.get(opts, :path, "/mcp")

    unless is_binary(path) and String.starts_with?(path, "/") and
             not String.contains?(path, ["?", "#"]) do
      raise ArgumentError, ":path must be an absolute HTTP path without query or fragment"
    end

    %{
      runtime: runtime,
      executor: Keyword.fetch!(opts, :executor),
      path: path,
      instance: make_ref(),
      auth_assign: atom_option!(opts, :auth_assign, :mcp_auth),
      cancellation_scope_assign:
        atom_option!(opts, :cancellation_scope_assign, :mcp_cancellation_scope),
      request_timeout: positive_option!(opts, :request_timeout, 30_000),
      max_body_bytes: positive_option!(opts, :max_body_bytes, 2_000_000),
      read_timeout: positive_option!(opts, :read_timeout, 5_000),
      body_timeout: positive_option!(opts, :body_timeout, 10_000),
      subscription_keepalive_ms: positive_option!(opts, :subscription_keepalive_ms, 15_000),
      max_subscriptions: positive_option!(opts, :max_subscriptions, 256),
      disconnect_probe_ms: probe_option!(opts),
      adapter_opts: Keyword.take(opts, [:allowed_origin_hosts, :allowed_hosts])
    }
  end

  @impl true
  def call(%Conn{halted: true} = conn, _opts), do: conn

  def call(%Conn{request_path: path} = conn, %{path: path} = opts) do
    case read_body(conn, opts) do
      {:ok, body, conn} -> admit(conn, body, opts)
      {:error, status, conn} -> refuse_body(conn, status)
    end
  end

  def call(%Conn{} = conn, _opts), do: conn |> Conn.send_resp(404, "") |> Conn.halt()

  defp admit(conn, body, opts) do
    request = %Request{
      method: conn.method,
      path: conn.request_path,
      headers: conn.req_headers,
      body: body,
      peer: Conn.get_peer_data(conn),
      connection_ref: make_ref()
    }

    case StreamableHTTP.prepare(opts.runtime, request, opts.adapter_opts) do
      {:response, response} ->
        send_response(conn, response, opts)

      {:ok, prepared} ->
        auth = Map.get(conn.assigns, opts.auth_assign)
        prepared = put_in(prepared.transport.metadata[:auth], auth)
        dispatch(conn, prepared, opts)
    end
  end

  defp dispatch(conn, %{kind: :notification} = prepared, opts) do
    case Server.resolve_notification(opts.runtime, prepared.raw, prepared.transport) do
      {:ok, {:cancel, id, reason}} -> cancel_scoped(conn, opts, id, reason)
      _other -> :ok
    end

    send_response(conn, StreamableHTTP.execute(opts.runtime, prepared), opts)
  end

  defp dispatch(conn, prepared, opts) do
    owner = self()
    lease = Lease.start(owner)
    sink = Progress.sink(owner)
    prepared = install_progress(prepared, sink)
    prepared = put_in(prepared.transport.metadata[:subscription_owner], lease)
    key = request_key(conn, opts, prepared.raw["id"])

    work = fn cancellation ->
      try do
        case StreamableHTTP.execute(opts.runtime, prepared, cancellation) do
          %StreamResponse{} = response -> open_stream(response, owner, lease, prepared, opts)
          response -> response
        end
      after
        Progress.close(sink)
      end
    end

    try do
      case submit(opts.executor, key, work, opts.request_timeout, lease) do
        {:ok, reference, executor} ->
          await(conn, opts, prepared, {reference, key, executor}, sink)

        {:error, :overloaded} ->
          send_response(
            conn,
            reject(opts, prepared, 503, "Server execution capacity exhausted"),
            opts
          )

        {:error, :duplicate_key} ->
          send_response(
            conn,
            reject(opts, prepared, 409, "Duplicate in-flight request ID in this scope"),
            opts
          )

        {:error, :unavailable} ->
          send_response(conn, reject(opts, prepared, 503, "Request executor unavailable"), opts)
      end
    after
      Progress.close(sink)
      Lease.stop(lease)
    end
  end

  # Runs in the executor task. The stream process holds the slot, so the
  # executor returns it when the stream ends for any reason.
  defp open_stream(response, owner, lease, prepared, opts) do
    slot = {opts.executor, __MODULE__, opts.max_subscriptions}

    case Stream.open(response, owner, lease, slot) do
      {:stream, _response, _stream} = stream ->
        stream

      {:error, :exhausted} ->
        reject(opts, prepared, 503, "Server subscription capacity exhausted")

      {:error, :unavailable} ->
        reject(opts, prepared, 503, "Request executor unavailable")
    end
  end

  defp install_progress(%{policy: %{stream_mode: :none}} = prepared, sink),
    do: put_in(prepared.transport.metadata[:progress_sink], sink)

  defp install_progress(prepared, _sink), do: prepared

  defp submit(executor, key, work, timeout, lease) do
    case GenServer.whereis(executor) do
      nil ->
        {:error, :unavailable}

      pid ->
        case Executor.submit(pid, key, work, timeout: timeout, reply_to: lease) do
          {:ok, reference} -> {:ok, reference, pid}
          error -> error
        end
    end
  catch
    :exit, _reason -> {:error, :unavailable}
  end

  defp await(conn, opts, prepared, {reference, key, executor}, sink) do
    monitor = Process.monitor(executor)

    state = %{
      conn: conn,
      reference: reference,
      key: key,
      executor: executor,
      monitor: monitor,
      progress: Progress.state(sink),
      deadline: System.monotonic_time(:millisecond) + opts.request_timeout
    }

    try do
      await_message(state, opts, prepared)
    after
      Process.demonitor(monitor, [:flush])
    end
  end

  defp await_message(state, opts, prepared) do
    %{
      executor: executor,
      reference: reference,
      key: key,
      monitor: monitor,
      progress: %{sink: %{reference: progress_reference}}
    } = state

    receive do
      {:mcp_execution, ^executor, ^reference, ^key, outcome} ->
        send_response(state.conn, execution_response(outcome, opts, prepared), opts)

      {:DOWN, ^monitor, :process, _pid, _reason} ->
        send_response(
          state.conn,
          reject(opts, prepared, 503, "Request executor unavailable"),
          opts
        )

      {:"$gen_call", from, {:mcp_progress, ^progress_reference, report}} ->
        report_progress(state, opts, prepared, from, report)
    after
      wait_time(state, opts) -> tick(state, opts, prepared)
    end
  end

  defp execution_response({:completed, response}, _opts, _prepared), do: response
  defp execution_response({:cancelled, _reason}, _opts, _prepared), do: %Response{status: 204}

  defp execution_response({:timed_out, _timeout}, opts, prepared),
    do: reject(opts, prepared, 504, "Request execution timed out")

  defp execution_response({:failed, _reason}, opts, prepared),
    do: reject(opts, prepared, 500, "Request worker failed")

  defp report_progress(state, opts, prepared, from, report) do
    case Progress.accept(state.progress, from, report) do
      {:ok, notification, progress} ->
        conn = progress_connection(state.conn)

        case Conn.chunk(conn, sse(JSON.encode!(notification))) do
          {:ok, conn} ->
            Progress.reply(from, report, :ok)
            await_message(%{state | conn: conn, progress: progress}, opts, prepared)

          {:error, _reason} ->
            Progress.reply(from, report, {:error, :disconnected})
            disconnect(%{state | conn: conn})
        end

      {:error, reason} ->
        Progress.reply(from, report, {:error, reason})
        await_message(state, opts, prepared)
    end
  end

  defp progress_connection(%Conn{state: :chunked} = conn), do: conn

  defp progress_connection(conn) do
    conn
    |> Conn.merge_resp_headers([
      {"content-type", "text/event-stream"},
      {"cache-control", "no-cache"},
      {"x-accel-buffering", "no"}
    ])
    |> Conn.send_chunked(200)
  end

  defp wait_time(state, opts) do
    remaining = max(state.deadline - System.monotonic_time(:millisecond), 0)

    cond do
      state.conn.state == :chunked -> min(remaining, keepalive_interval(opts))
      opts.disconnect_probe_ms == :infinity -> remaining
      true -> min(remaining, opts.disconnect_probe_ms)
    end
  end

  defp keepalive_interval(%{disconnect_probe_ms: :infinity} = opts),
    do: opts.subscription_keepalive_ms

  defp keepalive_interval(opts), do: min(opts.subscription_keepalive_ms, opts.disconnect_probe_ms)

  defp tick(state, opts, prepared) do
    if System.monotonic_time(:millisecond) >= state.deadline do
      Progress.close(state.progress.sink)
      cancel(state.executor, state.key, :request_timeout)
      send_response(state.conn, reject(opts, prepared, 504, "Request execution timed out"), opts)
    else
      # A silent request becomes an event stream so a write can reveal a
      # client that has gone away.
      conn = progress_connection(state.conn)

      case Conn.chunk(conn, ": keepalive\r\n\r\n") do
        {:ok, conn} -> await_message(%{state | conn: conn}, opts, prepared)
        {:error, _reason} -> disconnect(%{state | conn: conn})
      end
    end
  end

  defp disconnect(state) do
    Progress.close(state.progress.sink)
    cancel(state.executor, state.key, :disconnected)
    Conn.halt(state.conn)
  end

  defp cancel_scoped(conn, opts, id, reason) do
    if scope(conn, opts) != nil, do: cancel(opts.executor, request_key(conn, opts, id), reason)
    :ok
  end

  defp cancel(executor, key, reason) do
    _result = Executor.cancel(executor, key, reason)
    :ok
  catch
    :exit, _reason -> :ok
  end

  defp request_key(conn, opts, id) do
    {__MODULE__, opts.instance, scope(conn, opts) || make_ref(), id}
  end

  defp scope(conn, opts) do
    case {Map.get(conn.assigns, opts.auth_assign),
          Map.get(conn.assigns, opts.cancellation_scope_assign)} do
      {auth, client} when is_map(auth) and not is_nil(client) -> {auth, client}
      _anonymous -> nil
    end
  end

  defp reject(opts, prepared, status, message) do
    StreamableHTTP.reject(opts.runtime, prepared, Error.internal(message), status)
  end

  defp send_response(%Conn{state: :chunked} = conn, %Response{body: ""}, _opts),
    do: Conn.halt(conn)

  defp send_response(%Conn{state: :chunked} = conn, %Response{body: body}, _opts) do
    case Conn.chunk(conn, sse(body)) do
      {:ok, conn} -> Conn.halt(conn)
      {:error, _reason} -> Conn.halt(conn)
    end
  end

  defp send_response(conn, %Response{} = response, _opts) do
    conn
    |> Conn.merge_resp_headers(response.headers)
    |> Conn.send_resp(response.status, response.body)
    |> Conn.halt()
  end

  defp send_response(conn, {:stream, response, stream}, opts) do
    Stream.serve(conn, response, stream, opts.subscription_keepalive_ms) |> Conn.halt()
  end

  defp sse(json), do: ["event: message\r\ndata: ", json, "\r\n\r\n"]

  # A chunked read returns only once it has the requested bytes, however many
  # socket reads that takes, so a chunked body is refused rather than read.
  defp read_body(conn, opts) do
    case Conn.get_req_header(conn, "transfer-encoding") do
      [] ->
        deadline = System.monotonic_time(:millisecond) + opts.body_timeout
        read_body(conn, opts, deadline, [], 0)

      _declared ->
        {:error, 411, conn}
    end
  end

  defp read_body(conn, opts, deadline, acc, size) do
    remaining = deadline - System.monotonic_time(:millisecond)

    case read_slice(conn, opts, remaining, size) do
      {:ok, data, conn} -> body_read(conn, opts, [acc, data], size + byte_size(data))
      {:more, data, conn} -> more_body(conn, opts, deadline, [acc, data], size + byte_size(data))
      {:error, :timeout} -> {:error, 408, conn}
      {:error, _reason} -> {:error, 400, conn}
    end
  end

  defp read_slice(_conn, _opts, remaining, _size) when remaining <= 0, do: {:error, :timeout}

  defp read_slice(conn, opts, remaining, size) do
    # Never more than one byte past the limit, and never zero.
    length = min(@body_slice, opts.max_body_bytes + 1 - size)

    Conn.read_body(conn,
      length: length,
      read_length: length,
      read_timeout: min(opts.read_timeout, remaining)
    )
  end

  defp body_read(conn, opts, _acc, size) when size > opts.max_body_bytes, do: {:error, 413, conn}
  defp body_read(conn, _opts, acc, _size), do: {:ok, IO.iodata_to_binary(acc), conn}

  defp more_body(conn, opts, _deadline, _acc, size) when size > opts.max_body_bytes,
    do: {:error, 413, conn}

  defp more_body(conn, opts, deadline, acc, size), do: read_body(conn, opts, deadline, acc, size)

  # The rest of the body is unread. Closing the connection keeps an HTTP/1.x
  # adapter from reading it after this response; Bandit otherwise drains it
  # with its own limits. HTTP/2 forbids the header, and Bandit resets an
  # unfinished HTTP/2 stream instead of draining it.
  defp refuse_body(conn, status) do
    conn =
      if Conn.get_http_protocol(conn) in @http1,
        do: Conn.put_resp_header(conn, "connection", "close"),
        else: conn

    conn |> Conn.send_resp(status, "") |> Conn.halt()
  end

  defp positive_option!(opts, key, default) do
    case Keyword.get(opts, key, default) do
      value when is_integer(value) and value > 0 -> value
      _invalid -> raise ArgumentError, "#{inspect(key)} must be a positive integer"
    end
  end

  defp probe_option!(opts) do
    case Keyword.get(opts, :disconnect_probe_ms, 5_000) do
      :infinity ->
        :infinity

      value when is_integer(value) and value > 0 ->
        value

      _invalid ->
        raise ArgumentError, ":disconnect_probe_ms must be a positive integer or :infinity"
    end
  end

  defp atom_option!(opts, key, default) do
    case Keyword.get(opts, key, default) do
      value when is_atom(value) and not is_nil(value) -> value
      _invalid -> raise ArgumentError, "#{inspect(key)} must be a non-nil atom"
    end
  end
end
