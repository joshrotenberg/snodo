defmodule Snodo.Transport.StdioWriteTimeoutTest do
  use ExUnit.Case, async: true

  alias Snodo.Cancellation
  alias Snodo.Server.Executor
  alias Snodo.Transport.Stdio
  alias SnodoTest.TestFixtures
  alias SnodoTest.TestInput
  alias SnodoTest.TestSubscriptionHub
  alias SnodoTest.TestSubscriptionSource
  alias SnodoTest.TestTools.Trapping

  @moduletag capture_log: true
  @moduletag mcp_contract: ["stdio-write-deadline"]

  defmodule Output do
    @moduledoc false
    use GenServer

    def start_link(owner), do: GenServer.start_link(__MODULE__, owner)

    @impl true
    def init(owner), do: {:ok, owner}

    @impl true
    def handle_info({:io_request, writer, tag, {:put_chars, _encoding, data}}, owner) do
      send(owner, {:write, writer, tag, IO.iodata_to_binary(data)})
      {:noreply, owner}
    end
  end

  defmodule ProgressTool do
    @moduledoc false
    use Snodo.Tool, name: "write_progress"

    @impl true
    def call(_arguments, context) do
      :ok = Snodo.Progress.report(context, 0)
      :ok = Snodo.Progress.report(context, 1)
      {:ok, Snodo.Result.text("complete")}
    end
  end

  setup do
    input = start_supervised!(%{id: TestInput, start: {TestInput, :start_link, []}})
    output = start_supervised!({Output, self()})
    %{input: input, output: output}
  end

  test "a blocked write is terminal, leaves the device alive, and never retries queued output",
       ctx do
    {transport, monitor} = start_transport(ctx, write_timeout: 30)
    TestInput.push(ctx.input, "{invalid}\n{also-invalid}\n")
    TestInput.eof(ctx.input)
    assert_receive {:write, writer, tag, first}, 1_000
    writer_monitor = Process.monitor(writer)
    assert JSON.decode!(first)["error"]["code"] == -32_700
    assert_receive {:DOWN, ^monitor, :process, ^transport, {:output_failed, :timeout}}, 1_000
    assert_receive {:DOWN, ^writer_monitor, :process, ^writer, _}, 1_000
    assert Process.alive?(ctx.output)
    send(writer, {:io_reply, tag, :ok})
    refute_receive {:write, _, _, _}, 40
  end

  test "an error returned by the public I/O protocol terminates with no surviving helper", ctx do
    {transport, monitor} = start_transport(ctx, write_timeout: 1_000)
    TestInput.push(ctx.input, "{invalid}\n")
    assert_receive {:write, writer, tag, _data}, 1_000
    writer_monitor = Process.monitor(writer)
    send(writer, {:io_reply, tag, {:error, :enospc}})
    assert_receive {:DOWN, ^monitor, :process, ^transport, {:output_failed, :enospc}}, 1_000
    assert_receive {:DOWN, ^writer_monitor, :process, ^writer, _}, 1_000
    assert Process.alive?(ctx.output)
  end

  test "abrupt coordinator death also terminates its blocked write helper", ctx do
    {transport, monitor} = start_transport(ctx, write_timeout: 5_000)
    TestInput.push(ctx.input, "{invalid}\n")
    assert_receive {:write, writer, _tag, _data}, 1_000
    writer_monitor = Process.monitor(writer)
    Process.exit(transport, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^transport, :killed}, 1_000
    assert_receive {:DOWN, ^writer_monitor, :process, ^writer, :killed}, 1_000
    assert Process.alive?(ctx.output)
  end

  test "an unexpectedly terminated helper fails the transport without killing the device", ctx do
    {transport, monitor} = start_transport(ctx, write_timeout: 5_000)
    TestInput.push(ctx.input, "{invalid}\n")
    assert_receive {:write, writer, _tag, _data}, 1_000
    Process.exit(writer, :kill)

    assert_receive {:DOWN, ^monitor, :process, ^transport,
                    {:output_failed, {:writer_down, :killed}}},
                   1_000

    assert Process.alive?(ctx.output)
  end

  test "write timeout cancels running and queued transport work without stopping an external executor",
       ctx do
    executor =
      start_supervised!({Executor, max_concurrency: 1, max_queue: 1, default_timeout: :infinity})

    token = Integer.to_string(System.unique_integer([:positive]))
    :yes = :global.register_name({Trapping, token}, self())
    on_exit(fn -> :global.unregister_name({Trapping, token}) end)
    runtime = TestFixtures.runtime(tools: [Trapping])
    options = [runtime: runtime, executor: executor, write_timeout: 40]
    {transport, monitor} = start_transport(ctx, options)

    request =
      TestFixtures.request("running", "tools/call", %{
        "name" => "trapping",
        "arguments" => %{"token" => token}
      })

    push(ctx.input, request)
    assert_receive {:trapping_entered, worker, cancellation}, 1_000
    worker_monitor = Process.monitor(worker)
    push(ctx.input, TestFixtures.request("queued", "tools/list"))
    TestInput.push(ctx.input, "{invalid}\n")
    assert_receive {:write, writer, _tag, _data}, 1_000
    writer_monitor = Process.monitor(writer)
    assert %{running: 1, queued: 1} = Executor.stats(executor)
    assert_receive {:DOWN, ^monitor, :process, ^transport, {:output_failed, :timeout}}, 1_000
    assert_receive {:DOWN, ^worker_monitor, :process, ^worker, _}, 1_000
    assert_receive {:DOWN, ^writer_monitor, :process, ^writer, _}, 1_000
    assert Cancellation.cancelled?(cancellation)
    assert %{running: 0, queued: 0} = Executor.stats(executor)
    assert Process.alive?(executor)
    assert Process.alive?(ctx.output)
  end

  test "a failed first subscription acknowledgement closes its already-open source", ctx do
    hub = start_supervised!({TestSubscriptionHub, owner: self()})
    runtime = subscription_runtime(hub)
    {transport, monitor} = start_transport(ctx, runtime: runtime, write_timeout: 30)
    push(ctx.input, subscription_request())
    assert_receive {:subscription_opened, "listen", _filter}, 1_000
    assert_receive {:write, writer, _tag, data}, 1_000
    assert JSON.decode!(data)["method"] == "notifications/subscriptions/acknowledged"
    assert_receive {:subscription_closed, "listen", {:error, {:output_failed, :timeout}}}, 1_000
    assert_receive {:DOWN, ^monitor, :process, ^transport, {:output_failed, :timeout}}, 1_000
    refute Process.alive?(writer)
    assert {:error, :not_found} = TestSubscriptionHub.complete(hub, "listen")
  end

  test "a later output failure closes active subscriptions and their pending source worker",
       ctx do
    hub = start_supervised!({TestSubscriptionHub, owner: self()})
    runtime = subscription_runtime(hub)
    {transport, monitor} = start_transport(ctx, runtime: runtime, write_timeout: 30)
    push(ctx.input, subscription_request())
    assert_receive {:write, writer, tag, _data}, 1_000
    send(writer, {:io_reply, tag, :ok})
    assert_receive {:subscription_next, "listen"}, 1_000
    TestInput.push(ctx.input, "{invalid}\n")
    assert_receive {:write, _writer, _tag, _data}, 1_000
    assert_receive {:subscription_closed, "listen", :disconnected}, 1_000
    assert_receive {:DOWN, ^monitor, :process, ^transport, {:output_failed, :timeout}}, 1_000
    assert {:error, :not_found} = TestSubscriptionHub.complete(hub, "listen")
  end

  test "successful writes acknowledge one frame at a time and preserve progress then final ordering",
       ctx do
    runtime = TestFixtures.runtime(tools: [ProgressTool])
    {transport, monitor} = start_transport(ctx, runtime: runtime, write_timeout: 1_000)

    request =
      TestFixtures.request("ordered", "tools/call", %{"name" => "write_progress"})
      |> put_in(["params", "_meta", "progressToken"], "token")

    push(ctx.input, request)
    TestInput.eof(ctx.input)

    for value <- [0, 1] do
      assert_receive {:write, writer, tag, data}, 1_000
      writer_monitor = Process.monitor(writer)

      assert %{"method" => "notifications/progress", "params" => %{"progress" => ^value}} =
               JSON.decode!(data)

      refute_receive {:write, _, _, _}, 20
      send(writer, {:io_reply, tag, :ok})
      assert_receive {:DOWN, ^writer_monitor, :process, ^writer, _}, 1_000
    end

    assert_receive {:write, writer, tag, data}, 1_000
    assert %{"id" => "ordered", "result" => _} = JSON.decode!(data)
    send(writer, {:io_reply, tag, :ok})
    assert_receive {:DOWN, ^monitor, :process, ^transport, :normal}, 1_000
    refute Process.alive?(writer)
    assert Process.alive?(ctx.output)
  end

  test "serve returns a terminal output error rather than hanging at EOF", ctx do
    task =
      Task.async(fn ->
        Stdio.serve(TestFixtures.runtime(),
          input: ctx.input,
          output: ctx.output,
          write_timeout: 30
        )
      end)

    TestInput.push(ctx.input, "{invalid}\n")
    TestInput.eof(ctx.input)
    assert_receive {:write, writer, _tag, _data}, 1_000
    assert Task.await(task) == {:error, {:output_failed, :timeout}}
    refute Process.alive?(writer)
  end

  defp start_transport(ctx, options) do
    options =
      [runtime: TestFixtures.runtime(), input: ctx.input, output: ctx.output]
      |> Keyword.merge(options)

    {:ok, transport} = Stdio.start_link(options)
    Process.unlink(transport)
    monitor = Process.monitor(transport)

    on_exit(fn ->
      if Process.alive?(transport), do: GenServer.stop(transport)
    end)

    {transport, monitor}
  end

  defp push(input, request), do: TestInput.push(input, JSON.encode!(request) <> "\n")

  defp subscription_runtime(hub) do
    TestFixtures.runtime(
      subscription_source: {TestSubscriptionSource, hub},
      capabilities: %{"tools" => %{"listChanged" => true}}
    )
  end

  defp subscription_request do
    TestFixtures.request("listen", "subscriptions/listen", %{
      "notifications" => %{"toolsListChanged" => true}
    })
  end
end
