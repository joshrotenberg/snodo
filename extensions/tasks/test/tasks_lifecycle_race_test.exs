defmodule MCP.TasksLifecycleRaceTest do
  use ExUnit.Case, async: false

  @moduletag mcp_contract: ["tasks-extension-races"]
  @moduletag :tasks_package

  alias MCP.Extensions.Tasks.Runner
  alias MCP.Extensions.Tasks.Store.Memory
  alias MCPEx.TasksTestSupport, as: TasksSupport

  setup do
    store = start_supervised!(Memory)
    runner = start_supervised!({Runner, store: {Memory, store}})

    %{runtime: TasksSupport.runtime(store, runner, self())}
  end

  test "cancellation racing completion makes exactly one immutable terminal transition", %{
    runtime: runtime
  } do
    for iteration <- 1..12 do
      label = "race-#{iteration}"

      assert {:ok, %{"result" => created}} =
               TasksSupport.call(
                 runtime,
                 "race-create-#{iteration}",
                 "slow_compute",
                 %{"block" => true, "label" => label}
               )

      assert_receive {:tasks_barrier_entered, ^label, worker}, 1_000
      task_id = created["taskId"]

      release = Task.async(fn -> send(worker, {:tasks_release, label}) end)

      cancellation =
        Task.async(fn ->
          TasksSupport.cancel(runtime, "race-cancel-#{iteration}", task_id)
        end)

      _released = Task.await(release, 1_000)

      assert {:ok, %{"result" => %{"resultType" => "complete"}}} =
               Task.await(cancellation, 1_000)

      assert {:ok, %{"result" => terminal}} =
               TasksSupport.eventually_get(
                 runtime,
                 task_id,
                 &(&1["status"] in ["completed", "cancelled"])
               )

      assert terminal["status"] in ["completed", "cancelled"]

      case terminal["status"] do
        "completed" ->
          assert terminal["result"]["structuredContent"]["label"] == label
          refute Map.has_key?(terminal, "error")

        "cancelled" ->
          refute Map.has_key?(terminal, "result")
          refute Map.has_key?(terminal, "error")
      end

      assert {:ok, %{"result" => %{"resultType" => "complete"}}} =
               TasksSupport.cancel(runtime, "race-cancel-again-#{iteration}", task_id)

      assert {:ok, %{"result" => after_cancel}} =
               TasksSupport.get(runtime, "race-after-#{iteration}", task_id)

      assert after_cancel == terminal
    end
  end

  test "terminal cancellation is idempotent for both completed and cancelled tasks", %{
    runtime: runtime
  } do
    assert {:ok, %{"result" => completed_created}} =
             TasksSupport.call(
               runtime,
               "completed-create",
               "slow_compute",
               %{"block" => true, "label" => "complete-first"}
             )

    assert_receive {:tasks_barrier_entered, "complete-first", completed_worker}, 1_000
    send(completed_worker, {:tasks_release, "complete-first"})

    assert {:ok, %{"result" => completed}} =
             TasksSupport.eventually_get(
               runtime,
               completed_created["taskId"],
               &(&1["status"] == "completed")
             )

    for id <- ["completed-cancel-one", "completed-cancel-two"] do
      assert {:ok, %{"result" => %{"resultType" => "complete"}}} =
               TasksSupport.cancel(runtime, id, completed_created["taskId"])
    end

    assert {:ok, %{"result" => completed_after}} =
             TasksSupport.get(runtime, "completed-after", completed_created["taskId"])

    assert completed_after == completed

    assert {:ok, %{"result" => cancelled_created}} =
             TasksSupport.call(
               runtime,
               "cancelled-create",
               "slow_compute",
               %{"block" => true, "label" => "cancel-first"}
             )

    assert_receive {:tasks_barrier_entered, "cancel-first", _cancelled_worker}, 1_000

    assert {:ok, %{"result" => %{"resultType" => "complete"}}} =
             TasksSupport.cancel(runtime, "cancelled-cancel-one", cancelled_created["taskId"])

    assert {:ok, %{"result" => cancelled}} =
             TasksSupport.get(runtime, "cancelled-terminal", cancelled_created["taskId"])

    assert cancelled["status"] == "cancelled"

    assert {:ok, %{"result" => %{"resultType" => "complete"}}} =
             TasksSupport.cancel(runtime, "cancelled-cancel-two", cancelled_created["taskId"])

    assert {:ok, %{"result" => cancelled_after}} =
             TasksSupport.get(runtime, "cancelled-after", cancelled_created["taskId"])

    assert cancelled_after == cancelled
  end
end
