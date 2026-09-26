defmodule Snodo.Transport.StdioAcceptanceTest do
  use ExUnit.Case, async: true

  alias Snodo.Server.Executor
  alias Snodo.Subscription.Event
  alias Snodo.Transport.Stdio
  alias SnodoTest.TestFixtures
  alias SnodoTest.TestInput
  alias SnodoTest.TestSubscriptionHub
  alias SnodoTest.TestSubscriptionSource
  alias SnodoTest.TestTools.Echo
  alias SnodoTest.TestTools.Trapping

  test "empty input always shuts down cleanly" do
    runtime = TestFixtures.runtime()

    for _ <- 1..100 do
      assert serve(runtime, "") == []
    end
  end

  test "serves CRLF-framed requests and emits only complete JSON lines" do
    runtime = TestFixtures.runtime()

    requests = [
      TestFixtures.request("a", "tools/call", %{
        "name" => "echo",
        "arguments" => %{"text" => "one"}
      }),
      TestFixtures.request("b", "tools/call", %{
        "name" => "echo",
        "arguments" => %{"text" => "two"}
      })
    ]

    input = Enum.map_join(requests, "", &(JSON.encode!(&1) <> "\r\n"))
    responses = serve(runtime, input)

    assert Enum.sort(Enum.map(responses, & &1["id"])) == ["a", "b"]
    assert Enum.all?(responses, &(&1["jsonrpc"] == "2.0"))
  end

  test "malformed JSON and batches produce errors without poisoning later lines" do
    runtime = TestFixtures.runtime()
    valid = TestFixtures.request(3, "tools/list")
    input = "{not-json}\n[]\n" <> JSON.encode!(valid) <> "\n"

    responses = serve(runtime, input)

    codes =
      responses
      |> Enum.filter(&Map.has_key?(&1, "error"))
      |> Enum.map(&get_in(&1, ["error", "code"]))

    assert -32_700 in codes
    assert -32_600 in codes
    assert Enum.any?(responses, &(&1["id"] == 3 and Map.has_key?(&1, "result")))
  end

  test "request execution is concurrent and response order follows completion" do
    runtime = TestFixtures.runtime()

    slow =
      TestFixtures.request("slow", "tools/call", %{
        "name" => "echo",
        "arguments" => %{"text" => "slow", "delayMs" => 200}
      })

    fast =
      TestFixtures.request("fast", "tools/call", %{
        "name" => "echo",
        "arguments" => %{"text" => "fast"}
      })

    [first, second] = serve(runtime, JSON.encode!(slow) <> "\n" <> JSON.encode!(fast) <> "\n")
    assert first["id"] == "fast"
    assert second["id"] == "slow"
  end

  test "bounded execution rejects work beyond configured capacity" do
    runtime = TestFixtures.runtime()

    slow =
      TestFixtures.request("slow", "tools/call", %{
        "name" => "echo",
        "arguments" => %{"text" => "slow", "delayMs" => 100}
      })

    excess =
      TestFixtures.request("excess", "tools/call", %{
        "name" => "echo",
        "arguments" => %{"text" => "excess"}
      })

    responses =
      serve(runtime, JSON.encode!(slow) <> "\n" <> JSON.encode!(excess) <> "\n",
        max_concurrency: 1,
        max_queue: 0
      )

    assert %{"result" => _result} = Enum.find(responses, &(&1["id"] == "slow"))

    assert %{"error" => %{"code" => -32_603}} =
             Enum.find(responses, &(&1["id"] == "excess"))
  end

  test "execution deadlines become request errors and do not hang EOF draining" do
    runtime = TestFixtures.runtime()

    request =
      TestFixtures.request("times-out", "tools/call", %{
        "name" => "echo",
        "arguments" => %{"text" => "late", "delayMs" => 200}
      })

    assert [%{"id" => "times-out", "error" => %{"code" => -32_603, "message" => message}}] =
             serve(runtime, JSON.encode!(request) <> "\n", request_timeout: 20)

    assert message == "Request execution timed out"
  end

  test "an injected executor remains application-owned after stdio exits" do
    runtime = TestFixtures.runtime()
    {:ok, executor} = start_supervised({Executor, default_timeout: :infinity})

    assert serve(runtime, "", executor: executor) == []
    assert Process.alive?(executor)
  end

  @tag capture_log: true
  test "an injected executor failure terminates stdio without hanging pending EOF" do
    runtime = TestFixtures.runtime(tools: [Echo, Trapping])
    token = Integer.to_string(System.unique_integer([:positive]))
    :yes = :global.register_name({Trapping, token}, self())

    on_exit(fn -> :global.unregister_name({Trapping, token}) end)

    {:ok, executor} = Executor.start_link(default_timeout: :infinity)
    Process.unlink(executor)

    on_exit(fn ->
      if Process.alive?(executor), do: GenServer.stop(executor)
    end)

    {:ok, input} = TestInput.start_link()
    {:ok, output} = StringIO.open("")

    server =
      Task.async(fn ->
        Stdio.serve(runtime, input: input, output: output, executor: executor)
      end)

    request =
      TestFixtures.request("executor-dies", "tools/call", %{
        "name" => "trapping",
        "arguments" => %{"token" => token}
      })

    TestInput.push(input, JSON.encode!(request) <> "\n")
    assert_receive {:trapping_entered, _worker, _cancellation}, 1_000
    TestInput.eof(input)
    Process.exit(executor, :shutdown)

    assert {:error, {:executor_down, :shutdown}} = Task.await(server, 1_000)

    {_remaining_input, raw_output} = StringIO.contents(output)

    assert %{"id" => "executor-dies", "error" => %{"code" => -32_603}} =
             raw_output |> String.trim() |> JSON.decode!()
  end

  @tag capture_log: true
  test "serve coordinator follows the serving caller lifecycle" do
    runtime = TestFixtures.runtime()
    {:ok, input} = TestInput.start_link()
    {:ok, output} = StringIO.open("")
    global_name = {__MODULE__, make_ref()}
    test_process = self()

    serving_caller =
      spawn(fn ->
        result =
          Stdio.serve(runtime,
            input: input,
            output: output,
            name: {:global, global_name}
          )

        send(test_process, {:unexpected_serve_return, result})
      end)

    coordinator = await_global_name(global_name)
    # The name is registered before init/1 monitors the caller; wait for init.
    _state = :sys.get_state(coordinator)
    coordinator_monitor = Process.monitor(coordinator)
    Process.exit(serving_caller, :kill)

    assert_receive {:DOWN, ^coordinator_monitor, :process, ^coordinator,
                    {:serve_owner_down, :killed}},
                   1_000

    refute_receive {:unexpected_serve_return, _result}, 20
  end

  @tag capture_log: true
  test "executor death during submit becomes a shaped error and clean shutdown" do
    runtime = TestFixtures.runtime()

    fake_executor =
      spawn(fn ->
        receive do
          {:"$gen_call", _from, {:submit, _key, _work, _reply_to, _timeout}} ->
            exit(:fake_executor_crash)
        end
      end)

    request = TestFixtures.request("submit-race", "tools/list")
    {:ok, io} = StringIO.open(JSON.encode!(request) <> "\n")

    assert :ok = Stdio.serve(runtime, input: io, output: io, executor: fake_executor)

    {_remaining_input, raw_output} = StringIO.contents(io)

    assert %{"id" => "submit-race", "error" => %{"code" => -32_603}} =
             raw_output |> String.trim() |> JSON.decode!()
  end

  @tag timeout: 15_000
  test "100 concurrent responses remain atomic JSON lines" do
    runtime = TestFixtures.runtime()

    input =
      1..100
      |> Enum.map(fn id ->
        TestFixtures.request(id, "tools/call", %{
          "name" => "echo",
          "arguments" => %{"text" => Integer.to_string(id), "delayMs" => rem(id, 7)}
        })
      end)
      |> Enum.map_join("", &(JSON.encode!(&1) <> "\n"))

    responses = serve(runtime, input)

    assert length(responses) == 100
    assert responses |> Enum.map(& &1["id"]) |> Enum.sort() == Enum.to_list(1..100)
  end

  test "stdio cancellation kills one request, drops its reply, and keeps serving" do
    runtime = TestFixtures.runtime(tools: [Echo, Trapping])
    token = Integer.to_string(System.unique_integer([:positive]))
    :yes = :global.register_name({Trapping, token}, self())

    on_exit(fn -> :global.unregister_name({Trapping, token}) end)

    {:ok, input} = TestInput.start_link()
    {:ok, output} = StringIO.open("")
    server = Task.async(fn -> Stdio.serve(runtime, input: input, output: output) end)

    slow =
      TestFixtures.request("cancel-me", "tools/call", %{
        "name" => "trapping",
        "arguments" => %{"token" => token}
      })

    invalid_cancel = %{
      "jsonrpc" => "2.0",
      "method" => "notifications/cancelled",
      "params" => %{"requestId" => "cancel-me", "reason" => %{"not" => "a string"}}
    }

    valid_cancel = put_in(invalid_cancel, ["params", "reason"], "test")

    reused_id =
      TestFixtures.request("cancel-me", "tools/call", %{
        "name" => "echo",
        "arguments" => %{"text" => "id reused"}
      })

    fast =
      TestFixtures.request("survives", "tools/call", %{
        "name" => "echo",
        "arguments" => %{"text" => "still alive"}
      })

    TestInput.push(input, JSON.encode!(slow) <> "\n")
    assert_receive {:trapping_entered, worker, cancellation}, 1_000

    TestInput.push(input, JSON.encode!(invalid_cancel) <> "\n")
    Process.sleep(20)
    assert Process.alive?(worker)
    refute Snodo.Cancellation.cancelled?(cancellation)

    TestInput.push(input, JSON.encode!(valid_cancel) <> "\n")
    TestInput.push(input, JSON.encode!(reused_id) <> "\n")
    TestInput.push(input, JSON.encode!(fast) <> "\n")
    TestInput.eof(input)

    assert :ok = Task.await(server, 1_000)
    assert Snodo.Cancellation.cancelled?(cancellation)

    {_remaining_input, raw_output} = StringIO.contents(output)

    responses =
      raw_output
      |> String.split("\n", trim: true)
      |> Enum.map(&JSON.decode!/1)

    assert Enum.sort(Enum.map(responses, & &1["id"])) == ["cancel-me", "survives"]

    assert %{"result" => reused_result} = Enum.find(responses, &(&1["id"] == "cancel-me"))
    assert reused_result["content"] == [%{"type" => "text", "text" => "id reused"}]

    assert %{"result" => surviving_result} = Enum.find(responses, &(&1["id"] == "survives"))

    assert surviving_result["content"] == [
             %{"type" => "text", "text" => "still alive"}
           ]
  end

  @tag mcp_contract: ["subscriptions-stdio", "subscriptions-cancellation"]
  test "stdio multiplexes bounded subscription delivery and cancellation without a final reply" do
    {:ok, hub} = start_supervised({TestSubscriptionHub, owner: self()})

    runtime =
      TestFixtures.runtime(
        capabilities: %{"tools" => %{"listChanged" => true}},
        subscription_source: {TestSubscriptionSource, hub}
      )

    {:ok, input} = TestInput.start_link()
    {:ok, output} = StringIO.open("")
    server = Task.async(fn -> Stdio.serve(runtime, input: input, output: output) end)

    listen =
      TestFixtures.request("stdio-sub", "subscriptions/listen", %{
        "notifications" => %{"toolsListChanged" => true}
      })

    TestInput.push(input, JSON.encode!(listen) <> "\n")

    assert_receive {:subscription_opened, "stdio-sub", %{"toolsListChanged" => true}}, 1_000
    assert_receive {:subscription_next, "stdio-sub"}, 1_000
    refute_receive {:subscription_next, "stdio-sub"}, 30

    assert [%{"method" => "notifications/subscriptions/acknowledged"}] =
             await_output_messages(output, 1)

    assert :ok = TestSubscriptionHub.emit(hub, "stdio-sub", Event.tools_list_changed())
    assert_receive {:subscription_next, "stdio-sub"}, 1_000

    [acknowledgement, notification] = await_output_messages(output, 2)
    subscription_key = "io.modelcontextprotocol/subscriptionId"
    assert get_in(acknowledgement, ["params", "_meta", subscription_key]) == "stdio-sub"
    assert notification["method"] == "notifications/tools/list_changed"
    assert get_in(notification, ["params", "_meta", subscription_key]) == "stdio-sub"

    cancellation = %{
      "jsonrpc" => "2.0",
      "method" => "notifications/cancelled",
      "params" => %{"requestId" => "stdio-sub", "reason" => "client done"}
    }

    TestInput.push(input, JSON.encode!(cancellation) <> "\n")
    assert_receive {:subscription_closed, "stdio-sub", {:cancelled, "client done"}}, 1_000

    reused = TestFixtures.request("stdio-sub", "tools/list")
    TestInput.push(input, JSON.encode!(reused) <> "\n")
    TestInput.eof(input)

    assert :ok = Task.await(server, 1_000)
    messages = await_output_messages(output, 3)

    assert Enum.count(messages, &(&1["id"] == "stdio-sub")) == 1
    assert Enum.at(messages, 2)["result"]["tools"]
  end

  defp serve(runtime, input, opts \\ []) do
    {:ok, io} = StringIO.open(input)
    assert :ok = Stdio.serve(runtime, Keyword.merge(opts, input: io, output: io))
    {_remaining_input, output} = StringIO.contents(io)

    output
    |> String.split("\n", trim: true)
    |> Enum.map(&JSON.decode!/1)
  end

  defp await_output_messages(output, count, attempts \\ 100)

  defp await_output_messages(output, count, attempts) when attempts > 0 do
    {_remaining_input, raw_output} = StringIO.contents(output)

    messages =
      raw_output
      |> String.split("\n", trim: true)
      |> Enum.map(&JSON.decode!/1)

    if length(messages) >= count do
      messages
    else
      Process.sleep(10)
      await_output_messages(output, count, attempts - 1)
    end
  end

  defp await_output_messages(_output, count, 0) do
    flunk("timed out waiting for #{count} stdio messages")
  end

  defp await_global_name(name, attempts \\ 100)

  defp await_global_name(name, attempts) when attempts > 0 do
    case :global.whereis_name(name) do
      pid when is_pid(pid) ->
        pid

      :undefined ->
        Process.sleep(5)
        await_global_name(name, attempts - 1)
    end
  end

  defp await_global_name(name, 0) do
    flunk("stdio coordinator #{inspect(name)} was not registered")
  end

  test "a response object does not occupy an in-flight request id" do
    {:ok, input} = TestInput.start_link()
    {:ok, output} = StringIO.open("")

    server =
      Task.async(fn ->
        Stdio.serve(TestFixtures.runtime(tools: [Echo]), input: input, output: output)
      end)

    call =
      TestFixtures.request("shared", "tools/call", %{
        "name" => "echo",
        "arguments" => %{"text" => "done", "delayMs" => 100}
      })

    TestInput.push(input, JSON.encode!(call) <> "\n")

    TestInput.push(
      input,
      JSON.encode!(%{"jsonrpc" => "2.0", "id" => "shared", "result" => %{}}) <> "\n"
    )

    TestInput.eof(input)
    assert :ok = Task.await(server, 5_000)

    {_input, raw_output} = StringIO.contents(output)
    assert [line] = String.split(raw_output, "\n", trim: true)

    assert %{"id" => "shared", "result" => %{"content" => [%{"text" => "done"}]}} =
             JSON.decode!(line)
  end
end
