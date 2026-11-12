defmodule Snodo.Subscription.Bridge do
  @moduledoc """
  A supervised `:pg` bridge between node-local subscription hubs.

  Start the same scope and group on each directly connected Erlang node that
  serves subscriptions. The child spec starts the scope, a local
  `Snodo.Subscription.Hub`, and a forwarding worker in that order under a
  `:rest_for_one` supervisor. If the scope already exists, it is monitored but
  remains owned by its original supervisor. Losing either scope or hub restarts
  the forwarding worker so it rejoins with a live hub.

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
    * `:group` - the `:pg` group term, defaulting to `#{inspect(@default_group)}`;
    * `:hub_options` - options passed to `Snodo.Subscription.Hub.start_link/1`,
      defaulting to `[]` (a buffer of 100 events per listener and `:drop_oldest`).

  Use the same scope and group names on every participating node. Different
  groups may share a scope. Stopping a bridge stops a scope it started, so
  supervise a shared scope separately when bridges have independent lifetimes.
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) when is_list(opts) do
    unknown = Keyword.keys(opts) -- [:name, :scope, :group, :hub_options]

    if unknown != [] do
      raise ArgumentError, "unknown subscription bridge options: #{inspect(Enum.uniq(unknown))}"
    end

    scope = Keyword.get(opts, :scope, @default_scope)

    unless is_atom(scope) and not is_nil(scope) do
      raise ArgumentError, "subscription bridge scope must be an atom other than nil"
    end

    config = %{
      scope: scope,
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
  and is not acknowledged or replayed.
  """
  @spec publish(Supervisor.supervisor(), Event.t()) ::
          {:ok, Hub.delivery_report()} | {:error, {:invalid_event, String.t()}}
  def publish(bridge \\ __MODULE__, event) do
    GenServer.call(child(bridge, __MODULE__.Worker), {:publish, event})
  end

  @impl Snodo.Subscription.Source
  def open(filter, context, bridge), do: Hub.open(filter, context, child(bridge, Hub))

  @impl Snodo.Subscription.Source
  def next(handle, _bridge), do: Hub.next(handle, nil)

  @impl Snodo.Subscription.Source
  def close(handle, reason, _bridge), do: Hub.close(handle, reason, nil)

  @impl Supervisor
  def init(config) do
    children = [
      {__MODULE__.Scope, config.scope},
      {Hub, config.hub_options},
      {__MODULE__.Worker, {self(), config.scope, config.group}}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end

  defp child(bridge, id) do
    bridge
    |> Supervisor.which_children()
    |> Enum.find_value(fn
      {^id, pid, _type, _modules} when is_pid(pid) -> pid
      _child -> nil
    end)
  end
end

defmodule Snodo.Subscription.Bridge.Scope do
  @moduledoc false

  use GenServer

  @doc false
  def start_link(scope) do
    case :pg.start_link(scope) do
      {:error, {:already_started, pid}} -> GenServer.start_link(__MODULE__, pid)
      result -> result
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
    {:ok, %{scope: scope, group: group, hub: nil}, {:continue, supervisor}}
  end

  @impl GenServer
  def handle_continue(supervisor, state) do
    children = Supervisor.which_children(supervisor)
    {Hub, hub, :worker, _modules} = List.keyfind(children, Hub, 0)
    {:noreply, %{state | hub: hub}}
  end

  @impl GenServer
  def handle_call({:publish, event}, _from, state) do
    case Hub.publish(state.hub, event) do
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
  def handle_info({:subscription_event, event}, state) do
    _result = Hub.publish(state.hub, event)
    {:noreply, state}
  end
end
