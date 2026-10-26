defmodule Snodo.Transport.StdioNotifyTest do
  use ExUnit.Case, async: true

  alias Snodo.Error
  alias Snodo.Transport.Stdio
  alias SnodoTest.TestFixtures
  alias SnodoTest.TestInput

  @moduletag capture_log: true
  @method "notifications/claude/channel"

  setup do
    input = start_supervised!(%{id: TestInput, start: {TestInput, :start_link, []}})
    {:ok, output} = StringIO.open("")
    %{input: input, output: output}
  end

  defp start_transport(ctx, options \\ []) do
    options =
      Keyword.merge(
        [
          runtime: TestFixtures.runtime(),
          input: ctx.input,
          output: ctx.output,
          notification_methods: [@method]
        ],
        options
      )

    # Supervised last, so it stops before the input and output it reads and writes.
    start_supervised!(%{
      id: make_ref(),
      start: {Stdio, :start_link, [options]},
      restart: :temporary
    })
  end

  defp frames(ctx) do
    {_input, output} = StringIO.contents(ctx.output)
    output |> String.split("\n", trim: true) |> Enum.map(&JSON.decode!/1)
  end

  test "an idle connection emits a notification frame with no id", ctx do
    transport = start_transport(ctx)
    assert :ok = Stdio.notify(transport, @method, %{"content" => "new mail", "n" => 1})

    assert [frame] = frames(ctx)

    assert frame == %{
             "jsonrpc" => "2.0",
             "method" => @method,
             "params" => %{"content" => "new mail", "n" => 1}
           }
  end

  test "concurrent notifications and responses stay whole frames", ctx do
    transport = start_transport(ctx)
    ref = Process.monitor(transport)

    TestInput.push(
      ctx.input,
      JSON.encode!(TestFixtures.request("list", "tools/list")) <> "\n"
    )

    1..40
    |> Task.async_stream(fn n -> Stdio.notify(transport, @method, %{"n" => n}) end,
      max_concurrency: 20
    )
    |> Enum.each(fn {:ok, result} -> assert result == :ok end)

    # EOF stops the transport once the admitted request has been answered.
    TestInput.eof(ctx.input)
    assert_receive {:DOWN, ^ref, :process, ^transport, :normal}, 5_000

    all = frames(ctx)
    notifications = Enum.filter(all, &(&1["method"] == @method))
    assert Enum.sort(Enum.map(notifications, & &1["params"]["n"])) == Enum.to_list(1..40)
    assert Enum.any?(all, &(&1["id"] == "list" and Map.has_key?(&1, "result")))
    assert Enum.all?(notifications, &(not Map.has_key?(&1, "id")))
  end

  test "disallowed or invalid input errors and writes nothing", ctx do
    transport = start_transport(ctx)

    assert {:error, %Error{}} = Stdio.notify(transport, "notifications/other", %{})
    assert {:error, %Error{}} = Stdio.notify(transport, "notifications/progress", %{})
    assert {:error, %Error{}} = Stdio.notify(transport, 5, %{})
    assert {:error, %Error{}} = Stdio.notify(transport, @method, "text")
    assert {:error, %Error{}} = Stdio.notify(transport, @method, %{"pid" => self()})
    assert frames(ctx) == []
    assert :ok = Stdio.notify(transport, @method)
  end

  test "nothing is sendable unless methods are enabled", ctx do
    transport = start_transport(ctx, notification_methods: [])
    assert {:error, %Error{}} = Stdio.notify(transport, @method, %{})
  end

  test "reserved or malformed method lists are refused at startup", ctx do
    Process.flag(:trap_exit, true)

    reserved = [
      "notifications/progress",
      "notifications/tools/list_changed",
      "notifications/prompts/list_changed",
      "notifications/resources/list_changed",
      "notifications/resources/updated",
      "notifications/roots/list_changed",
      "notifications/elicitation/complete",
      "notifications/tasks/status"
    ]

    for methods <- Enum.map(reserved, &[&1]) ++ [["tools/call"], "x"] do
      assert {:error, _} =
               Stdio.start_link(
                 runtime: TestFixtures.runtime(),
                 input: ctx.input,
                 output: ctx.output,
                 notification_methods: methods
               )
    end
  end

  test "a caller timeout returns :timeout and the queued frame is still written", ctx do
    transport = start_transport(ctx)
    :ok = :sys.suspend(transport)
    assert {:error, :timeout} = Stdio.notify(transport, @method, %{"n" => 1}, 20)
    :ok = :sys.resume(transport)
    # A synchronous call is handled after the queued notification.
    assert :ok = Stdio.notify(transport, @method, %{"n" => 2})
    assert [%{"params" => %{"n" => 1}}, %{"params" => %{"n" => 2}}] = frames(ctx)
  end

  test "an abnormal transport stop is not reported as a closed connection", ctx do
    transport = start_transport(ctx)
    :ok = :sys.suspend(transport)
    task = Task.async(fn -> Stdio.notify(transport, @method, %{}) end)
    ref = Process.monitor(transport)
    await_queued_call(transport)
    Process.exit(transport, :kill)
    assert_receive {:DOWN, ^ref, :process, ^transport, :killed}, 1_000
    assert {:error, {:transport_down, :killed}} = Task.await(task)
  end

  # The suspended transport holds the caller's request unread in its mailbox.
  defp await_queued_call(transport) do
    case Process.info(transport, :message_queue_len) do
      {:message_queue_len, n} when n > 0 ->
        :ok

      _empty ->
        receive do
        after
          1 -> await_queued_call(transport)
        end
    end
  end

  test "a closed connection returns :closed", ctx do
    transport = start_transport(ctx)
    ref = Process.monitor(transport)
    GenServer.stop(transport)
    assert_receive {:DOWN, ^ref, :process, ^transport, _}, 1_000
    assert {:error, :closed} = Stdio.notify(transport, @method, %{})
  end

  test "a failed write is terminal and reported to the caller", ctx do
    {:ok, output} = StringIO.open("")
    transport = start_transport(ctx, output: output)
    ref = Process.monitor(transport)
    GenServer.stop(output)

    assert {:error, {:output_failed, _reason}} = Stdio.notify(transport, @method, %{})
    assert_receive {:DOWN, ^ref, :process, ^transport, {:output_failed, _}}, 1_000
  end
end
