defmodule MCP.TasksExtensionAcceptanceTest do
  use ExUnit.Case, async: false

  @moduletag mcp_contract: ["tasks-extension-lifecycle"]
  @moduletag :tasks_package

  alias MCP.Context
  alias MCP.Extensions.Tasks.RetryPolicy
  alias MCP.Extensions.Tasks.Runner
  alias MCP.Extensions.Tasks.Snapshot
  alias MCP.Extensions.Tasks.Store
  alias MCP.Extensions.Tasks.Store.Memory
  alias MCP.Extensions.Tasks.Work
  alias MCP.Transport.Context, as: TransportContext
  alias MCPEx.TasksTestSupport, as: TasksSupport

  setup do
    scope = fn context ->
      case context.auth do
        %{"tenant" => tenant} -> {:tenant, tenant}
        _other -> :shared
      end
    end

    store = start_supervised!({Memory, scope: scope})
    store_ref = {Memory, store}
    runner = start_supervised!({Runner, store: store_ref})

    %{
      runtime: TasksSupport.runtime(store, runner, self()),
      runner: runner,
      store: store,
      store_ref: store_ref
    }
  end

  test "an application work builder persists only its JSON-safe authority projection", %{
    runner: runner,
    store: store,
    store_ref: store_ref
  } do
    auth = %{"tenant" => "durable-tenant", "requestSecret" => "do-not-project"}

    builder = fn task_id, name, arguments, context ->
      Work.new!(task_id, "example/export", %{
        "name" => name,
        "arguments" => arguments,
        "tenant" => context.auth["tenant"]
      })
    end

    retry_policy = RetryPolicy.new!([100, 500])

    runtime =
      TasksSupport.runtime(store, runner, self(),
        work_builder: builder,
        retry_policy: retry_policy
      )

    assert {:ok, %{"result" => created}} =
             TasksSupport.call(
               runtime,
               "custom-work-builder",
               "slow_compute",
               %{"block" => true, "label" => "custom-work"},
               auth: auth
             )

    task_id = created["taskId"]

    access_context = %Context{
      protocol_version: "2026-07-28",
      protocol: MCP.Protocol.V2026_07_28,
      transport: %TransportContext{transport: :direct},
      auth: auth
    }

    assert {:ok, access} = Store.authorize(store_ref, access_context, {:get, task_id})
    assert {:ok, %Snapshot{} = snapshot} = Store.get(store_ref, task_id, access)

    assert snapshot.work ==
             Work.new!(
               task_id,
               "example/export",
               %{
                 "name" => "slow_compute",
                 "arguments" => %{"block" => true, "label" => "custom-work"},
                 "tenant" => "durable-tenant"
               },
               retry_policy: retry_policy
             )

    refute JSON.encode!(Work.to_map(snapshot.work)) =~ "do-not-project"

    assert_receive {:tasks_barrier_entered, "custom-work", worker}, 1_000
    send(worker, {:tasks_release, "custom-work"})
  end

  test "a work builder cannot split task and idempotency identity", %{
    runner: runner,
    store: store
  } do
    builder = fn _task_id, _name, _arguments, _context ->
      Work.new!("different-identity", "example/export", %{})
    end

    runtime = TasksSupport.runtime(store, runner, self(), work_builder: builder)

    assert {:ok, %{"error" => %{"code" => -32_603}}} =
             TasksSupport.call(
               runtime,
               "mismatched-work-identity",
               "slow_compute",
               %{"block" => true, "label" => "must-not-run"}
             )

    assert :sys.get_state(store).entries == %{}
    refute_receive {:tasks_barrier_entered, "must-not-run", _worker}
  end

  test "tasks/update rejects malformed input responses as invalid params", %{
    runtime: runtime
  } do
    for {suffix, responses} <- [
          {"empty-key", %{"" => %{}}},
          {"non-object", %{"approval" => []}}
        ] do
      raw =
        TasksSupport.request("invalid-input-response-#{suffix}", "tasks/update", %{
          "taskId" => "not-looked-up",
          "inputResponses" => responses
        })

      assert {:ok, %{"error" => %{"code" => -32_602}}} =
               TasksSupport.dispatch(runtime, raw)
    end
  end

  test "creates a flat, immediately visible task and inlines the completed tool result", %{
    runtime: runtime
  } do
    assert {:ok, %{"result" => created}} =
             TasksSupport.call(
               runtime,
               "create-flat",
               "slow_compute",
               %{"block" => true, "label" => "flat"}
             )

    assert created["resultType"] == "task"
    assert created["status"] == "working"
    assert is_binary(created["taskId"])
    assert is_binary(created["createdAt"])
    assert is_binary(created["lastUpdatedAt"])
    assert {:ok, _created_at, 0} = DateTime.from_iso8601(created["createdAt"])
    assert {:ok, _updated_at, 0} = DateTime.from_iso8601(created["lastUpdatedAt"])
    assert created["ttlMs"] == 60_000
    assert created["pollIntervalMs"] == 5

    refute Map.has_key?(created, "task")
    refute Map.has_key?(created, "result")
    refute Map.has_key?(created, "error")
    refute Map.has_key?(created, "inputRequests")
    refute Map.has_key?(created, "requestState")
    refute Map.has_key?(created, "ttl")
    refute Map.has_key?(created, "pollInterval")

    assert_receive {:tasks_barrier_entered, "flat", worker}, 1_000

    task_id = created["taskId"]

    assert {:ok, %{"result" => visible}} =
             TasksSupport.get(runtime, "immediate-get", task_id)

    assert visible["resultType"] == "complete"
    assert visible["taskId"] == task_id
    assert visible["status"] == "working"
    refute Map.has_key?(visible, "result")
    refute Map.has_key?(visible, "error")
    refute Map.has_key?(visible, "requestState")

    send(worker, {:tasks_release, "flat"})

    assert {:ok, %{"result" => completed}} =
             TasksSupport.eventually_get(
               runtime,
               task_id,
               &(&1["status"] == "completed")
             )

    assert completed["resultType"] == "complete"
    assert completed["result"]["isError"] == false

    assert completed["result"]["structuredContent"] == %{
             "computed" => true,
             "label" => "flat"
           }

    refute get_in(completed, ["result", "_meta", "io.modelcontextprotocol/related-task"])
    refute Map.has_key?(completed, "requestState")
    refute Map.has_key?(completed, "ttl")
    refute Map.has_key?(completed, "pollInterval")
  end

  test "tool-domain errors complete with isError while protocol crashes fail", %{
    runtime: runtime
  } do
    assert {:ok, %{"result" => domain_created}} =
             TasksSupport.call(runtime, "domain-create", "failing_job")

    assert domain_created["resultType"] == "task"

    assert {:ok, %{"result" => domain_task}} =
             TasksSupport.eventually_get(
               runtime,
               domain_created["taskId"],
               &(&1["status"] == "completed")
             )

    assert domain_task["resultType"] == "complete"
    assert domain_task["status"] == "completed"
    assert domain_task["result"]["isError"] == true

    assert [%{"type" => "text", "text" => "Actionable task failure"}] =
             domain_task["result"]["content"]

    refute Map.has_key?(domain_task, "error")

    assert {:ok, %{"result" => crash_created}} =
             TasksSupport.call(runtime, "crash-create", "protocol_error_job")

    assert {:ok, %{"result" => failed_task}} =
             TasksSupport.eventually_get(
               runtime,
               crash_created["taskId"],
               &(&1["status"] == "failed")
             )

    assert failed_task["resultType"] == "complete"
    assert failed_task["status"] == "failed"
    assert failed_task["error"]["code"] == -32_603
    assert is_binary(failed_task["error"]["message"])
    refute failed_task["error"]["message"] =~ "private task crash detail"
    refute Map.has_key?(failed_task, "result")
  end

  test "task work detaches request transport authority before the requester exits", %{
    runtime: runtime,
    runner: runner
  } do
    owner = self()
    sentinel = make_ref()
    auth = %{"tenant" => "detached"}

    transport = %TransportContext{
      transport: :request_probe,
      peer: {{192, 0, 2, 44}, 49_999},
      request_headers: [{"Authorization", "request-only"}],
      response_handle: {:response_handle, sentinel},
      connection_ref: {:connection_ref, sentinel},
      metadata: %{
        auth: auth,
        progress: {:progress, sentinel},
        session: {:session, sentinel},
        request_authority: sentinel
      }
    }

    raw =
      TasksSupport.request(
        "detached-request",
        "tools/call",
        %{"name" => "detached_context", "arguments" => %{}}
      )
      |> put_in(
        ["params", "_meta", "io.modelcontextprotocol/test-request-metadata"],
        %{"present" => true}
      )

    {requester, monitor} =
      spawn_monitor(fn ->
        response = TasksSupport.dispatch(runtime, raw, transport_context: transport)
        send(owner, {:tasks_detached_created, self(), response})
      end)

    assert_receive {:tasks_detached_created, ^requester, {:ok, %{"result" => created}}}, 1_000
    assert created["resultType"] == "task"
    assert_receive {:DOWN, ^monitor, :process, ^requester, :normal}, 1_000
    assert_receive {:tasks_detached_ready, worker}, 1_000

    runner_state = :sys.get_state(runner)
    refute contains_term?(runner_state, &match?(%Context{}, &1))
    refute contains_term?(runner_state, &(&1 === sentinel))

    send(worker, :inspect_detached)

    assert_receive {:tasks_detached_observed, observed}, 1_000

    assert observed == %{
             application_owner: owner,
             auth: auth,
             execution_id: created["taskId"],
             request_id_nil?: true,
             session_nil?: true,
             progress_nil?: true,
             metadata_empty?: true,
             transport: :task,
             peer_nil?: true,
             request_headers_empty?: true,
             response_handle_nil?: true,
             connection_ref_nil?: true,
             transport_metadata_empty?: true
           }

    send(worker, :release_detached)

    assert {:ok, %{"result" => completed}} =
             TasksSupport.eventually_get(
               runtime,
               created["taskId"],
               &(&1["status"] == "completed"),
               auth: auth
             )

    assert completed["result"]["structuredContent"] == %{"detached" => true}
  end

  test "a non-JSON asynchronous result becomes a stable readable failure", %{
    runtime: runtime
  } do
    assert {:ok, %{"result" => created}} =
             TasksSupport.call(runtime, "invalid-result-create", "invalid_raw_result")

    task_id = created["taskId"]

    assert {:ok, %{"result" => failed}} =
             TasksSupport.eventually_get(runtime, task_id, &(&1["status"] == "failed"))

    assert failed["error"] == %{
             "code" => -32_603,
             "message" => "Task worker returned a non-JSON result"
           }

    refute Map.has_key?(failed, "result")
    assert is_binary(JSON.encode!(failed))

    for request_id <- ["invalid-result-get-one", "invalid-result-get-two"] do
      assert {:ok, %{"result" => repeated}} = TasksSupport.get(runtime, request_id, task_id)
      assert repeated == failed
    end
  end

  test "task creation is a per-request policy and required support reports -32021", %{
    runtime: runtime
  } do
    discovery_request = TasksSupport.request("discover", "server/discover")

    assert {:ok, %{"result" => discovery}} =
             TasksSupport.dispatch(runtime, discovery_request)

    assert discovery["capabilities"]["extensions"][TasksSupport.extension_id()] == %{}
    refute Map.has_key?(discovery["capabilities"], "tasks")

    assert {:ok, %{"result" => sync_only}} =
             TasksSupport.call(runtime, "sync-with-cap", "greet", %{"name" => "MCP"})

    assert sync_only["resultType"] == "complete"
    assert sync_only["isError"] == false
    refute Map.has_key?(sync_only, "taskId")

    assert {:ok, %{"result" => optional_sync}} =
             TasksSupport.call(
               runtime,
               "optional-without-cap",
               "slow_compute",
               %{"label" => "sync-fallback"},
               tasks: false
             )

    assert optional_sync["resultType"] == "complete"
    assert optional_sync["structuredContent"]["computed"] == true
    refute Map.has_key?(optional_sync, "taskId")

    assert {:ok, %{"error" => required_error}} =
             TasksSupport.call(
               runtime,
               "required-without-cap",
               "failing_job",
               %{},
               tasks: false
             )

    assert required_error["code"] == -32_021

    assert get_in(required_error, [
             "data",
             "requiredCapabilities",
             "extensions",
             TasksSupport.extension_id()
           ]) == %{}

    for {method, params} <- [
          {"tasks/get", %{"taskId" => "not-negotiated"}},
          {"tasks/update", %{"taskId" => "not-negotiated", "inputResponses" => %{}}},
          {"tasks/cancel", %{"taskId" => "not-negotiated"}}
        ] do
      raw = TasksSupport.request("gate-#{method}", method, params, tasks: false)
      assert {:ok, %{"error" => %{"code" => -32_021}}} = TasksSupport.dispatch(runtime, raw)
    end

    assert {:ok, %{"result" => opted_in}} =
             TasksSupport.call(
               runtime,
               "per-request-opt-in",
               "slow_compute",
               %{"label" => "opted-in"}
             )

    assert opted_in["resultType"] == "task"
    assert is_binary(opted_in["taskId"])
  end

  test "legacy hints are ignored, removed methods stay removed, and unknown ids reject", %{
    runtime: runtime
  } do
    legacy =
      TasksSupport.request("legacy-hint", "tools/call", %{
        "name" => "greet",
        "arguments" => %{"name" => "Legacy"},
        "task" => %{"ttl" => 100, "pollInterval" => 1}
      })

    assert {:ok, %{"result" => legacy_result}} = TasksSupport.dispatch(runtime, legacy)
    assert legacy_result["resultType"] == "complete"
    refute Map.has_key?(legacy_result, "taskId")

    for method <- ["tasks/result", "tasks/list"] do
      raw = TasksSupport.request("removed-#{method}", method, %{"taskId" => "legacy"})
      assert {:ok, %{"error" => %{"code" => -32_601}}} = TasksSupport.dispatch(runtime, raw)
    end

    assert {:ok, %{"error" => %{"code" => -32_602}}} =
             TasksSupport.get(runtime, "unknown-get", "unknown-task")

    assert {:ok, %{"error" => %{"code" => -32_602}}} =
             TasksSupport.update(runtime, "unknown-update", "unknown-task", %{})

    assert {:ok, %{"error" => %{"code" => -32_602}}} =
             TasksSupport.cancel(runtime, "unknown-cancel", "unknown-task")
  end

  test "tasks/update resumes a parked task", %{runtime: runtime} do
    assert {:ok, %{"result" => created}} =
             TasksSupport.call(runtime, "input-create", "confirm_delete")

    task_id = created["taskId"]

    assert {:ok, %{"result" => waiting}} =
             TasksSupport.eventually_get(
               runtime,
               task_id,
               &(&1["status"] == "input_required")
             )

    assert waiting["resultType"] == "complete"
    assert waiting["status"] == "input_required"

    assert %{"confirmation" => %{"method" => "elicitation/create"}} =
             waiting["inputRequests"]

    response = %{"action" => "accept", "content" => %{"confirmed" => true}}

    assert {:ok, %{"result" => %{"resultType" => "complete"}}} =
             TasksSupport.update(runtime, "input-update", task_id, %{
               "confirmation" => response
             })

    assert {:ok, %{"result" => completed}} =
             TasksSupport.eventually_get(
               runtime,
               task_id,
               &(&1["status"] == "completed")
             )

    assert completed["result"]["structuredContent"]["confirmation"] == response
    refute Map.has_key?(completed, "inputRequests")
  end

  test "partial multi-input fulfillment leaves only unanswered keys and keys cannot be reused", %{
    runtime: runtime
  } do
    assert {:ok, %{"result" => multi_created}} =
             TasksSupport.call(runtime, "multi-create", "multi_input")

    multi_id = multi_created["taskId"]

    assert {:ok, %{"result" => two_pending}} =
             TasksSupport.eventually_get(runtime, multi_id, fn task ->
               task["status"] == "input_required" and
                 map_size(Map.get(task, "inputRequests", %{})) == 2
             end)

    assert Map.keys(two_pending["inputRequests"]) |> Enum.sort() == ["first", "second"]

    first_response = %{"action" => "accept", "content" => %{"confirmed" => true}}

    assert {:ok, %{"result" => %{"resultType" => "complete"}}} =
             TasksSupport.update(runtime, "multi-first", multi_id, %{
               "first" => first_response
             })

    assert {:ok, %{"result" => after_first}} =
             TasksSupport.get(runtime, "multi-after-first", multi_id)

    assert after_first["status"] == "input_required"
    assert Map.keys(after_first["inputRequests"]) == ["second"]

    assert {:ok, %{"result" => %{"resultType" => "complete"}}} =
             TasksSupport.update(runtime, "multi-unknown-key", multi_id, %{
               "never-issued" => %{"ignored" => true}
             })

    assert {:ok, %{"result" => still_pending}} =
             TasksSupport.get(runtime, "multi-still-pending", multi_id)

    assert Map.keys(still_pending["inputRequests"]) == ["second"]

    second_response = %{"action" => "accept", "content" => %{"confirmed" => false}}

    assert {:ok, %{"result" => %{"resultType" => "complete"}}} =
             TasksSupport.update(runtime, "multi-second", multi_id, %{
               "second" => second_response
             })

    assert {:ok, %{"result" => multi_completed}} =
             TasksSupport.eventually_get(
               runtime,
               multi_id,
               &(&1["status"] == "completed")
             )

    assert multi_completed["result"]["structuredContent"]["responses"] == %{
             "first" => first_response,
             "second" => second_response
           }

    assert {:ok, %{"result" => reuse_created}} =
             TasksSupport.call(runtime, "reuse-create", "key_reuse")

    reuse_id = reuse_created["taskId"]

    assert {:ok, %{"result" => reuse_waiting}} =
             TasksSupport.eventually_get(
               runtime,
               reuse_id,
               &(&1["status"] == "input_required")
             )

    assert Map.keys(reuse_waiting["inputRequests"]) == ["one-shot"]

    one_shot_response = %{"action" => "accept", "content" => %{"confirmed" => true}}

    assert {:ok, %{"result" => %{"resultType" => "complete"}}} =
             TasksSupport.update(runtime, "reuse-update", reuse_id, %{
               "one-shot" => one_shot_response
             })

    assert_receive {:tasks_key_reuse_result, {:error, :duplicate_input_key}}, 1_000

    assert {:ok, %{"result" => reuse_completed}} =
             TasksSupport.eventually_get(
               runtime,
               reuse_id,
               &(&1["status"] == "completed")
             )

    assert reuse_completed["result"]["structuredContent"]["reuseRejected"] == true

    assert reuse_completed["result"]["structuredContent"]["firstResponse"] ==
             one_shot_response
  end

  test "task visibility and mutation are isolated by request scope", %{runtime: runtime} do
    tenant_a = [auth: %{"tenant" => "a"}]
    tenant_b = [auth: %{"tenant" => "b"}]

    assert {:ok, %{"result" => created}} =
             TasksSupport.call(
               runtime,
               "scoped-create",
               "slow_compute",
               %{"block" => true, "label" => "scoped"},
               tenant_a
             )

    assert_receive {:tasks_barrier_entered, "scoped", _worker}, 1_000
    task_id = created["taskId"]

    assert {:ok, %{"error" => %{"code" => -32_602}}} =
             TasksSupport.get(runtime, "scope-get-b", task_id, tenant_b)

    assert {:ok, %{"error" => %{"code" => -32_602}}} =
             TasksSupport.update(runtime, "scope-update-b", task_id, %{}, tenant_b)

    assert {:ok, %{"error" => %{"code" => -32_602}}} =
             TasksSupport.cancel(runtime, "scope-cancel-b", task_id, tenant_b)

    assert {:ok, %{"result" => %{"status" => "working"}}} =
             TasksSupport.get(runtime, "scope-get-a", task_id, tenant_a)

    assert {:ok, %{"result" => %{"resultType" => "complete"}}} =
             TasksSupport.cancel(runtime, "scope-cancel-a", task_id, tenant_a)

    assert {:ok, %{"result" => cancelled}} =
             TasksSupport.get(runtime, "scope-cancelled-a", task_id, tenant_a)

    assert cancelled["status"] == "cancelled"
  end

  defp contains_term?(term, predicate) when is_function(predicate, 1) do
    predicate.(term) or contains_child_term?(term, predicate)
  end

  defp contains_child_term?(term, predicate) when is_map(term) do
    term
    |> :maps.to_list()
    |> Enum.any?(fn {key, value} ->
      contains_term?(key, predicate) or contains_term?(value, predicate)
    end)
  end

  defp contains_child_term?(term, predicate) when is_list(term) do
    Enum.any?(term, &contains_term?(&1, predicate))
  end

  defp contains_child_term?(term, predicate) when is_tuple(term) do
    term
    |> Tuple.to_list()
    |> Enum.any?(&contains_term?(&1, predicate))
  end

  defp contains_child_term?(_term, _predicate), do: false
end
