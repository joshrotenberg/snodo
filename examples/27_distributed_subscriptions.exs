defmodule Examples.DistributedSubscriptions.Runner do
  @moduledoc false

  alias Snodo.Context
  alias Snodo.Subscription.Bridge
  alias Snodo.Subscription.Event
  alias Snodo.Subscription.Hub
  alias Snodo.Transport.Context, as: TransportContext

  def run(mode) do
    opts = [
      name: nil,
      scope: Examples.DistributedSubscriptions.Scope,
      hub_options: [max_buffer: 2]
    ]

    children = [
      Supervisor.child_spec({Bridge, opts}, id: :first),
      Supervisor.child_spec({Bridge, opts}, id: :second)
    ]

    {:ok, supervisor} = Supervisor.start_link(children, strategy: :one_for_one)
    children = Supervisor.which_children(supervisor)
    {:first, first, _, _} = List.keyfind(children, :first, 0)
    {:second, second, _, _} = List.keyfind(children, :second, 0)

    try do
      exercise(first, second)
      print_summary(mode)
    after
      Supervisor.stop(supervisor)
    end
  end

  defp exercise(first_bridge, second_bridge) do
    context = %Context{
      request_id: "distributed-example",
      protocol_version: "2026-07-28",
      protocol: Snodo.Protocol.V2026_07_28,
      transport: %TransportContext{transport: :direct}
    }

    tools_filter = %{"toolsListChanged" => true}
    {:ok, ^tools_filter, first} = Bridge.open(tools_filter, context, first_bridge)
    {:ok, ^tools_filter, second} = Bridge.open(tools_filter, context, second_bridge)

    resource_filter = %{"resourceSubscriptions" => ["demo://status"]}
    {:ok, ^resource_filter, unrelated} = Bridge.open(resource_filter, context, second_bridge)

    pulls = for handle <- [first, second], do: Task.async(fn -> Bridge.next(handle, nil) end)
    event = Event.tools_list_changed()
    {:ok, %{matched: 1}} = Bridge.publish(first_bridge, event)

    Enum.each(pulls, fn pull ->
      {:ok, ^event} = Task.await(pull, 1_000)
    end)

    {:error, {:invalid_event, _reason}} =
      Bridge.publish(first_bridge, Event.resource_updated("relative-uri"))

    resource_pull = Task.async(fn -> Bridge.next(unrelated, nil) end)
    resource_event = Event.resource_updated("demo://status")
    {:ok, %{matched: 1}} = Bridge.publish(second_bridge, resource_event)
    {:ok, ^resource_event} = Task.await(resource_pull, 1_000)

    %{queued: 0} = Hub.stats(elem(first, 0))
    %{queued: 0} = Hub.stats(elem(second, 0))

    Enum.each([first, second, unrelated], fn handle ->
      :ok = Bridge.close(handle, :complete, nil)
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
