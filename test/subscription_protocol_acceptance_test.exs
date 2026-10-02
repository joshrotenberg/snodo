defmodule SnodoTest.OverclaimingSubscriptionSource do
  @behaviour Snodo.Subscription.Source

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

defmodule SnodoTest.ContextRecordingSubscriptionSource do
  @behaviour Snodo.Subscription.Source

  @impl true
  def open(filter, context, owner) do
    send(owner, {:subscription_open_context, context})
    {:ok, filter, owner}
  end

  @impl true
  def next(_handle, _options), do: :closed

  @impl true
  def close(_handle, _reason, _options), do: :ok
end

defmodule SnodoTest.SubscriptionPrincipal do
  @moduledoc false
  defstruct [:name, :scope]
end

defmodule Snodo.SubscriptionProtocolAcceptanceTest do
  use ExUnit.Case, async: true

  alias Snodo.Context
  alias Snodo.Protocol.V2026_07_28
  alias Snodo.Subscription
  alias Snodo.Subscription.Event
  alias Snodo.Subscription.Source
  alias Snodo.Test, as: MCPTest
  alias Snodo.Transport.Context, as: TransportContext
  alias SnodoTest.ContextRecordingSubscriptionSource
  alias SnodoTest.SubscriptionPrincipal
  alias SnodoTest.TestFixtures
  alias SnodoTest.TestSubscriptionHub
  alias SnodoTest.TestSubscriptionSource

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
        subscription_source: {SnodoTest.OverclaimingSubscriptionSource, self()}
      )

    assert {:ok, %{"error" => %{"code" => -32_603}}} =
             MCPTest.dispatch(runtime,
               id: "overclaim",
               protocol: "2026-07-28",
               method: "subscriptions/listen",
               params: %{"notifications" => %{"toolsListChanged" => true}}
             )

    assert_receive {:overclaiming_source_closed, {:error, %Snodo.Error{}}}
  end

  test "an open subscription keeps its accepted filter, not the request's other params" do
    {:ok, hub} = start_supervised({TestSubscriptionHub, owner: self()})
    long_uri = "test://resource/" <> String.duplicate("a", 100)

    # Decoding makes strings longer than 64 bytes into sub-binaries of the body.
    notifications = %{"toolsListChanged" => true, "resourceSubscriptions" => [long_uri]}

    params =
      JSON.decode!(
        JSON.encode!(%{
          "notifications" => notifications,
          "inputResponses" => %{"unused" => %{"action" => "accept"}},
          "requestState" => "unused",
          "padding" => String.duplicate("x", 100_000)
        })
      )

    [decoded_uri] = params["notifications"]["resourceSubscriptions"]
    assert :binary.referenced_byte_size(decoded_uri) > byte_size(decoded_uri)

    assert {:stream, subscription} =
             MCPTest.dispatch(runtime(hub),
               id: "sub-retained",
               protocol: "2026-07-28",
               method: "subscriptions/listen",
               params: params
             )

    assert subscription.accepted_filter == notifications

    [uri] = subscription.accepted_filter["resourceSubscriptions"]
    assert :binary.referenced_byte_size(uri) == byte_size(uri)
    assert subscription.context.request_params == %{}
    assert subscription.context.input_responses == %{}
    assert subscription.context.request_state == nil
    assert subscription.context.request_method == "subscriptions/listen"

    assert_receive {:subscription_opened, "sub-retained", opened_filter}
    [opened] = opened_filter["resourceSubscriptions"]
    assert :binary.referenced_byte_size(opened) == byte_size(opened)

    assert :ok = Subscription.close(subscription, :complete)
  end

  test "an open subscription drops request-only context after the source opens" do
    decoded =
      %{
        "metadata" => String.duplicate("m", 100),
        "method" => "subscriptions/listen",
        "capabilities" => String.duplicate("c", 100),
        "header" => String.duplicate("h", 100),
        "extension" => String.duplicate("e", 100),
        "padding" => String.duplicate("x", 100_000)
      }
      |> JSON.encode!()
      |> JSON.decode!()

    assert :binary.referenced_byte_size(decoded["extension"]) > 100_000
    assert :binary.referenced_byte_size(decoded["header"]) > 100_000

    context = %Context{
      protocol_version: "2026-07-28",
      protocol: V2026_07_28,
      transport: %TransportContext{
        transport: :direct,
        request_headers: %{"x-padding" => decoded["header"]},
        metadata: %{request_data: decoded["metadata"]}
      },
      request_id: "sub-retained-context",
      request_method: decoded["method"],
      request_params: %{"padding" => decoded["padding"]},
      client_info: %{"padding" => decoded["capabilities"]},
      client_capabilities: %{"padding" => decoded["capabilities"]},
      metadata: %{"padding" => decoded["metadata"]},
      extensions: %{"test.extension" => %{"value" => decoded["extension"]}},
      server_info: %{"name" => "test", "version" => "1"},
      server_capabilities: %{"tools" => %{"listChanged" => true}},
      auth: %{
        principal: %SubscriptionPrincipal{
          name: decoded["header"],
          scope: {:scope, decoded["extension"]}
        }
      }
    }

    source = Source.normalize!({ContextRecordingSubscriptionSource, self()})

    assert {:ok, subscription} =
             Subscription.open(source, %{"toolsListChanged" => true}, context)

    assert_receive {:subscription_open_context, ^context}, 1_000
    assert subscription.context.request_params == %{}
    assert subscription.context.client_info == nil
    assert subscription.context.client_capabilities == %{}
    assert subscription.context.metadata == %{}
    assert subscription.context.transport == %TransportContext{transport: :direct}
    assert subscription.context.request_method == "subscriptions/listen"

    assert :binary.referenced_byte_size(subscription.context.request_method) < 1_000

    assert subscription.context.server_info == context.server_info
    assert subscription.context.auth == context.auth

    assert %SubscriptionPrincipal{name: name, scope: {:scope, scope}} =
             subscription.context.auth.principal

    assert :binary.referenced_byte_size(name) < 1_000
    assert :binary.referenced_byte_size(scope) < 1_000

    retained = subscription.context.extensions["test.extension"]["value"]
    assert retained == decoded["extension"]
    assert :binary.referenced_byte_size(retained) < 1_000

    assert {:ok, _acknowledgement} = Subscription.acknowledgement(subscription)
    assert {:ok, _completion} = Subscription.completion(subscription)
    assert :ok = Subscription.close(subscription, :complete)
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
