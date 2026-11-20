defmodule SnodoTest.SubscriptionBridge do
  @moduledoc false

  import ExUnit.Assertions

  alias Snodo.Subscription
  alias Snodo.Subscription.Bridge
  alias Snodo.Test, as: MCPTest
  alias SnodoTest.TestFixtures

  def listen(bridge) do
    runtime =
      TestFixtures.runtime(
        capabilities: %{"tools" => %{"listChanged" => true}},
        subscription_source: Bridge.source(bridge)
      )

    _ =
      assert {:stream, subscription} =
               MCPTest.dispatch(runtime,
                 id: "bridge-listen",
                 protocol: "2026-07-28",
                 method: "subscriptions/listen",
                 params: %{"notifications" => %{"toolsListChanged" => true}}
               )

    _ =
      assert {:ok, %{"method" => "notifications/subscriptions/acknowledged"}} =
               Subscription.acknowledgement(subscription)

    subscription
  end

  def await_members(scope, group, count, excluded \\ [], timeout \\ 5_000) do
    {ref, members} = :pg.monitor(scope, group)

    try do
      await_membership(ref, group, MapSet.new(members), {count, excluded, timeout})
    after
      :pg.demonitor(scope, ref)
    end
  end

  defp await_membership(ref, group, members, {count, excluded, timeout} = wanted) do
    if MapSet.size(members) == count and Enum.all?(excluded, &(not MapSet.member?(members, &1))) do
      MapSet.to_list(members)
    else
      receive do
        {^ref, :join, ^group, joined} ->
          await_membership(ref, group, MapSet.union(members, MapSet.new(joined)), wanted)

        {^ref, :leave, ^group, left} ->
          await_membership(ref, group, MapSet.difference(members, MapSet.new(left)), wanted)
      after
        timeout ->
          flunk("expected #{count} members of #{inspect(group)}, got #{inspect(members)}")
      end
    end
  end
end
