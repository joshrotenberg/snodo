defmodule Snodo.Compliance.StdioRegressionVectorsTest do
  use ExUnit.Case, async: true

  alias Snodo.Protocol.V2025_11_25
  alias Snodo.Subscription.Hub
  alias Snodo.Transport.Stdio
  alias SnodoTest.TestFixtures
  alias SnodoTest.TestInput
  alias SnodoTest.TestTools.Trapping

  @modern_meta %{
    "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
    "io.modelcontextprotocol/clientCapabilities" => %{}
  }
  @subscription_id "io.modelcontextprotocol/subscriptionId"

  test "cancelling numeric request ID 7 leaves string request ID \"7\" in flight" do
    token = Integer.to_string(System.unique_integer([:positive]))
    :yes = :global.register_name({Trapping, token}, self())
    on_exit(fn -> :global.unregister_name({Trapping, token}) end)

    {input, server} = connect(TestFixtures.runtime(tools: [Trapping]))

    # Hold each request in flight before sending the next message.
    [{numeric_worker, numeric_cancellation}, {string_worker, string_cancellation}] =
      for id <- [7, "7"] do
        push(input, %{
          "jsonrpc" => "2.0",
          "id" => id,
          "method" => "tools/call",
          "params" => %{
            "_meta" => @modern_meta,
            "name" => "trapping",
            "arguments" => %{"token" => token}
          }
        })

        assert_receive {:trapping_entered, worker, cancellation}
        {worker, cancellation}
      end

    monitor = Process.monitor(numeric_worker)

    push(input, %{
      "jsonrpc" => "2.0",
      "method" => "notifications/cancelled",
      "params" => %{"requestId" => 7}
    })

    assert_receive {:DOWN, ^monitor, :process, ^numeric_worker, _reason}
    assert Snodo.Cancellation.cancelled?(numeric_cancellation)
    refute Snodo.Cancellation.cancelled?(string_cancellation)

    send(string_worker, :finish)

    assert_receive {:stdout,
                    %{"id" => "7", "result" => %{"content" => [%{"text" => "finished"}]}}}

    finish(input, server)
  end

  test "a rejected discovery probe leaves the same stdio connection ready to initialize" do
    {input, server} = connect(TestFixtures.runtime(tools: [], protocols: [V2025_11_25]))

    push(input, %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "server/discover",
      "params" => %{"_meta" => @modern_meta}
    })

    assert_receive {:stdout, %{"id" => 1, "error" => %{"code" => -32_600}}}

    push(input, %{
      "jsonrpc" => "2.0",
      "id" => 2,
      "method" => "initialize",
      "params" => %{
        "protocolVersion" => "2025-11-25",
        "capabilities" => %{},
        "clientInfo" => %{"name" => "fallback-vector", "version" => "1"}
      }
    })

    assert_receive {:stdout, %{"id" => 2, "result" => %{"protocolVersion" => "2025-11-25"}}}

    push(input, %{"jsonrpc" => "2.0", "method" => "notifications/initialized"})
    push(input, %{"jsonrpc" => "2.0", "id" => 3, "method" => "ping"})

    assert_receive {:stdout, %{"id" => 3, "result" => %{}}}
    finish(input, server)
  end

  test "two listen requests for the same URI each receive one correlated update" do
    hub = start_supervised!(Hub)

    runtime =
      TestFixtures.runtime(
        capabilities: %{"resources" => %{"subscribe" => true}},
        subscription_source: Hub.source(hub)
      )

    {input, server} = connect(runtime)
    uri = "test://resource/shared"
    filter = %{"resourceSubscriptions" => [uri]}

    for id <- [1, 2] do
      push(input, %{
        "jsonrpc" => "2.0",
        "id" => id,
        "method" => "subscriptions/listen",
        "params" => %{"_meta" => @modern_meta, "notifications" => filter}
      })

      assert_receive {:stdout,
                      %{
                        "method" => "notifications/subscriptions/acknowledged",
                        "params" => %{
                          "_meta" => %{@subscription_id => ^id},
                          "notifications" => ^filter
                        }
                      }}
    end

    assert {:ok, %{matched: 2}} = Hub.notify_resource_updated(hub, uri)

    for id <- [1, 2] do
      assert_receive {:stdout,
                      %{
                        "method" => "notifications/resources/updated",
                        "params" => %{"_meta" => %{@subscription_id => ^id}, "uri" => ^uri}
                      }}
    end

    assert :ok = Hub.complete(hub)

    for id <- [1, 2] do
      assert_receive {:stdout, %{"id" => ^id, "result" => %{"resultType" => "complete"}}}
    end

    finish(input, server)
  end

  defp connect(runtime) do
    {:ok, input} = TestInput.start_link()
    owner = self()
    output = start_supervised!({Task, fn -> forward_output(owner) end})
    server = Task.async(fn -> Stdio.serve(runtime, input: input, output: output) end)
    {input, server}
  end

  defp forward_output(owner) do
    receive do
      {:io_request, from, reply_as, {:put_chars, _encoding, data}} ->
        send(owner, {:stdout, data |> IO.iodata_to_binary() |> JSON.decode!()})
        send(from, {:io_reply, reply_as, :ok})
        forward_output(owner)
    end
  end

  defp push(input, message), do: TestInput.push(input, JSON.encode!(message) <> "\n")

  defp finish(input, server) do
    TestInput.eof(input)
    assert :ok = Task.await(server)
    refute_received {:stdout, _message}
  end
end
