defmodule MCPEx.TasksInstrumentationSink do
  @behaviour MCP.Instrumentation

  @impl true
  def handle_event(event_name, measurements, metadata, owner) do
    send(owner, {:tasks_instrumentation, event_name, measurements, metadata})
    :ok
  end
end

defmodule MCP.TasksInstrumentationTest do
  use ExUnit.Case, async: false

  alias MCP.Extensions.Tasks.Runner
  alias MCP.Extensions.Tasks.Store.Memory
  alias MCPEx.TasksInstrumentationSink
  alias MCPEx.TasksTestSupport, as: TasksSupport

  test "runner emits bounded job and store-transition lifecycle events" do
    store = start_supervised!(Memory)

    runner =
      start_supervised!(
        {Runner, store: {Memory, store}, instrumentation: {TasksInstrumentationSink, self()}}
      )

    runtime = TasksSupport.runtime(store, runner, self())

    assert {:ok, %{"result" => created}} =
             TasksSupport.call(
               runtime,
               "instrumented-create",
               "slow_compute",
               %{"block" => true, "label" => "instrumented"}
             )

    task_id = created["taskId"]

    assert_receive {:tasks_instrumentation, [:mcp_ex, :tasks, :runner, :job, :start],
                    %{jobs: 1, system_time: system_time},
                    %{task_id: ^task_id, revision: 0, source: :request}}

    assert is_integer(system_time)
    assert_receive {:tasks_barrier_entered, "instrumented", worker}
    send(worker, {:tasks_release, "instrumented"})

    assert_receive {:tasks_instrumentation, [:mcp_ex, :tasks, :store, :transition],
                    %{duration: transition_duration},
                    %{
                      task_id: ^task_id,
                      expected_revision: 0,
                      event_kind: :completed,
                      authority: :worker,
                      outcome: :applied
                    }},
                   1_000

    assert transition_duration >= 0

    assert_receive {:tasks_instrumentation, [:mcp_ex, :tasks, :runner, :job, :stop],
                    %{duration: job_duration, jobs: 0},
                    %{
                      task_id: ^task_id,
                      outcome: :completed,
                      store_outcome: :applied,
                      release_outcome: :ok
                    }},
                   1_000

    assert job_duration >= transition_duration

    assert {:ok, %{"result" => %{"status" => "completed"}}} =
             TasksSupport.eventually_get(runtime, task_id, &(&1["status"] == "completed"))
  end

  test "request cancellation is observed without exposing access or payload values" do
    store = start_supervised!(Memory)

    runner =
      start_supervised!(
        {Runner, store: {Memory, store}, instrumentation: {TasksInstrumentationSink, self()}},
        id: :cancel_instrumentation_runner
      )

    runtime = TasksSupport.runtime(store, runner, self())

    assert {:ok, %{"result" => created}} =
             TasksSupport.call(
               runtime,
               "instrumented-cancel-create",
               "slow_compute",
               %{"block" => true, "label" => "private-payload"}
             )

    task_id = created["taskId"]
    assert_receive {:tasks_instrumentation, [:mcp_ex, :tasks, :runner, :job, :start], _, _}
    assert_receive {:tasks_barrier_entered, "private-payload", _worker}

    assert {:ok, %{"result" => %{"resultType" => "complete"}}} =
             TasksSupport.cancel(runtime, "instrumented-cancel", task_id)

    assert_receive {:tasks_instrumentation, [:mcp_ex, :tasks, :store, :transition], _measurements,
                    %{
                      task_id: ^task_id,
                      event_kind: :cancelled,
                      authority: :request,
                      outcome: :applied
                    } = transition_metadata}

    refute Map.has_key?(transition_metadata, :access)
    refute inspect(transition_metadata) =~ "private-payload"

    assert_receive {:tasks_instrumentation, [:mcp_ex, :tasks, :runner, :job, :stop], %{jobs: 0},
                    %{task_id: ^task_id, outcome: :cancelled}}
  end
end
