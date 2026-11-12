defmodule Snodo.SubscriptionBridgeTest do
  use ExUnit.Case, async: true

  alias Snodo.Subscription
  alias Snodo.Subscription.Bridge
  alias Snodo.Subscription.Event
  alias Snodo.Subscription.Hub
  alias SnodoTest.SubscriptionBridge, as: Helpers

  setup context do
    scope = :"#{__MODULE__}.#{context.test}"
    {:ok, scope: scope, group: :events}
  end

  test "forwards once, validates events, filters, and retains each hub's queue policy", config do
    first = start_bridge(config, :first, hub_options: [max_buffer: 1])

    second =
      start_bridge(config, :second,
        hub_options: [
          max_buffer: 1,
          overflow: :drop_newest,
          instrumentation: {SnodoTest.TestInstrumentationSink, self()}
        ]
      )

    first_stream = Helpers.listen(first)
    second_stream = Helpers.listen(second)
    first_event = Event.tools_list_changed(metadata: %{"seq" => 1})
    second_event = Event.tools_list_changed(metadata: %{"seq" => 2})

    assert {:ok, %{matched: 1, buffered: 1, dropped: 0}} = Bridge.publish(first, first_event)
    assert {:ok, %{matched: 1, buffered: 1, dropped: 1}} = Bridge.publish(first, second_event)
    assert {:ok, %{matched: 0}} = Bridge.publish(first, Event.prompts_list_changed())
    assert {:error, {:invalid_event, _message}} = Bridge.publish(first, :invalid)

    assert {:error, {:invalid_event, _message}} =
             Bridge.publish(first, Event.resource_updated("relative"))

    assert_receive {:instrumentation, [:snodo, :subscription, :overflow],
                    %{dropped: 1, queued: 1}, %{policy: :drop_newest}},
                   1_000

    assert %{queued: 1, dropped: 1} = Hub.stats(hub(second))
    assert %{queued: 1, dropped: 1} = Hub.stats(hub(first))

    assert {:ok, ^second_event} = Bridge.next(first_stream.handle, first)
    assert {:ok, ^first_event} = Bridge.next(second_stream.handle, second)
    assert :ok = Subscription.close(first_stream, :cancelled)
    assert :ok = Subscription.close(second_stream, :cancelled)
  end

  test "leaves an existing scope alive when stopped", config do
    scope = start_supervised!(%{id: :scope, start: {:pg, :start_link, [config.scope]}})
    bridge = start_bridge(config, :bridge, start_scope: false)
    assert [member] = :pg.get_members(config.scope, config.group)
    monitor = Process.monitor(member)
    assert :ok = stop_supervised(:bridge)
    assert_receive {:DOWN, ^monitor, :process, ^member, :shutdown}, 1_000
    assert Process.alive?(scope)
    assert :pg.get_members(config.scope, config.group) == []
    refute Process.alive?(bridge)
  end

  @tag :capture_log
  test "a rest_for_one parent restarts the external scope before its bridge", config do
    children = [
      %{id: :scope, start: {:pg, :start_link, [config.scope]}},
      {Bridge, name: nil, scope: config.scope, group: config.group, start_scope: false}
    ]

    owner =
      start_supervised!(%{
        id: :scope_owner,
        type: :supervisor,
        start: {Supervisor, :start_link, [children, [strategy: :rest_for_one]]}
      })

    scope = Process.whereis(config.scope)

    {Bridge, old_bridge, :supervisor, _modules} =
      List.keyfind(Supervisor.which_children(owner), Bridge, 0)

    old_hub = hub(old_bridge)
    old_worker = worker(old_bridge)
    monitor = Process.monitor(old_bridge)
    Process.exit(scope, :kill)

    assert_receive {:DOWN, ^monitor, :process, ^old_bridge, :shutdown}, 1_000

    {Bridge, bridge, :supervisor, _modules} =
      List.keyfind(Supervisor.which_children(owner), Bridge, 0)

    replacement = Process.whereis(config.scope)
    refute bridge == old_bridge
    refute replacement == scope
    assert {:links, links} = Process.info(replacement, :links)
    assert owner in links
    refute bridge in links
    refute hub(bridge) == old_hub
    assert [new_worker] = Helpers.await_members(config.scope, config.group, 1, [old_worker])
    refute new_worker == old_worker
    assert {:ok, %{matched: 0}} = Bridge.publish(bridge, Event.tools_list_changed())
    assert :ok = Supervisor.terminate_child(owner, Bridge)
    assert Process.alive?(replacement)
    assert Process.alive?(owner)
  end

  @tag :capture_log
  test "fails promptly and exhausts restart intensity when an external scope never returns",
       config do
    {:ok, scope} = :pg.start_link(config.scope)
    Process.unlink(scope)
    {:ok, bridge} = Bridge.start_link(name: nil, scope: config.scope, start_scope: false)
    Process.unlink(bridge)

    on_exit(fn ->
      if Process.alive?(bridge), do: Process.exit(bridge, :kill)
      if Process.alive?(scope), do: Process.exit(scope, :kill)
    end)

    bridge_monitor = Process.monitor(bridge)
    old_worker = worker(bridge)
    worker_monitor = Process.monitor(old_worker)
    Process.exit(scope, :kill)
    assert_receive {:DOWN, ^worker_monitor, :process, ^old_worker, :shutdown}

    publication = Task.async(fn -> Bridge.publish(bridge, Event.tools_list_changed()) end)
    ref = publication.ref
    assert_receive {^ref, {:error, :unavailable}}
    assert_receive {:DOWN, ^ref, :process, _caller, :normal}
    assert_receive {:DOWN, ^bridge_monitor, :process, ^bridge, :shutdown}

    context = %Snodo.Context{
      protocol_version: "2026-07-28",
      protocol: Snodo.Protocol.V2026_07_28,
      transport: %Snodo.Transport.Context{transport: :direct}
    }

    assert {:error, :unavailable} = Bridge.open(%{}, context, bridge)
    assert Process.whereis(config.scope) == nil
  end

  @tag :capture_log
  test "fails when an external scope has not been started", config do
    Process.flag(:trap_exit, true)
    assert {:error, {:scope_not_started, scope}} = Bridge.Scope.start_link({config.scope, false})
    assert scope == config.scope

    assert {:error, {:shutdown, {:failed_to_start_child, Bridge.Scope, reason}}} =
             Bridge.start_link(name: nil, scope: config.scope, start_scope: false)

    assert reason == {:scope_not_started, scope}

    assert Process.whereis(scope) == nil
  end

  test "returns unavailable for stopped children and a stopped supervisor", config do
    context = %Snodo.Context{
      protocol_version: "2026-07-28",
      protocol: Snodo.Protocol.V2026_07_28,
      transport: %Snodo.Transport.Context{transport: :direct}
    }

    bridge = start_bridge(config, :bridge)
    event = Event.tools_list_changed()

    assert :ok = Supervisor.terminate_child(bridge, Bridge.Worker)
    assert {:error, :unavailable} = Bridge.publish(bridge, event)
    assert :ok = Supervisor.terminate_child(bridge, Hub)
    assert {:error, :unavailable} = Bridge.open(%{}, context, bridge)

    assert {:ok, _hub} = Supervisor.restart_child(bridge, Hub)
    assert {:ok, _worker} = Supervisor.restart_child(bridge, Bridge.Worker)
    assert {:ok, %{matched: 0}} = Bridge.publish(bridge, event)
    assert {:ok, %{}, handle} = Bridge.open(%{}, context, bridge)
    assert :ok = Bridge.close(handle, :cancelled, bridge)

    assert :ok = stop_supervised(:bridge)
    assert {:error, :unavailable} = Bridge.publish(bridge, event)
    assert {:error, :unavailable} = Bridge.open(%{}, context, bridge)
  end

  test "rejoins after its hub or owned scope restarts and opens streams on the new hub", config do
    bridge = start_bridge(config, :bridge)
    source = Bridge.source(bridge)

    for target <- [hub(bridge), Process.whereis(config.scope)] do
      old_worker = worker(bridge)
      monitor = Process.monitor(old_worker)
      Process.exit(target, :kill)
      assert_receive {:DOWN, ^monitor, :process, ^old_worker, :shutdown}, 1_000
      assert is_pid(hub(bridge))
      assert [_new_worker] = Helpers.await_members(config.scope, config.group, 1, [old_worker])
      assert source == Bridge.source(bridge)
      subscription = Helpers.listen(bridge)
      assert {:ok, %{matched: 1}} = Bridge.publish(bridge, Event.tools_list_changed())
      assert {:ok, %Event{kind: :tools_list_changed}} = Bridge.next(subscription.handle, bridge)
      assert :ok = Subscription.close(subscription, :cancelled)
    end
  end

  test "rejects unknown options and invalid scope names" do
    assert_raise ArgumentError, ~r/unknown subscription bridge options/, fn ->
      Bridge.start_link(extra: true)
    end

    assert_raise ArgumentError, ~r/scope must be an atom/, fn ->
      Bridge.start_link(scope: "scope")
    end

    assert_raise ArgumentError, ~r/start_scope must be a boolean/, fn ->
      Bridge.start_link(start_scope: :external)
    end
  end

  defp start_bridge(config, id, opts \\ []) do
    start_supervised!(
      {Bridge, Keyword.merge([name: nil, scope: config.scope, group: config.group], opts)},
      id: id
    )
  end

  defp hub(bridge), do: child(bridge, Hub)
  defp worker(bridge), do: child(bridge, Bridge.Worker)

  defp child(bridge, module) do
    {^module, pid, :worker, _modules} =
      bridge |> Supervisor.which_children() |> List.keyfind(module, 0)

    pid
  end
end

defmodule Snodo.SubscriptionBridgeDefaultsTest do
  use ExUnit.Case, async: false

  alias Snodo.Subscription.Bridge
  alias Snodo.Subscription.Event
  alias Snodo.Subscription.Hub

  test "supplies a supervisor child spec and default scope, group, and hub options" do
    assert %{type: :supervisor, start: {Bridge, :start_link, [[]]}} = Bridge.child_spec([])
    bridge = start_supervised!(Bridge)
    assert Process.whereis(Bridge) == bridge
    assert Bridge.source() == {Bridge, Bridge}
    assert [_worker] = :pg.get_members(Bridge.PG, {Bridge, :events})
    {Hub, hub, :worker, _modules} = List.keyfind(Supervisor.which_children(bridge), Hub, 0)
    assert %{max_buffer: 100, overflow: :drop_oldest} = Hub.stats(hub)
    assert {:ok, %{matched: 0}} = Bridge.publish(Event.tools_list_changed())
  end
end

defmodule Snodo.SubscriptionBridgeDistributedTest do
  use ExUnit.Case, async: false

  alias Snodo.Subscription
  alias Snodo.Subscription.Bridge
  alias Snodo.Subscription.Event
  alias SnodoTest.SubscriptionBridge, as: Helpers

  @moduletag :distributed
  @moduletag timeout: 60_000
  @moduletag skip:
               if(Node.alive?(),
                 do: false,
                 else: "Erlang distribution unavailable; test/test_helper.exs could not start it"
               )

  setup context do
    scope = :"#{__MODULE__}.#{context.test}"
    group = :events
    bridge = start_supervised!({Bridge, name: nil, scope: scope, group: group})
    peer_name = :"snodo_bridge_peer_#{System.unique_integer([:positive])}"
    {:ok, bridge: bridge, scope: scope, group: group, peer_name: peer_name}
  end

  test "publishes on a peer into a subscriptions/listen stream on this node", config do
    {peer, remote_bridge, _node} = start_peer(config)
    subscription = Helpers.listen(config.bridge)
    {worker, monitor} = Subscription.start_worker(subscription, self())
    :ok = Subscription.continue(worker)
    event = Event.tools_list_changed(metadata: %{"origin" => "peer"})

    assert {:ok, %{matched: 0}} = :peer.call(peer, Bridge, :publish, [remote_bridge, event])
    assert_receive {:mcp_subscription, ^worker, {:ok, ^event}}, 5_000

    assert {:ok, %{"method" => "notifications/tools/list_changed", "params" => params}} =
             Subscription.notification(subscription, event)

    assert params["_meta"]["io.modelcontextprotocol/subscriptionId"] == "bridge-listen"
    assert :ok = Subscription.close(subscription, :cancelled)
    assert :ok = Subscription.stop_worker(worker, monitor)
  end

  test "removes a stopped node and rejoins when the same node restarts", config do
    {peer, remote_bridge, peer_node} = start_peer(config)
    subscription = Helpers.listen(config.bridge)
    {worker, monitor} = Subscription.start_worker(subscription, self())
    :ok = Subscription.continue(worker)
    before_restart = Event.tools_list_changed(metadata: %{"phase" => "before"})

    assert {:ok, _report} = :peer.call(peer, Bridge, :publish, [remote_bridge, before_restart])
    assert_receive {:mcp_subscription, ^worker, {:ok, ^before_restart}}, 5_000

    Node.monitor(peer_node, true)
    :ok = :peer.stop(peer)
    assert_receive {:nodedown, ^peer_node}, 5_000
    assert [local_worker] = Helpers.await_members(config.scope, config.group, 1)
    assert node(local_worker) == node()

    {new_peer, new_bridge, ^peer_node} = start_peer(config)
    after_restart = Event.tools_list_changed(metadata: %{"phase" => "after"})
    :ok = Subscription.continue(worker)
    assert {:ok, _report} = :peer.call(new_peer, Bridge, :publish, [new_bridge, after_restart])
    assert_receive {:mcp_subscription, ^worker, {:ok, ^after_restart}}, 5_000
    assert :ok = Subscription.close(subscription, :cancelled)
    assert :ok = Subscription.stop_worker(worker, monitor)
    Node.monitor(peer_node, false)
  end

  defp start_peer(config) do
    {:ok, peer, peer_node} =
      :peer.start(%{
        name: config.peer_name,
        connection: :standard_io,
        args: [~c"+S", ~c"2:2", ~c"-setcookie", Atom.to_charlist(Node.get_cookie())],
        wait_boot: 15_000
      })

    on_exit(fn -> if Process.alive?(peer), do: :peer.stop(peer) end)
    assert :ok = :peer.call(peer, :code, :add_paths, [:code.get_path()])
    assert {:ok, _apps} = :peer.call(peer, Application, :ensure_all_started, [:snodo])
    assert Node.connect(peer_node)

    assert {:ok, bridge} =
             :peer.call(peer, Supervisor, :start_child, [
               Snodo.Supervisor,
               {Bridge, name: nil, scope: config.scope, group: config.group}
             ])

    assert length(Helpers.await_members(config.scope, config.group, 2)) == 2

    assert length(:peer.call(peer, Helpers, :await_members, [config.scope, config.group, 2])) == 2
    {peer, bridge, peer_node}
  end
end
