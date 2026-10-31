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

  `init/1` may run once at compile time or on every request (Phoenix's
  `forward` does the latter), so the options must not hold a function or a pid
  that has to outlive compilation. Cancellation keys also carry an `:instance`,
  which defaults to `{executor, path}` and keeps two mounts that share an
  executor apart; set it explicitly when two mounts share both.

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
  Over HTTP/2, Bandit 1.12.5 restarted a read's `:read_timeout` wait on every
  DATA frame, even an empty one, so a client that kept sending small or empty
  frames could hold a read past the deadline. Bandit 1.14.0 gives each read one
  deadline that empty frames do not extend and that data extends only in
  proportion to the bytes delivered (`Bandit.HTTP2.Stream.read_data/2`), so
  the Plug's deadline bounds the body there too; a test covers this. Use
  Bandit 1.14 or later for untrusted HTTP/2 clients. After a body error over
  HTTP/1.x the response closes the connection, so the adapter does not read the rest of
  the body.

  ## Initialize-era sessions

  `:sessions` names a `Snodo.Session.Manager` the application supervises,
  which gives clients of the enabled initialize-era dialects a
  `Snodo.Session` as described in `Snodo.Transport.StreamableHTTP`. It
  defaults to `nil`, which keeps the dialects sessionless and answers `GET`
  and `DELETE` with 405. A session is bound to the value of the auth assign.
  A handler's input requests are written on the request's event stream, `GET`
  opens the session's standalone stream with a keepalive every
  `:subscription_keepalive_ms`, and `notifications/cancelled` cancels a
  request in flight on the same session. Sessions live on the node that
  created them, so several nodes need sticky routing by `Mcp-Session-Id`.
  """

  @behaviour Plug

  require Logger

  alias Plug.Conn
  alias Snodo.Error
  alias Snodo.Progress
  alias Snodo.Server
  alias Snodo.Server.Executor
  alias Snodo.Server.Runtime
  alias Snodo.Session
  alias Snodo.Session.Manager, as: SessionManager
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

    executor = Keyword.fetch!(opts, :executor)

    %{
      runtime: runtime,
      executor: executor,
      path: path,
      # Part of every cancellation key. It must not change between init/1
      # calls, because Phoenix's forward calls init/1 on each request.
      instance: Keyword.get(opts, :instance, {executor, path}),
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
      adapter_opts: Keyword.take(opts, [:allowed_origin_hosts, :allowed_hosts]),
      sessions: sessions_option!(opts)
    }
  end

  @impl true
  def call(%Conn{halted: true} = conn, _opts), do: conn

  def call(%Conn{request_path: path} = conn, %{path: path} = opts) do
    case read_body(conn, opts) do
      {:ok, "", conn} = read ->
        if consumed?(conn), do: body_consumed(conn), else: admit_read(read, opts)

      read ->
        admit_read(read, opts)
    end
  end

  def call(%Conn{} = conn, _opts), do: conn |> Conn.send_resp(404, "") |> Conn.halt()

  @body_consumed "The request body was already consumed by a body parser such as Plug.Parsers. " <>
                   "Install Snodo.Transport.Plug before the parser, or forward the MCP path " <>
                   "before the parsing plug runs."

  defp admit_read({:ok, body, conn}, opts), do: admit(conn, body, opts)
  defp admit_read({:error, status, conn}, _opts), do: refuse_body(conn, status)

  # An empty read means a parser took the body only when a parser ran and the
  # request declared a non-empty body. Params alone are not evidence: another
  # plug can set them on a bodyless request. Chunked bodies are refused before
  # this point, so a body always declares its length here.
  defp consumed?(%Conn{body_params: %Conn.Unfetched{}}), do: false

  defp consumed?(%Conn{} = conn) do
    Enum.any?(Conn.get_req_header(conn, "content-length"), fn value ->
      match?({length, ""} when length > 0, Integer.parse(String.trim(value)))
    end)
  end

  defp body_consumed(conn) do
    Logger.error("Snodo.Transport.Plug: " <> @body_consumed)

    body =
      JSON.encode!(%{
        "jsonrpc" => "2.0",
        "id" => nil,
        "error" => %{"code" => -32_603, "message" => @body_consumed}
      })

    conn
    |> Conn.put_resp_content_type("application/json")
    |> Conn.send_resp(500, body)
    |> Conn.halt()
  end

  defp admit(conn, body, opts) do
    request = %Request{
      method: conn.method,
      path: conn.request_path,
      headers: conn.req_headers,
      body: body,
      peer: Conn.get_peer_data(conn),
      connection_ref: make_ref()
    }

    auth = Map.get(conn.assigns, opts.auth_assign)

    case StreamableHTTP.prepare(opts.runtime, request, adapter_opts(opts, auth)) do
      {:response, response} ->
        send_response(conn, response, opts)

      {:standalone, session} ->
        serve_standalone(conn, session, opts)

      {:ok, prepared} ->
        prepared = put_in(prepared.transport.metadata[:auth], auth)
        dispatch(conn, prepared, opts)
    end
  end

  defp adapter_opts(%{sessions: nil} = opts, _auth), do: opts.adapter_opts

  defp adapter_opts(opts, auth),
    do: opts.adapter_opts ++ [sessions: SessionManager.config(opts.sessions), auth: auth]

  # The session's standalone stream: list changes and resource updates, each
  # acknowledged to the session once written.
  defp serve_standalone(conn, %Session{pid: pid}, opts) do
    case Session.attach_stream(pid, self()) do
      :ok ->
        monitor = Process.monitor(pid)

        try do
          conn |> progress_connection() |> stream_standalone(pid, monitor, opts) |> Conn.halt()
        after
          Process.demonitor(monitor, [:flush])
        end

      {:error, :conflict} ->
        send_resp_error(conn, 409, -32_600, "The session already has a standalone stream")

      {:error, :closed} ->
        send_resp_error(conn, 404, -32_001, "Session not found")
    end
  end

  defp stream_standalone(conn, pid, monitor, opts) do
    receive do
      {:mcp_session_message, ^pid, ref, message} ->
        case Conn.chunk(conn, sse(JSON.encode!(message))) do
          {:ok, conn} ->
            send(pid, {:mcp_session_written, ref, :ok})
            stream_standalone(conn, pid, monitor, opts)

          {:error, reason} ->
            send(pid, {:mcp_session_written, ref, {:error, reason}})
            conn
        end

      {:DOWN, ^monitor, :process, ^pid, _reason} ->
        conn
    after
      opts.subscription_keepalive_ms ->
        case Conn.chunk(conn, ": keepalive\r\n\r\n") do
          {:ok, conn} -> stream_standalone(conn, pid, monitor, opts)
          {:error, _reason} -> conn
        end
    end
  end

  defp send_resp_error(conn, status, code, message) do
    body =
      JSON.encode!(%{
        "jsonrpc" => "2.0",
        "id" => nil,
        "error" => %{"code" => code, "message" => message}
      })

    conn
    |> Conn.put_resp_content_type("application/json")
    |> Conn.send_resp(status, body)
    |> Conn.halt()
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
    tracked = tracked_request(prepared)

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
          track_request(tracked, executor, key)
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
      untrack_request(tracked)
    end
  end

  # A request on a session can be cancelled with notifications/cancelled,
  # which reaches it through the session. Only the session and the request ID
  # are kept, so an open stream does not hold the request body.
  defp tracked_request(%{session: %Session{pid: pid}, raw: %{"id" => id}}), do: {pid, id}
  defp tracked_request(_prepared), do: nil

  defp track_request({pid, id}, executor, key),
    do: Session.track(pid, id, fn reason -> cancel(executor, key, reason) end)

  defp track_request(nil, _executor, _key), do: :ok

  defp untrack_request({pid, id}), do: Session.untrack(pid, id)
  defp untrack_request(nil), do: :ok

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

      {:"$gen_call", from, {:mcp_stream_message, ^progress_reference, message}} ->
        send_stream_message(state, opts, prepared, from, message)
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

  # A server-to-client request made on behalf of this request, on its own
  # event stream.
  defp send_stream_message(state, opts, prepared, from, message) do
    conn = progress_connection(state.conn)

    case Conn.chunk(conn, sse(JSON.encode!(message))) do
      {:ok, conn} ->
        GenServer.reply(from, :ok)
        await_message(%{state | conn: conn}, opts, prepared)

      {:error, _reason} ->
        GenServer.reply(from, {:error, :disconnected})
        disconnect(%{state | conn: conn})
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

  defp sessions_option!(opts) do
    case Keyword.get(opts, :sessions) do
      nil -> nil
      name when is_atom(name) -> name
      _invalid -> raise ArgumentError, ":sessions must be the name of a Snodo.Session.Manager"
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
