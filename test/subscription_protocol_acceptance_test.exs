defmodule MCPEx.OverclaimingSubscriptionSource do
  @behaviour MCP.Subscription.Source

  @impl true
  def open(_filter, _context, owner) do
    {:ok, %{"promptsListChanged" => true}, owner}
  end

  @impl true
  def next(_handle, _options), do: :closed

  @impl true
  def close(owner, reason, _options) do
    send(owner, {:overclaiming_source_closed, reason})
    :ok
  end
end

defmodule MCP.SubscriptionProtocolAcceptanceTest do
  use ExUnit.Case, async: true

  alias MCP.Subscription
  alias MCP.Subscription.Event
  alias MCP.Test, as: MCPTest
  alias MCPEx.TestFixtures
  alias MCPEx.TestSubscriptionHub
  alias MCPEx.TestSubscriptionSource

  @subscription_id_key "io.modelcontextprotocol/subscriptionId"

  @tag mcp_contract: ["subscriptions-listen-wire", "subscriptions-source-lifecycle"]
  test "direct dispatch negotiates a truthful filter and shapes the full stream lifecycle" do
    {:ok, hub} = start_supervised({TestSubscriptionHub, owner: self()})
    runtime = runtime(hub)

    assert {:stream, subscription} =
             MCPTest.dispatch(runtime,
               id: "sub-direct",
               protocol: "2026-07-28",
               method: "subscriptions/listen",
               params: %{
                 "notifications" => %{
                   "toolsListChanged" => true,
                   "promptsListChanged" => true,
                   "resourcesListChanged" => false,
                   "resourceSubscriptions" => ["test://resource/one"]
                 }
               }
             )

    assert_receive {:subscription_opened, "sub-direct", accepted}

    assert accepted == %{
             "toolsListChanged" => true,
             "resourceSubscriptions" => ["test://resource/one"]
           }

    assert {:ok, acknowledgement} = Subscription.acknowledgement(subscription)

    assert acknowledgement == %{
             "jsonrpc" => "2.0",
             "method" => "notifications/subscriptions/acknowledged",
             "params" => %{
               "_meta" => %{@subscription_id_key => "sub-direct"},
               "notifications" => accepted
             }
           }

    assert {:ok, resource_notification} =
             Subscription.notification(
               subscription,
               Event.resource_updated("test://resource/one", metadata: %{"com.example/seq" => 1})
             )

    assert resource_notification["method"] == "notifications/resources/updated"
    assert resource_notification["params"]["uri"] == "test://resource/one"

    assert resource_notification["params"]["_meta"] == %{
             "com.example/seq" => 1,
             @subscription_id_key => "sub-direct"
           }

    assert :drop =
             Subscription.notification(
               subscription,
               Event.resource_updated("test://resource/unrequested")
             )

    assert :drop = Subscription.notification(subscription, Event.prompts_list_changed())

    assert {:ok, completion} = Subscription.completion(subscription)
    assert completion["id"] == "sub-direct"
    assert get_in(completion, ["result", "resultType"]) == "complete"
    assert get_in(completion, ["result", "_meta", @subscription_id_key]) == "sub-direct"

    assert :ok = Subscription.close(subscription, :complete)
    assert_receive {:subscription_closed, "sub-direct", :complete}
  end

  test "filter validation and source advertisement fail closed" do
    assert_raise ArgumentError, ~r/configured subscription_source/, fn ->
      TestFixtures.runtime(capabilities: %{"tools" => %{"listChanged" => true}})
    end

    {:ok, hub} = start_supervised({TestSubscriptionHub, owner: self()})
    configured = runtime(hub)

    assert configured.capabilities == %{
             "tools" => %{"listChanged" => true},
             "resources" => %{"subscribe" => true}
           }

    invalid_filters = [
      %{},
      %{"notifications" => []},
      %{"notifications" => %{"toolsListChanged" => "yes"}},
      %{"notifications" => %{"resourceSubscriptions" => "test://resource/one"}},
      %{"notifications" => %{"resourceSubscriptions" => ["relative/path"]}}
    ]

    Enum.each(invalid_filters, fn params ->
      assert {:ok, %{"error" => %{"code" => -32_602}}} =
               MCPTest.dispatch(configured,
                 id: "invalid-filter",
                 protocol: "2026-07-28",
                 method: "subscriptions/listen",
                 params: params
               )
    end)

    unconfigured = TestFixtures.runtime()

    assert {:ok, %{"error" => %{"code" => -32_601}}} =
             MCPTest.dispatch(unconfigured,
               id: "no-source",
               protocol: "2026-07-28",
               method: "subscriptions/listen",
               params: %{"notifications" => %{}}
             )
  end

  test "an overclaiming source is rejected and its opened handle is closed" do
    runtime =
      TestFixtures.runtime(
        capabilities: %{"tools" => %{"listChanged" => true}},
        subscription_source: {MCPEx.OverclaimingSubscriptionSource, self()}
      )

    assert {:ok, %{"error" => %{"code" => -32_603}}} =
             MCPTest.dispatch(runtime,
               id: "overclaim",
               protocol: "2026-07-28",
               method: "subscriptions/listen",
               params: %{"notifications" => %{"toolsListChanged" => true}}
             )

    assert_receive {:overclaiming_source_closed, {:error, %MCP.Error{}}}
  end

  defp runtime(hub) do
    TestFixtures.runtime(
      capabilities: %{
        "tools" => %{"listChanged" => true},
        "resources" => %{"subscribe" => true}
      },
      subscription_source: {TestSubscriptionSource, hub}
    )
  end
end
