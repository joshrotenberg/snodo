defmodule Examples.DistributedSubscriptions.Bridge do
  @moduledoc false

  use GenServer

  alias Snodo.Subscription.Hub

  @scope Examples.DistributedSubscriptions.Scope
  @group {__MODULE__, :events}

  def start_link(opts) do
    hub = Keyword.fetch!(opts, :hub)
    GenServer.start_link(__MODULE__, hub, Keyword.take(opts, [:name]))
  end

  def publish(bridge, event), do: GenServer.call(bridge, {:publish, event})

  @impl GenServer
  def init(hub) do
    :ok = :pg.join(@scope, @group, self())
    {:ok, hub}
  end

  @impl GenServer
  def handle_call({:publish, event}, _from, hub) do
    case Hub.publish(hub, event) do
      {:ok, report} ->
        @scope
        |> :pg.get_members(@group)
        |> Enum.reject(&(&1 == self()))
        |> Enum.each(&send(&1, {:subscription_event, event}))

        {:reply, {:ok, report}, hub}

      {:error, _reason} = error ->
        {:reply, error, hub}
    end
  end

  @impl GenServer
  def handle_info({:subscription_event, event}, hub) do
    _result = Hub.publish(hub, event)
    {:noreply, hub}
  end
end

defmodule Examples.DistributedSubscriptions.Runner do
  @moduledoc false

  alias Examples.DistributedSubscriptions.Bridge
  alias Snodo.Context
  alias Snodo.Subscription.Event
  alias Snodo.Subscription.Hub
  alias Snodo.Transport.Context, as: TransportContext

  def run(mode) do
    {:ok, scope} = :pg.start_link(Examples.DistributedSubscriptions.Scope)
    {:ok, first_hub} = Hub.start_link(max_buffer: 2)
    {:ok, second_hub} = Hub.start_link(max_buffer: 2)
    {:ok, first_bridge} = Bridge.start_link(hub: first_hub)
    {:ok, second_bridge} = Bridge.start_link(hub: second_hub)

    try do
      exercise(first_hub, second_hub, first_bridge, second_bridge)
      print_summary(mode)
    after
      Enum.each([first_bridge, second_bridge, first_hub, second_hub, scope], fn pid ->
        if Process.alive?(pid), do: GenServer.stop(pid)
      end)
    end
  end

  defp exercise(first_hub, second_hub, first_bridge, second_bridge) do
    context = %Context{
      request_id: "distributed-example",
      protocol_version: "2026-07-28",
      protocol: Snodo.Protocol.V2026_07_28,
      transport: %TransportContext{transport: :direct}
    }

    tools_filter = %{"toolsListChanged" => true}
    {:ok, ^tools_filter, first} = Hub.open(tools_filter, context, first_hub)
    {:ok, ^tools_filter, second} = Hub.open(tools_filter, context, second_hub)

    resource_filter = %{"resourceSubscriptions" => ["demo://status"]}
    {:ok, ^resource_filter, unrelated} = Hub.open(resource_filter, context, second_hub)

    pulls = for handle <- [first, second], do: Task.async(fn -> Hub.next(handle, nil) end)
    event = Event.tools_list_changed()
    {:ok, %{matched: 1}} = Bridge.publish(first_bridge, event)

    Enum.each(pulls, fn pull ->
      {:ok, ^event} = Task.await(pull, 1_000)
    end)

    {:error, {:invalid_event, _reason}} =
      Bridge.publish(first_bridge, Event.resource_updated("relative-uri"))

    resource_pull = Task.async(fn -> Hub.next(unrelated, nil) end)
    resource_event = Event.resource_updated("demo://status")
    {:ok, %{matched: 1}} = Bridge.publish(second_bridge, resource_event)
    {:ok, ^resource_event} = Task.await(resource_pull, 1_000)

    %{queued: 0} = Hub.stats(first_hub)
    %{queued: 0} = Hub.stats(second_hub)

    Enum.each([{first, first_hub}, {second, second_hub}, {unrelated, second_hub}], fn
      {handle, hub} -> :ok = Hub.close(handle, :complete, hub)
    end)
  end

  defp print_summary(:check), do: IO.puts("27_distributed_subscriptions: ok")

  defp print_summary(:walkthrough) do
    IO.puts("One event reached listeners on both local hubs through a shared :pg group.")
    IO.puts("Each hub applied its own subscription filters.")
  end
end

case System.argv() do
  ["--check"] -> Examples.DistributedSubscriptions.Runner.run(:check)
  [] -> Examples.DistributedSubscriptions.Runner.run(:walkthrough)
  _arguments -> raise "usage: mix run examples/27_distributed_subscriptions.exs [--check]"
end
