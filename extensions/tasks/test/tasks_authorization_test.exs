defmodule Snodo.Extensions.TasksAuthorizationTest do
  use ExUnit.Case, async: true

  alias Snodo.Extensions.Tasks
  alias Snodo.Extensions.Tasks.Runner
  alias Snodo.Extensions.Tasks.Store.Memory
  alias Snodo.Protocol.V2026_07_28
  alias Snodo.Router
  alias Snodo.Server.Runtime
  alias SnodoTest.TasksTestSupport, as: Support

  defmodule Guarded do
    use Snodo.Tool, name: "guarded"

    input_schema(%{
      "type" => "object",
      "properties" => %{"x" => %{"type" => "integer"}},
      "required" => ["x"]
    })

    @impl true
    def call(_arguments, context) do
      send(context.auth["owner"], {:guarded_ran, context.request_method})
      {:ok, Snodo.Result.text("ran")}
    end
  end

  defmodule DenyAll do
    @behaviour Snodo.Authorization

    @impl true
    def authorize(phase, component, context, _options) do
      send(context.auth["owner"], {:policy, phase, component.name, context.request_method})
      {:error, Snodo.Error.authorization(-32_003, "Not permitted")}
    end
  end

  defmodule DenyToolsCall do
    @behaviour Snodo.Authorization

    @impl true
    def authorize(:invocation, _component, %{request_method: "tools/call"}, _options),
      do: {:error, Snodo.Error.authorization(-32_003, "Not permitted")}

    def authorize(_phase, _component, _context, _options), do: :ok
  end

  defmodule Recording do
    @behaviour Snodo.Authorization

    @impl true
    def authorize(phase, _component, context, _options) do
      send(context.auth["owner"], {:policy, phase, context.request_method})
      :ok
    end
  end

  defmodule DurableExecutor do
    @behaviour Snodo.Extensions.Tasks.WorkExecutor

    @impl true
    def execute(work, _cancellation, owner) do
      send(owner, {:executor_ran, work.input})
      {:completed, %{"content" => [], "resultType" => "complete"}}
    end
  end

  test "a refused call creates no task, with or without a durable executor" do
    for executor <- [nil, {DurableExecutor, self()}] do
      %{runtime: runtime, store: store} = start_tasks(DenyAll, executor)

      assert {:ok, %{"error" => %{"code" => -32_003}}} = call(runtime, %{"x" => 1})
      assert_received {:policy, :invocation, "guarded", "tools/call"}
      assert stored_tasks(store) == 0
      refute_receive {:executor_ran, _input}, 50
      refute_received {:guarded_ran, _method}
    end
  end

  test "missing arguments return the direct call's tool error and create no task" do
    %{runtime: runtime, store: store} = start_tasks(nil, {DurableExecutor, self()})

    assert {:ok, %{"result" => %{"isError" => true, "content" => [%{"text" => text}]}}} =
             call(runtime, %{})

    assert text =~ "x"
    assert stored_tasks(store) == 0
    refute_receive {:executor_ran, _input}, 50
  end

  test "a policy keyed on the request method refuses the task at creation" do
    %{runtime: runtime, store: store} = start_tasks(DenyToolsCall, nil)

    assert {:ok, %{"error" => %{"code" => -32_003}}} = call(runtime, %{"x" => 1})
    assert stored_tasks(store) == 0
    refute_receive {:guarded_ran, _method}, 50
  end

  test "authorized work runs, and the worker still sees the request method" do
    %{runtime: runtime} = start_tasks(Recording, nil)

    assert {:ok, %{"result" => %{"taskId" => _task_id}}} = call(runtime, %{"x" => 1})
    assert_receive {:policy, :invocation, "tools/call"}, 1_000
    assert_receive {:guarded_ran, "tools/call"}, 1_000

    %{runtime: durable} = start_tasks(Recording, {DurableExecutor, self()})

    assert {:ok, %{"result" => %{"taskId" => _task_id}}} = call(durable, %{"x" => 2})
    assert_receive {:policy, :invocation, "tools/call"}, 1_000
    assert_receive {:executor_ran, %{"arguments" => %{"x" => 2}}}, 1_000
  end

  defp start_tasks(policy, executor) do
    store = start_supervised!({Memory, []}, id: make_ref())
    store_ref = {Memory, store}

    runner_options =
      if executor, do: [store: store_ref, executor: executor], else: [store: store_ref]

    runner = start_supervised!({Runner, runner_options}, id: make_ref())

    runtime =
      Runtime.new(
        router: Router.register_tool(Router.new(), Guarded),
        protocols: [V2026_07_28],
        authorization: policy,
        extensions: [
          {Tasks, store: store_ref, runner: runner, task_support: %{"guarded" => :optional}}
        ],
        server_info: %{"name" => "tasks-authorization", "version" => "1"},
        capabilities: %{"tools" => %{}, "extensions" => %{Tasks.id() => %{}}}
      )

    %{runtime: runtime, store: store}
  end

  defp call(runtime, arguments) do
    Support.call(runtime, 1, "guarded", arguments, auth: %{"sub" => "alice", "owner" => self()})
  end

  defp stored_tasks(store), do: map_size(:sys.get_state(store).entries)
end
