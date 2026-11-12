defmodule Snodo.Subscription.Bridge do
  @moduledoc """
  A supervised `:pg` bridge between node-local subscription hubs.

  Start the same scope and group on each directly connected Erlang node that
  serves subscriptions. The child spec starts the scope, a local
  `Snodo.Subscription.Hub`, and a forwarding worker in that order under a
  `:rest_for_one` supervisor. The default `start_scope: :auto` monitors a scope
  that is already registered when the bridge starts, without ever starting a
  replacement. Otherwise the bridge starts and owns the scope. Use
  `start_scope: true` to allow starting a replacement even for an existing
  scope, or `false` to require an externally supervised scope. Put the scope
  first and its bridges after it under a
  `:rest_for_one` parent so a scope failure restarts the bridges after a live
  replacement is available. A hub failure restarts the forwarding worker.
  If the hub is manually stopped and restarted, the worker monitors it and
  resolves its replacement on the next publication.

      children = [{Snodo.Subscription.Bridge, name: MyApp.SubscriptionBridge}]

      runtime =
        MyServer.runtime(
          subscription_source: Snodo.Subscription.Bridge.source(MyApp.SubscriptionBridge)
        )

      Snodo.Subscription.Bridge.publish(
        MyApp.SubscriptionBridge,
        Snodo.Subscription.Event.tools_list_changed()
      )

  Publications are validated and delivered locally before being forwarded.
  The returned report describes only the local hub; remote sends have no
  acknowledgement. Each node's hub keeps its own bounded per-listener queues,
  filters, and overflow policy. The forwarding worker's mailbox is not bounded
  by the hub's queue limit.

  `:pg` membership converges after nodes connect directly. A new bridge can
  miss events until peers learn about it. Events published during a network
  split are not replayed after reconnection. Restarting a node or its local
  scope or hub loses in-memory listeners and queued events. Clients should
  reopen streams and refresh affected catalogs or resources.

  This is one `Snodo.Subscription.Source`; applications using another message
  bus can implement that behaviour or publish into their own local hubs.
  """

  use Supervisor

  alias Snodo.Subscription.Event
  alias Snodo.Subscription.Hub

  @behaviour Snodo.Subscription.Source

  @default_scope __MODULE__.PG
  @default_group {__MODULE__, :events}

  @doc """
  Starts the scope, local hub, and forwarding worker under one supervisor.

  Options are:

    * `:name` - the supervisor's registered name, defaulting to `#{inspect(__MODULE__)}`;
      use `nil` for an unnamed supervisor;
    * `:scope` - the `:pg` scope atom, defaulting to `#{inspect(@default_scope)}`;
    * `:start_scope` - `:auto` (the default) monitors an already registered scope
      without ever starting it later, or starts and owns an absent scope.
      `true` allows starting the scope on every restart, while `false` requires
      an externally supervised scope;
    * `:group` - the `:pg` group term, defaulting to `#{inspect(@default_group)}`;
    * `:hub_options` - options passed to `Snodo.Subscription.Hub.start_link/1`,
      defaulting to `[]` (a buffer of 100 events per listener and `:drop_oldest`).

  Use the same scope and group names on every participating node. Different
  groups may share a scope. Stopping a bridge stops a scope it started, so
  supervise a shared scope separately when bridges have independent lifetimes.

  With `start_scope: false`, the caller must start the scope first. If it is
  absent when the scope child starts, this returns the standard supervisor
  startup error:

      {:error,
       {:shutdown,
        {:failed_to_start_child, Snodo.Subscription.Bridge.Scope, {:scope_not_started, scope}}}}

  If the scope exits later during startup, this may fail on a later child or
  succeed and then restart as usual. The usual supervisor startup and linking
  semantics apply. The bridge never starts or waits for an external scope. If
  it stays absent after a failure, immediate restart failures exhaust the
  bridge supervisor's restart intensity and the supervisor exits. Put the scope
  and its bridges under a `:rest_for_one` parent, with the scope first, so it
  restarts the scope before restarting the bridges.
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) when is_list(opts) do
    unknown = Keyword.keys(opts) -- [:name, :scope, :start_scope, :group, :hub_options]

    if unknown != [] do
      raise ArgumentError, "unknown subscription bridge options: #{inspect(Enum.uniq(unknown))}"
    end

    scope = Keyword.get(opts, :scope, @default_scope)

    unless is_atom(scope) and not is_nil(scope) do
      raise ArgumentError, "subscription bridge scope must be an atom other than nil"
    end

    start_scope = Keyword.get(opts, :start_scope, :auto)

    unless start_scope in [:auto, true, false] do
      raise ArgumentError, "subscription bridge start_scope must be :auto or a boolean"
    end

    config = %{
      scope: scope,
      start_scope:
        if(start_scope == :auto, do: is_nil(Process.whereis(scope)), else: start_scope),
      group: Keyword.get(opts, :group, @default_group),
      hub_options: Keyword.get(opts, :hub_options, [])
    }

    case Keyword.get(opts, :name, __MODULE__) do
      nil -> Supervisor.start_link(__MODULE__, config)
      name -> Supervisor.start_link(__MODULE__, config, name: name)
    end
  end

  @doc "Returns a source configuration that resolves the current local hub when opening a stream."
  @spec source(Supervisor.supervisor()) :: {module(), Supervisor.supervisor()}
  def source(bridge \\ __MODULE__), do: {__MODULE__, bridge}

  @doc """
  Publishes locally and forwards a valid event to every other group member.

  The delivery report covers only the local hub. Remote delivery is best effort
  and is not acknowledged or replayed. Returns `{:error, :unavailable}` if the
  supervisor or forwarding worker is absent, restarting, or exits during the
  call. An event may already have reached listeners if an in-flight call fails.
  """
  @spec publish(Supervisor.supervisor(), Event.t()) ::
          {:ok, Hub.delivery_report()}
          | {:error, {:invalid_event, String.t()} | :unavailable}
  def publish(bridge \\ __MODULE__, event) do
    with_child(bridge, __MODULE__.Worker, &GenServer.call(&1, {:publish, event}))
  end

  @doc """
  Opens a listener on the current local hub.

  Returns `{:error, :unavailable}` if the supervisor or hub is absent,
  restarting, or exits during the call.
  """
  @spec open(map(), Snodo.Context.t(), Supervisor.supervisor()) ::
          {:ok, map(), term()} | {:error, :invalid_filter | :unavailable}
  @impl Snodo.Subscription.Source
  def open(filter, context, bridge) do
    with_child(bridge, Hub, &Hub.open(filter, context, &1))
  end

  @impl Snodo.Subscription.Source
  def next(handle, _bridge), do: Hub.next(handle, nil)

  @impl Snodo.Subscription.Source
  def close(handle, reason, _bridge), do: Hub.close(handle, reason, nil)

  @impl Supervisor
  def init(config) do
    children = [
      {__MODULE__.Scope, {config.scope, config.start_scope}},
      {Hub, config.hub_options},
      {__MODULE__.Worker, {self(), config.scope, config.group}}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end

  defp with_child(bridge, id, fun) do
    child =
      bridge
      |> Supervisor.which_children()
      |> List.keyfind(id, 0)

    case child do
      {^id, pid, _type, _modules} when is_pid(pid) -> fun.(pid)
      _unavailable -> {:error, :unavailable}
    end
  catch
    :exit, _reason -> {:error, :unavailable}
  end
end

defmodule Snodo.Subscription.Bridge.Scope do
  @moduledoc false

  use GenServer

  @doc false
  def start_link({scope, true}) do
    case :pg.start_link(scope) do
      {:error, {:already_started, pid}} -> GenServer.start_link(__MODULE__, pid)
      result -> result
    end
  end

  def start_link({scope, false}) do
    case Process.whereis(scope) do
      nil -> {:error, {:scope_not_started, scope}}
      pid -> GenServer.start_link(__MODULE__, pid)
    end
  end

  @impl GenServer
  def init(pid), do: {:ok, Process.monitor(pid)}

  @impl GenServer
  def handle_info({:DOWN, ref, :process, _pid, reason}, ref) do
    {:stop, {:scope_down, reason}, ref}
  end
end

defmodule Snodo.Subscription.Bridge.Worker do
  @moduledoc false

  use GenServer

  alias Snodo.Subscription.Hub

  @doc false
  def start_link(config), do: GenServer.start_link(__MODULE__, config)

  @impl GenServer
  def init({supervisor, scope, group}) do
    # Resolving the hub in handle_continue avoids calling a supervisor that is
    # still waiting for this child's start_link to return.
    :ok = :pg.join(scope, group, self())
    state = %{supervisor: supervisor, scope: scope, group: group, hub: nil, hub_monitor: nil}
    {:ok, state, {:continue, :resolve_hub}}
  end

  @impl GenServer
  def handle_continue(:resolve_hub, state) do
    {:noreply, resolve_hub(state)}
  end

  @impl GenServer
  def handle_call({:publish, event}, _from, state) do
    state = resolve_hub(state)

    case publish_locally(state.hub, event) do
      {:ok, report} ->
        state.scope
        |> :pg.get_members(state.group)
        |> Enum.reject(&(&1 == self()))
        |> Enum.uniq()
        |> Enum.each(&send(&1, {:subscription_event, event}))

        {:reply, {:ok, report}, state}

      {:error, _reason} = error ->
        {:reply, error, state}
    end
  end

  @impl GenServer
  def handle_info({:DOWN, ref, :process, _hub, _reason}, %{hub_monitor: ref} = state) do
    {:noreply, %{state | hub: nil, hub_monitor: nil}}
  end

  def handle_info({:subscription_event, event}, state) do
    state = resolve_hub(state)
    _result = publish_locally(state.hub, event)
    {:noreply, state}
  end

  defp resolve_hub(%{hub: nil} = state) do
    case List.keyfind(Supervisor.which_children(state.supervisor), Hub, 0) do
      {Hub, hub, :worker, _modules} when is_pid(hub) ->
        %{state | hub: hub, hub_monitor: Process.monitor(hub)}

      _unavailable ->
        state
    end
  end

  defp resolve_hub(state), do: state

  defp publish_locally(nil, _event), do: {:error, :unavailable}

  defp publish_locally(hub, event) do
    Hub.publish(hub, event)
  catch
    :exit, _reason -> {:error, :unavailable}
  end
end
