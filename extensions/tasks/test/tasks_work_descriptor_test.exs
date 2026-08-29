defmodule MCPEx.TasksWorkDescriptorTest.Executor do
  @behaviour MCP.Extensions.Tasks.WorkExecutor

  @impl true
  def execute(work, cancellation, owner) do
    send(owner, {:executed_work, work, cancellation})
    {:completed, %{"ok" => true}}
  end
end

defmodule MCPEx.TasksWorkDescriptorTest.RaisingExecutor do
  @behaviour MCP.Extensions.Tasks.WorkExecutor

  @impl true
  def execute(_work, _cancellation, _state), do: raise("executor failed")
end

defmodule MCPEx.TasksWorkDescriptorTest.InvalidExecutor do
  @behaviour MCP.Extensions.Tasks.WorkExecutor

  @impl true
  def execute(_work, _cancellation, _state), do: :invalid
end

defmodule MCP.TasksWorkDescriptorTest do
  use ExUnit.Case, async: true

  @moduletag mcp_contract: ["tasks-work-descriptor"]
  @moduletag :tasks_package

  alias MCP.Cancellation
  alias MCP.Extensions.Tasks.Event
  alias MCP.Extensions.Tasks.RetryPolicy
  alias MCP.Extensions.Tasks.Snapshot
  alias MCP.Extensions.Tasks.Task, as: ProtocolTask
  alias MCP.Extensions.Tasks.Transition
  alias MCP.Extensions.Tasks.Work
  alias MCP.Extensions.Tasks.WorkExecutor
  alias MCPEx.TasksWorkDescriptorTest.Executor
  alias MCPEx.TasksWorkDescriptorTest.InvalidExecutor
  alias MCPEx.TasksWorkDescriptorTest.RaisingExecutor

  @created_at "2026-08-24T10:00:00.000Z"
  @requested_at "2026-08-24T10:00:01.000Z"
  @accepted_at "2026-08-24T10:00:02.000Z"

  test "work descriptors are versioned JSON data with a stable idempotency key" do
    assert {:ok, work} =
             Work.tool_call(
               "task-123",
               "durable_export",
               %{"format" => "csv", "filters" => [%{"active" => true}]}
             )

    assert work == %Work{
             idempotency_key: "task-123",
             type: "tools/call",
             input: %{
               "name" => "durable_export",
               "arguments" => %{
                 "format" => "csv",
                 "filters" => [%{"active" => true}]
               }
             }
           }

    encoded = Work.to_map(work)
    assert encoded["version"] == 2
    assert encoded["idempotencyKey"] == "task-123"
    assert encoded["retryPolicy"] == %{"version" => 1, "delaysMs" => []}

    json_round_trip = encoded |> JSON.encode!() |> JSON.decode!()
    assert {:ok, ^work} = Work.from_map(json_round_trip)
  end

  test "work descriptors reject empty identity and non-JSON process state" do
    assert {:error, :invalid_work_idempotency_key} = Work.new("", "custom", %{})
    assert {:error, :invalid_work_type} = Work.new("task", "", %{})
    assert {:error, :invalid_work_input} = Work.new("task", "custom", %{"pid" => self()})
    assert {:error, :invalid_work_input} = Work.new("task", "custom", :not_a_map)
    assert {:error, :invalid_tool_name} = Work.tool_call("task", "", %{})
    assert {:error, :invalid_tool_arguments} = Work.tool_call("task", "tool", [])

    assert_raise ArgumentError, fn ->
      Work.new!("task", "custom", %{"function" => fn -> :not_serializable end})
    end

    assert {:error, {:unsupported_work_version, 3}} =
             Work.from_map(%{
               "version" => 3,
               "idempotencyKey" => "task",
               "type" => "custom",
               "input" => %{}
             })

    assert {:error, :invalid_work_encoding} =
             Work.from_map(%{
               "version" => 2,
               "idempotencyKey" => "task",
               "type" => "custom",
               "input" => %{},
               "retryPolicy" => %{"version" => 1, "delaysMs" => []},
               "unexpected" => true
             })
  end

  test "the executor boundary validates configuration, failures, and outcomes" do
    work = Work.new!("task-executor", "custom", %{"value" => 1})
    cancellation = Cancellation.new()
    executor = {Executor, self()}

    assert WorkExecutor.validate_ref!(executor) == executor

    assert {:ok, {:completed, %{"ok" => true}}} =
             WorkExecutor.invoke(executor, work, cancellation)

    assert_receive {:executed_work, ^work, ^cancellation}

    assert {:error, {:invalid_executor_return, :invalid}} =
             WorkExecutor.invoke({InvalidExecutor, nil}, work, cancellation)

    assert {:error, {:executor_exception, %RuntimeError{}, stacktrace}} =
             WorkExecutor.invoke({RaisingExecutor, nil}, work, cancellation)

    assert is_list(stacktrace)
    assert_raise ArgumentError, fn -> WorkExecutor.validate_ref!({__MODULE__, nil}) end
    assert_raise ArgumentError, fn -> WorkExecutor.validate_ref!(:not_a_ref) end
  end

  test "snapshot v3 persists work, retry state, and original request identity" do
    work = Work.new!("recovery-task", "custom", %{"job" => "export"})
    initial = Snapshot.new(task("recovery-task"), work)

    assert initial.work == work
    assert initial.input_history == %{}
    assert :ok = Snapshot.validate(initial)

    requested =
      transition!(
        initial,
        event!(Event.input_requested("approval", input_request(), id: "input-requested")),
        @requested_at
      ).snapshot

    assert requested.task.status == :input_required
    assert requested.input_history == %{"approval" => input_request()}
    assert requested.task.input_requests == requested.input_history

    encoded = Snapshot.to_map(requested)
    assert encoded["version"] == 3
    assert encoded["work"] == Work.to_map(work)
    assert encoded["retryCount"] == 0
    assert encoded["retryAt"] == nil
    assert encoded["lastFailure"] == nil
    assert encoded["inputHistory"] == %{"approval" => input_request()}

    json_round_trip = encoded |> JSON.encode!() |> JSON.decode!()
    assert {:ok, recovered} = Snapshot.from_map(json_round_trip)
    assert recovered == requested
    assert recovered.work.idempotency_key == recovered.task.id

    accepted =
      transition!(
        recovered,
        event!(
          Event.input_responses_accepted(
            %{"approval" => input_response()},
            id: "input-accepted"
          )
        ),
        @accepted_at
      ).snapshot

    assert accepted.task.status == :working
    assert accepted.task.input_requests == %{}
    assert accepted.input_history == %{"approval" => input_request()}
    assert accepted.accepted_input_responses == %{"approval" => input_response()}
    assert :ok = Snapshot.validate(accepted)

    accepted_round_trip =
      accepted
      |> Snapshot.to_map()
      |> JSON.encode!()
      |> JSON.decode!()

    assert {:ok, ^accepted} = Snapshot.from_map(accepted_round_trip)
  end

  test "snapshot validation fails closed when replay identity becomes ambiguous" do
    initial = Snapshot.new(task("identity-task"))

    requested =
      transition!(
        initial,
        event!(Event.input_requested("approval", input_request(), id: "record-history")),
        @requested_at
      ).snapshot

    assert {:error, :input_history_does_not_cover_used_keys} =
             Snapshot.validate(%{requested | input_history: %{}})

    different_request = put_in(input_request(), ["params", "message"], "A different request")

    assert {:error, :outstanding_input_request_does_not_match_history} =
             Snapshot.validate(%{
               requested
               | input_history: %{"approval" => different_request}
             })

    assert {:error, :input_history_does_not_cover_used_keys} =
             Snapshot.validate(%{
               requested
               | input_history: Map.put(requested.input_history, "never-issued", input_request())
             })

    assert {:error, :accepted_response_still_outstanding} =
             Snapshot.validate(%{
               requested
               | accepted_input_responses: %{"approval" => input_response()}
             })

    assert {:error, {:unsupported_snapshot_version, 1}} =
             requested
             |> Snapshot.to_map()
             |> Map.put("version", 1)
             |> Snapshot.from_map()
  end

  test "persisted retry bookkeeping rejects impossible cross-field states" do
    work =
      Work.new!("retry-invariants", "custom", %{}, retry_policy: RetryPolicy.new!([250]))

    initial = Snapshot.new(task("retry-invariants"), work)

    retry_event =
      event!(
        Event.retry_requested(
          %{"code" => -32_603, "message" => "temporary"},
          "Retrying",
          id: "retry-invariants-scheduled"
        )
      )

    scheduled = transition!(initial, retry_event, @requested_at).snapshot
    assert :ok = Snapshot.validate(scheduled)
    assert {:ok, ^scheduled} = scheduled |> Snapshot.to_map() |> Snapshot.from_map()

    terminal =
      scheduled
      |> transition!(
        event!(Event.completed(%{"ok" => true}, id: "retry-invariants-completed")),
        @accepted_at
      )
      |> Map.fetch!(:snapshot)

    assert :ok = Snapshot.validate(terminal)

    assert {:error, :retry_history_missing_failure} =
             terminal
             |> Snapshot.to_map()
             |> Map.put("lastFailure", nil)
             |> Snapshot.from_map()

    assert {:error, :nonterminal_retry_missing_retry_at} =
             scheduled
             |> Snapshot.to_map()
             |> Map.put("retryAt", nil)
             |> Snapshot.from_map()

    assert {:error, :failure_without_retry_history} =
             initial
             |> Snapshot.to_map()
             |> Map.put("lastFailure", scheduled.last_failure)
             |> Snapshot.from_map()

    assert {:error, :retry_count_exceeds_revision} =
             scheduled
             |> Snapshot.to_map()
             |> Map.put("revision", 0)
             |> Snapshot.from_map()
  end

  defp task(id) do
    ProtocolTask.new!(
      id: id,
      created_at: @created_at,
      ttl_ms: 60_000,
      poll_interval_ms: 5,
      status_message: "Task accepted"
    )
  end

  defp transition!(snapshot, event, committed_at) do
    assert {:ok, %Transition{} = transition} =
             Transition.apply(snapshot, event, committed_at)

    transition
  end

  defp event!({:ok, %Event{} = event}), do: event

  defp input_request do
    %{
      "method" => "elicitation/create",
      "params" => %{
        "message" => "Approve the durable operation?",
        "requestedSchema" => %{
          "type" => "object",
          "properties" => %{"approved" => %{"type" => "boolean"}},
          "required" => ["approved"]
        }
      }
    }
  end

  defp input_response do
    %{"action" => "accept", "content" => %{"approved" => true}}
  end
end
