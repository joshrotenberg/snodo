defmodule Snodo.TasksOrdinaryMRTRBoundaryTest do
  use ExUnit.Case, async: false

  alias Snodo.Extensions.Tasks.Runner
  alias Snodo.Extensions.Tasks.Store.Memory
  alias Snodo.Protocol.V2026_07_28
  alias Snodo.Router
  alias SnodoTest.TasksTestSupport, as: TasksSupport

  @moduletag mcp_contract: ["tasks-extension-lifecycle"]
  @moduletag :tasks_package

  defmodule BoundaryTool do
    @moduledoc false
    use Snodo.Tool, name: "mrtr_boundary"

    alias Snodo.Elicitation
    alias Snodo.Result

    @impl true
    def call(%{"kind" => kind}, _context) do
      {:ok, result(kind)}
    end

    defp result("ordinary") do
      Result.input_required(input_requests: %{"approval" => request()})
    end

    defp result("wire") do
      Result.wire(%{
        "resultType" => "input_required",
        "inputRequests" => %{"approval" => request()}
      })
    end

    defp result("state_only"), do: Result.input_required(request_state: "private-continuation")

    defp result("nested_task") do
      Result.wire(%{"resultType" => "task", "taskId" => "private-child-task"})
    end

    defp result("custom_complete") do
      Result.wire(%{"resultType" => "example/custom-complete", "value" => "final"})
    end

    defp request do
      Elicitation.form("Confirm the preview", %{
        "type" => "object",
        "properties" => %{"confirm" => %{"type" => "boolean"}},
        "required" => ["confirm"]
      })
    end
  end

  setup do
    store = start_supervised!(Memory)
    runner = start_supervised!({Runner, store: {Memory, store}})

    runtime =
      TasksSupport.runtime(store, runner, self(), task_support: %{"mrtr_boundary" => :optional})

    router = Router.register_tool(runtime.router, BoundaryTool)
    %{runtime: %{runtime | router: router}}
  end

  test "ordinary and wire MRTR results cannot be stored as completed tasks", %{runtime: runtime} do
    for kind <- ["ordinary", "wire", "state_only"] do
      task = run_task(runtime, kind, true)

      assert task["status"] == "failed"
      assert task["error"]["code"] == -32_603
      assert task["error"]["message"] =~ "Tasks.await_input/3"
      assert task["error"]["message"] =~ "finish MRTR"
      refute Map.has_key?(task, "result")
      refute Map.has_key?(task, "inputRequests")
      refute Map.has_key?(task, "requestState")
      refute JSON.encode!(task) =~ "private-continuation"
    end
  end

  test "async workers still enforce the dialect's per-request elicitation capability", %{
    runtime: runtime
  } do
    for kind <- ["ordinary", "wire"] do
      task = run_task(runtime, kind, false)

      assert task["status"] == "failed"

      assert task["error"] == %{
               "code" => -32_021,
               "message" => "Missing required client capability",
               "data" => %{"requiredCapabilities" => %{"elicitation" => %{"form" => %{}}}}
             }

      refute Map.has_key?(task, "result")
    end
  end

  test "nested task handles are rejected rather than becoming terminal task output", %{
    runtime: runtime
  } do
    task = run_task(runtime, "nested_task", false)

    assert task["status"] == "failed"
    assert task["error"]["code"] == -32_603
    refute Map.has_key?(task, "result")
    refute JSON.encode!(task) =~ "private-child-task"
  end

  test "the guard does not reject unrelated extension-defined result types", %{runtime: runtime} do
    task = run_task(runtime, "custom_complete", false)

    assert task["status"] == "completed"
    assert task["result"]["resultType"] == "example/custom-complete"
    assert task["result"]["value"] == "final"
    refute Map.has_key?(task, "error")
  end

  test "optional Tasks policy preserves ordinary synchronous MRTR without task negotiation", %{
    runtime: runtime
  } do
    request =
      TasksSupport.request(
        "synchronous-mrtr",
        "tools/call",
        %{"name" => "mrtr_boundary", "arguments" => %{"kind" => "ordinary"}},
        tasks: false
      )
      |> add_elicitation_capability()

    assert {:ok, %{"result" => result}} = TasksSupport.dispatch(runtime, request)
    assert result["resultType"] == "input_required"
    assert result["inputRequests"]["approval"]["method"] == "elicitation/create"
    refute Map.has_key?(result, "taskId")
  end

  defp run_task(runtime, kind, elicitation?) do
    request =
      TasksSupport.request("create-#{kind}", "tools/call", %{
        "name" => "mrtr_boundary",
        "arguments" => %{"kind" => kind}
      })

    request =
      if elicitation? do
        add_elicitation_capability(request)
      else
        request
      end

    assert {:ok, %{"result" => %{"resultType" => "task", "taskId" => task_id}}} =
             TasksSupport.dispatch(runtime, request)

    assert {:ok, %{"result" => task}} =
             TasksSupport.eventually_get(
               runtime,
               task_id,
               &(&1["status"] in ["failed", "completed"])
             )

    task
  end

  defp add_elicitation_capability(request) do
    put_in(
      request,
      ["params", "_meta", V2026_07_28.client_capabilities_key(), "elicitation"],
      %{"form" => %{}}
    )
  end
end
