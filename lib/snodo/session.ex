defmodule Snodo.Session do
  @moduledoc """
  One initialize-era session: the state a 2025-11-25 or 2025-06-18 client
  shares with the server between `initialize` and the end of the session.

  Sessions are opt-in. A transport given the `sessions:` option starts one
  process per session: `Snodo.Transport.StreamableHTTP.Server` and
  `Snodo.Transport.Plug` for each `initialize` (through
  `Snodo.Session.Manager`, which issues the `Mcp-Session-Id`), and
  `Snodo.Transport.Stdio` for its connection, which needs no ID. Without the
  option the dialects run sessionless, as before. 2026-07-28 requests never
  use a session.

  The process holds the negotiated version, the client's capabilities and
  information, the principal that created the session, the log level set with
  `logging/setLevel`, the resources the client subscribed to, the standalone
  stream, the server's requests waiting for the client's answers, and the
  client's requests in flight, so `notifications/cancelled` can reach them.

  A handler written for 2026-07-28 input requests serves these clients
  unchanged: it returns `Snodo.Result.input_required/1` with
  `Snodo.Elicitation`, `Snodo.Sampling`, or `Snodo.Roots` requests, and the
  transport sends each one to the client as its own JSON-RPC request on the
  original request's response stream, waits for the answers, and calls the
  handler again with them in `Snodo.Context.input_responses`. The
  request's deadline covers every round.

  With a `:subscription_source` on the runtime, the session opens it for the
  list changes the server advertises and the resources the client subscribes
  to with `resources/subscribe`, and sends each event on the standalone
  stream: the `GET` stream over HTTP, or the connection over stdio. An event
  that arrives while no standalone stream is open is dropped.

  The struct is a snapshot that a transport passes to the dialect; it is
  `Snodo.Context.session` for requests on a session.
  """

  use GenServer, restart: :temporary

  alias Snodo.Context
  alias Snodo.Subscription
  alias Snodo.Transport.Context, as: TransportContext

  @enforce_keys [:pid]
  defstruct [
    :id,
    :pid,
    :protocol_version,
    :client_info,
    :log_level,
    client_capabilities: %{},
    ready?: false
  ]

  @type t :: %__MODULE__{
          id: String.t() | nil,
          pid: pid(),
          protocol_version: String.t() | nil,
          client_info: map() | nil,
          client_capabilities: map(),
          log_level: Snodo.Logging.level() | nil,
          ready?: boolean()
        }

  @id_bytes 24

  @doc false
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc false
  @spec info(pid()) :: t()
  def info(pid), do: GenServer.call(pid, :info)

  @doc false
  # Returns the session's snapshot when `principal` is the one it is bound
  # to, and counts as activity.
  @spec admit(pid(), term()) :: {:ok, t()} | :error
  def admit(pid, principal), do: call(pid, {:admit, principal}, :error)

  @doc false
  # Records the result of a successful `initialize`.
  @spec ready(pid(), String.t(), map() | nil, map()) :: :ok
  def ready(pid, version, client_info, client_capabilities),
    do: call(pid, {:ready, version, client_info, client_capabilities}, :ok)

  @doc false
  @spec put_log_level(pid(), Snodo.Logging.level()) :: :ok
  def put_log_level(pid, level), do: call(pid, {:log_level, level}, :ok)

  @doc false
  @spec subscribe(pid(), String.t(), Context.t()) :: :ok | {:error, Snodo.Error.t()}
  def subscribe(pid, uri, context), do: call(pid, {:subscribe, uri, context}, :ok)

  @doc false
  @spec unsubscribe(pid(), String.t()) :: :ok
  def unsubscribe(pid, uri), do: call(pid, {:unsubscribe, uri}, :ok)

  @doc """
  Makes `stream` the session's standalone stream.

  For an HTTP stack that serves the `{:standalone, session}` result of
  `Snodo.Transport.StreamableHTTP.prepare/3` itself. The session sends
  `stream` `{:mcp_session_message, session_pid, ref, message}` for each
  notification, and sends the next one only after `stream` replies with
  `send(session_pid, {:mcp_session_written, ref, :ok | {:error, reason}})`.
  The session watches `stream` and detaches it when it exits. Returns
  `{:error, :conflict}` when the session already has a standalone stream,
  which HTTP answers with 409, and `{:error, :closed}` when the session has
  ended.
  """
  @spec attach_stream(pid(), pid()) :: :ok | {:error, :conflict | :closed}
  def attach_stream(pid, stream), do: call(pid, {:attach_stream, stream}, {:error, :closed})

  @doc false
  # Allocates the ID of a server-to-client request whose answer goes to the
  # caller as `{:mcp_session_answer, session, id, response}`.
  @spec open_request(pid()) :: {:ok, pos_integer()} | {:error, :closed}
  def open_request(pid), do: call(pid, :open_request, {:error, :closed})

  @doc false
  @spec close_request(pid(), pos_integer()) :: :ok
  def close_request(pid, id), do: call(pid, {:close_request, id}, :ok)

  @doc false
  # Routes a client's JSON-RPC response to the request waiting for it.
  @spec deliver(pid(), map()) :: :ok | {:error, :unknown}
  def deliver(pid, response), do: call(pid, {:deliver, response}, {:error, :unknown})

  @doc false
  # Records a client request in flight; `cancel` is called with the reason
  # when the client cancels it. The entry goes when the caller exits.
  @spec track(pid(), term(), (term() -> term())) :: :ok
  def track(pid, request_id, cancel), do: call(pid, {:track, request_id, cancel}, :ok)

  @doc false
  @spec untrack(pid(), term()) :: :ok
  def untrack(pid, request_id), do: call(pid, {:untrack, request_id}, :ok)

  @doc false
  @spec cancel(pid(), term(), term()) :: :ok
  def cancel(pid, request_id, reason), do: call(pid, {:cancel, request_id, reason}, :ok)

  @doc false
  @spec close(pid()) :: :ok
  def close(pid) do
    GenServer.stop(pid, :normal)
  catch
    :exit, _reason -> :ok
  end

  # A session that has ended answers as if it never existed.
  defp call(pid, request, closed) do
    GenServer.call(pid, request)
  catch
    :exit, _reason -> closed
  end

  @impl true
  def init(opts) do
    runtime = Keyword.fetch!(opts, :runtime)

    state = %{
      id: nil,
      registry: Keyword.get(opts, :registry),
      runtime: runtime,
      principal: Keyword.get(opts, :principal),
      idle_timeout: Keyword.get(opts, :idle_timeout, :infinity),
      idle_timer: nil,
      version: nil,
      client_info: nil,
      client_capabilities: %{},
      log_level: nil,
      ready?: false,
      stream: nil,
      writing: nil,
      outgoing: %{},
      next_id: 1,
      tracked: %{},
      uris: MapSet.new(),
      auth: nil,
      subscription: nil
    }

    with {:ok, state} <- register(state) do
      state = attach_initial_stream(state, Keyword.get(opts, :stream))
      {:ok, schedule_idle(state)}
    end
  end

  defp register(%{registry: nil} = state), do: {:ok, state}

  defp register(%{registry: {module, options}} = state) do
    id = Base.url_encode64(:crypto.strong_rand_bytes(@id_bytes), padding: false)

    case module.register(options, id, self()) do
      :ok -> {:ok, %{state | id: id}}
      {:error, reason} -> {:stop, reason}
    end
  end

  defp attach_initial_stream(state, nil), do: state

  defp attach_initial_stream(state, stream) when is_pid(stream),
    do: %{state | stream: %{pid: stream, monitor: Process.monitor(stream)}}

  @impl true
  def handle_call(:info, _from, state), do: {:reply, snapshot(state), state}

  def handle_call({:admit, principal}, _from, state) do
    if principal == state.principal,
      do: {:reply, {:ok, snapshot(state)}, schedule_idle(state)},
      else: {:reply, :error, state}
  end

  def handle_call({:ready, version, client_info, capabilities}, _from, state) do
    state = %{
      state
      | version: version,
        client_info: client_info,
        client_capabilities: capabilities,
        ready?: true,
        log_level: nil,
        uris: MapSet.new()
    }

    {:reply, :ok, state |> reopen_subscription(nil) |> schedule_idle()}
  end

  def handle_call({:log_level, level}, _from, state),
    do: {:reply, :ok, %{state | log_level: level}}

  def handle_call({:subscribe, uri, context}, _from, state) do
    state = %{state | uris: MapSet.put(state.uris, uri)}
    {:reply, :ok, reopen_subscription(state, context)}
  end

  def handle_call({:unsubscribe, uri}, _from, state) do
    if MapSet.member?(state.uris, uri) do
      state = %{state | uris: MapSet.delete(state.uris, uri)}
      {:reply, :ok, reopen_subscription(state, nil)}
    else
      {:reply, :ok, state}
    end
  end

  def handle_call({:attach_stream, _stream}, _from, %{stream: %{}} = state),
    do: {:reply, {:error, :conflict}, state}

  def handle_call({:attach_stream, stream}, _from, state) do
    state = %{state | stream: %{pid: stream, monitor: Process.monitor(stream)}}
    {:reply, :ok, state}
  end

  def handle_call(:open_request, {caller, _tag}, state) do
    id = state.next_id
    entry = %{pid: caller, monitor: Process.monitor(caller)}

    state = %{state | next_id: id + 1, outgoing: Map.put(state.outgoing, id, entry)}
    {:reply, {:ok, id}, state}
  end

  def handle_call({:close_request, id}, _from, state),
    do: {:reply, :ok, drop_outgoing(state, id)}

  def handle_call({:deliver, %{"id" => id} = response}, _from, state) do
    case Map.fetch(state.outgoing, id) do
      {:ok, %{pid: pid}} ->
        send(pid, {:mcp_session_answer, self(), id, response})
        {:reply, :ok, state |> drop_outgoing(id) |> schedule_idle()}

      :error ->
        {:reply, {:error, :unknown}, state}
    end
  end

  def handle_call({:deliver, _response}, _from, state), do: {:reply, {:error, :unknown}, state}

  def handle_call({:track, request_id, cancel}, {caller, _tag}, state) do
    state = untrack_request(state, request_id)
    entry = %{cancel: cancel, monitor: Process.monitor(caller)}
    {:reply, :ok, %{state | tracked: Map.put(state.tracked, request_id, entry)}}
  end

  def handle_call({:untrack, request_id}, _from, state),
    do: {:reply, :ok, untrack_request(state, request_id)}

  def handle_call({:cancel, request_id, reason}, _from, state) do
    case Map.fetch(state.tracked, request_id) do
      {:ok, %{cancel: cancel}} ->
        _ignored = safe_cancel(cancel, reason)
        {:reply, :ok, untrack_request(state, request_id)}

      :error ->
        {:reply, :ok, state}
    end
  end

  @impl true
  def handle_info({:mcp_session_idle, timer}, %{idle_timer: timer} = state) do
    if active?(state),
      do: {:noreply, schedule_idle(state)},
      else: {:stop, :normal, state}
  end

  def handle_info({:mcp_session_idle, _stale}, state), do: {:noreply, state}

  def handle_info({:mcp_session_written, ref, result}, %{writing: ref} = state) do
    state = %{state | writing: nil}

    case result do
      :ok -> {:noreply, continue_subscription(state)}
      {:error, _reason} -> {:noreply, state |> detach_stream() |> continue_subscription()}
    end
  end

  def handle_info({:mcp_session_written, _ref, _result}, state), do: {:noreply, state}

  def handle_info(
        {:mcp_subscription, worker, outcome},
        %{subscription: %{worker: worker}} = state
      ),
      do: {:noreply, handle_event(state, outcome)}

  def handle_info({:mcp_subscription, _worker, _outcome}, state), do: {:noreply, state}

  def handle_info({:DOWN, monitor, :process, _pid, _reason}, state) do
    {:noreply, handle_down(state, monitor)}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    close_subscription(state.subscription, :disconnected)

    Enum.each(state.outgoing, fn {id, %{pid: pid}} ->
      send(pid, {:mcp_session_answer, self(), id, :closed})
    end)

    case state do
      %{registry: {module, options}, id: id} when is_binary(id) -> module.unregister(options, id)
      _unregistered -> :ok
    end

    :ok
  end

  defp snapshot(state) do
    %__MODULE__{
      id: state.id,
      pid: self(),
      protocol_version: state.version,
      client_info: state.client_info,
      client_capabilities: state.client_capabilities,
      log_level: state.log_level,
      ready?: state.ready?
    }
  end

  defp handle_down(%{stream: %{monitor: monitor}} = state, monitor),
    do: state |> Map.put(:stream, nil) |> Map.put(:writing, nil) |> continue_subscription()

  defp handle_down(%{subscription: %{monitor: monitor} = entry} = state, monitor) do
    close_subscription(%{entry | worker: nil}, {:error, :worker_down})
    %{state | subscription: nil}
  end

  defp handle_down(state, monitor) do
    outgoing =
      Enum.find_value(state.outgoing, fn {id, entry} -> if entry.monitor == monitor, do: id end)

    tracked =
      Enum.find_value(state.tracked, fn {id, entry} -> if entry.monitor == monitor, do: id end)

    cond do
      not is_nil(outgoing) -> %{state | outgoing: Map.delete(state.outgoing, outgoing)}
      not is_nil(tracked) -> %{state | tracked: Map.delete(state.tracked, tracked)}
      true -> state
    end
  end

  defp drop_outgoing(state, id) do
    case Map.pop(state.outgoing, id) do
      {nil, _outgoing} ->
        state

      {%{monitor: monitor}, outgoing} ->
        Process.demonitor(monitor, [:flush])
        %{state | outgoing: outgoing}
    end
  end

  defp untrack_request(state, request_id) do
    case Map.pop(state.tracked, request_id) do
      {nil, _tracked} ->
        state

      {%{monitor: monitor}, tracked} ->
        Process.demonitor(monitor, [:flush])
        %{state | tracked: tracked}
    end
  end

  defp safe_cancel(cancel, reason) do
    cancel.(reason)
  catch
    _kind, _reason -> :ok
  end

  defp detach_stream(%{stream: nil} = state), do: state

  defp detach_stream(%{stream: %{monitor: monitor}} = state) do
    Process.demonitor(monitor, [:flush])
    %{state | stream: nil, writing: nil}
  end

  # A session with work in flight or an open stream is in use, however long
  # since its last request.
  defp active?(state),
    do: state.outgoing != %{} or state.tracked != %{} or not is_nil(state.stream)

  defp schedule_idle(%{idle_timeout: :infinity} = state), do: state

  defp schedule_idle(state) do
    if state.idle_timer, do: Process.cancel_timer(state.idle_timer)
    timer = make_ref()
    Process.send_after(self(), {:mcp_session_idle, timer}, state.idle_timeout)
    %{state | idle_timer: timer}
  end

  # Subscriptions. The source is opened for the list changes the server
  # advertises and the resources the client subscribed to, and opened again
  # when that set changes. `context` carries the auth of the request that
  # changed it; the first request's auth is kept otherwise.

  defp reopen_subscription(state, context) do
    close_subscription(state.subscription, :complete)
    state = %{state | subscription: nil, writing: nil}
    state = if context, do: %{state | auth: context.auth}, else: state

    with %{subscription_source: source} when not is_nil(source) <- state.runtime,
         true <- state.ready?,
         filter when map_size(filter) > 0 <- requested_filter(state),
         {:ok, subscription} <-
           Subscription.open(
             source,
             filter,
             subscription_context(state),
             state.runtime.extension_registry,
             self()
           ) do
      {worker, monitor} = Subscription.start_worker(subscription, self())
      :ok = Subscription.continue(worker)
      %{state | subscription: %{subscription: subscription, worker: worker, monitor: monitor}}
    else
      _none -> state
    end
  end

  defp requested_filter(state) do
    capabilities = state.runtime.capabilities

    %{}
    |> put_flag("toolsListChanged", get_in(capabilities, ["tools", "listChanged"]))
    |> put_flag("promptsListChanged", get_in(capabilities, ["prompts", "listChanged"]))
    |> put_flag("resourcesListChanged", get_in(capabilities, ["resources", "listChanged"]))
    |> put_uris(state.uris, get_in(capabilities, ["resources", "subscribe"]))
  end

  defp put_flag(filter, key, true), do: Map.put(filter, key, true)
  defp put_flag(filter, _key, _setting), do: filter

  defp put_uris(filter, uris, true) do
    if MapSet.size(uris) > 0,
      do: Map.put(filter, "resourceSubscriptions", uris |> MapSet.to_list() |> Enum.sort()),
      else: filter
  end

  defp put_uris(filter, _uris, _setting), do: filter

  defp subscription_context(state) do
    {:ok, protocol} =
      Snodo.Protocol.Registry.fetch(state.runtime.protocol_registry, state.version)

    %Context{
      protocol_version: state.version,
      protocol: protocol,
      transport: %TransportContext{transport: :session, metadata: %{session: snapshot(state)}},
      session: snapshot(state),
      auth: state.auth,
      server_info: state.runtime.server_info,
      server_capabilities: state.runtime.capabilities,
      client_info: state.client_info,
      client_capabilities: state.client_capabilities
    }
  end

  defp handle_event(state, {:ok, event}) do
    %{subscription: subscription} = state.subscription

    case Subscription.notification(subscription, event) do
      {:ok, notification} -> write_standalone(state, notification)
      :drop -> continue_subscription(state)
      {:error, _error} -> stop_subscription(state, {:error, :invalid_event})
    end
  end

  defp handle_event(state, :closed), do: stop_subscription(state, :complete)
  defp handle_event(state, {:error, reason}), do: stop_subscription(state, {:error, reason})

  defp write_standalone(%{stream: nil} = state, _notification), do: continue_subscription(state)

  defp write_standalone(%{stream: %{pid: pid}} = state, notification) do
    ref = make_ref()
    send(pid, {:mcp_session_message, self(), ref, notification})
    %{state | writing: ref}
  end

  defp continue_subscription(%{subscription: %{worker: worker}, writing: nil} = state) do
    :ok = Subscription.continue(worker)
    state
  end

  defp continue_subscription(state), do: state

  defp stop_subscription(state, reason) do
    close_subscription(state.subscription, reason)
    %{state | subscription: nil}
  end

  defp close_subscription(nil, _reason), do: :ok

  defp close_subscription(%{subscription: subscription, worker: worker, monitor: monitor}, reason) do
    :ok = Subscription.close(subscription, reason)
    if worker, do: Subscription.stop_worker(worker, monitor)
    :ok
  end
end
