defmodule Snodo.Extensions.Tasks.Store.ContractTest do
  @moduledoc """
  Reusable ExUnit checks for a `Snodo.Extensions.Tasks.Store` implementation.

  Use this module inside an `ExUnit.Case` and pass `:start_store`, an arity-2
  function receiving the test context and store options. It must return a
  fresh `{module, state}` reference. The suite passes `:max_tasks` and
  `:max_active_tasks_per_scope` to check capacity. Start a store with a scope
  function based on `context.auth["tenant"]`; each test uses distinct tenant
  values. The function may register cleanup with `on_exit/1`.

      use ExUnit.Case, async: false
      use Snodo.Extensions.Tasks.Store.ContractTest,
        start_store: &__MODULE__.start_contract_store/2

  A store whose concurrent writers can be refused with a documented, retryable
  backpressure result passes `:retryable?`, an arity-1 function that returns
  true for such a result. The capacity check races two creations; a creation
  refused that way is retried once after the race, so the check still requires
  exactly one creation and one capacity refusal. Without `:retryable?`, no
  result is retried.

      use Snodo.Extensions.Tasks.Store.ContractTest,
        start_store: &__MODULE__.start_contract_store/2,
        retryable?: &(&1 == {:error, :database_busy})

  The suite checks the public store boundary. Run backend-specific persistence,
  restart, database transaction, and stress tests alongside it.
  """

  alias Snodo.Context
  alias Snodo.Extensions.Tasks.Store
  alias Snodo.Extensions.Tasks.Task, as: ProtocolTask
  alias Snodo.Extensions.Tasks.Work

  @doc false
  @spec retry(result, (result -> boolean()) | nil, (-> result)) :: result when result: term()
  def retry(result, nil, _again), do: result
  def retry(result, retryable, again), do: if(retryable.(result), do: again.(), else: result)

  @doc false
  @spec create(Store.ref(), String.t(), String.t(), (String.t() -> Context.t()), keyword()) ::
          {:ok, Snodo.Extensions.Tasks.Snapshot.t()} | {:error, term()}
  def create(store, id, tenant, context_for, opts \\ []) do
    created_at =
      Keyword.get_lazy(opts, :created_at, fn ->
        DateTime.utc_now() |> DateTime.to_iso8601()
      end)

    task =
      ProtocolTask.new!(
        id: id,
        created_at: created_at,
        ttl_ms: Keyword.get(opts, :ttl_ms, 60_000),
        poll_interval_ms: 10
      )

    work = Work.new!(id, "contract/test", %{"taskId" => id}, Keyword.take(opts, [:retry_policy]))
    {:ok, access} = Store.authorize(store, context_for.(tenant), {:create, id})
    Store.create(store, task, work, access)
  end

  @doc false
  @spec access(
          Snodo.Extensions.Tasks.Store.ref(),
          String.t(),
          Store.action(),
          (String.t() -> Context.t())
        ) ::
          Store.access()
  def access(store, tenant, action, context_for) do
    {:ok, value} = Store.authorize(store, context_for.(tenant), action)
    value
  end

  @doc false
  @spec id(String.t()) :: String.t()
  def id(label), do: "contract-#{label}-#{System.unique_integer([:positive])}"

  @doc "Injects the shared store contract tests into an ExUnit case."
  defmacro __using__(opts) do
    starter = Keyword.fetch!(opts, :start_store)
    retryable = Keyword.get(opts, :retryable?)

    tests = [
      revision_test(starter),
      claim_test(starter),
      retry_test(starter),
      capacity_test(starter, retryable),
      ttl_test(starter),
      input_test(starter)
    ]

    quote do
      alias Snodo.Context
      alias Snodo.Extensions.Tasks.Event
      alias Snodo.Extensions.Tasks.RetryPolicy
      alias Snodo.Extensions.Tasks.Snapshot
      alias Snodo.Extensions.Tasks.Store
      alias Snodo.Extensions.Tasks.Store.ContractTest
      alias Snodo.Extensions.Tasks.Transition
      alias Snodo.Protocol.V2026_07_28
      alias Snodo.Transport.Context, as: TransportContext

      defp contract_context(tenant) do
        %Context{
          protocol_version: V2026_07_28.version(),
          protocol: V2026_07_28,
          transport: %TransportContext{transport: :direct},
          auth: %{"tenant" => tenant}
        }
      end

      unquote_splicing(tests)
    end
  end

  defp revision_test(starter) do
    quote do
      test "creates task and work atomically and guards event revisions", context do
        store = unquote(starter).(context, [])
        context_for = &contract_context/1
        id = ContractTest.id("revision")

        assert {:ok, %Snapshot{revision: 0} = initial} =
                 ContractTest.create(store, id, "tenant-a", context_for)

        assert initial.work.idempotency_key == id
        assert initial.work.input == %{"taskId" => id}
        read = ContractTest.access(store, "tenant-a", {:get, id}, context_for)
        assert {:ok, ^initial} = Store.get(store, id, read)
        assert {:ok, ^initial, lease} = Store.claim(store, id, "worker-a", 10_000)

        {:ok, event} = Event.completed(%{"content" => []}, id: ContractTest.id("event"))

        assert {:ok, %Transition{outcome: :applied, event_revision: 1, snapshot: winner}} =
                 Store.transition(store, id, 0, event, {:worker, lease})

        assert winner.revision == 1
        assert winner.task.status == :completed

        {:ok, loser} =
          Event.failed(%{"code" => -32_603, "message" => "late"}, nil,
            id: ContractTest.id("loser")
          )

        assert {:conflict, %Snapshot{revision: 1}} =
                 Store.transition(store, id, 0, loser, {:worker, lease})

        assert {:ok, %Transition{outcome: :duplicate, event_revision: 1, snapshot: ^winner}} =
                 Store.transition(store, id, 0, event, {:worker, lease})

        assert {:ok, ^winner} = Store.get(store, id, read)
      end
    end
  end

  defp claim_test(starter) do
    quote do
      test "released claims recover at a new generation and fence old leases", context do
        store = unquote(starter).(context, [])
        context_for = &contract_context/1
        id = ContractTest.id("claim")
        assert {:ok, %Snapshot{}} = ContractTest.create(store, id, "tenant-a", context_for)
        assert {:ok, %Snapshot{}, old_lease} = Store.claim(store, id, "worker-a", 10_000)
        assert :unavailable = Store.claim(store, id, "worker-b", 10_000)
        assert :ok = Store.release(store, old_lease)

        assert {:ok, %Snapshot{task: %{id: ^id}}, new_lease} =
                 Store.claim_next(store, "worker-b", 10_000)

        refute new_lease == old_lease
        assert {:error, :stale_lease} = Store.worker_snapshot(store, id, old_lease)
        assert {:ok, %Snapshot{}} = Store.worker_snapshot(store, id, new_lease)
        assert {:error, :stale_lease} = Store.renew(store, old_lease, 10_000)
        assert :empty = Store.claim_next(store, "worker-c", 10_000)

        {:ok, completed} = Event.completed(%{"content" => []}, id: ContractTest.id("fenced"))

        assert {:error, :stale_lease} =
                 Store.transition(store, id, 0, completed, {:worker, old_lease})

        assert {:ok, %Transition{outcome: :applied}} =
                 Store.transition(store, id, 0, completed, {:worker, new_lease})
      end
    end
  end

  defp retry_test(starter) do
    quote do
      test "retry deadline holds both exact and recovery claims", context do
        store = unquote(starter).(context, [])
        context_for = &contract_context/1
        id = ContractTest.id("retry")
        policy = RetryPolicy.new!([2_000])

        assert {:ok, %Snapshot{}} =
                 ContractTest.create(store, id, "tenant-a", context_for, retry_policy: policy)

        assert {:ok, %Snapshot{}, lease} = Store.claim(store, id, "worker-a", 10_000)

        {:ok, retry} =
          Event.retry_requested(%{"code" => -32_603, "message" => "retry"}, nil,
            id: ContractTest.id("retry-event")
          )

        assert {:ok, %Transition{outcome: :applied, snapshot: scheduled}} =
                 Store.transition(store, id, 0, retry, {:worker, lease})

        assert scheduled.retry_count == 1
        assert is_binary(scheduled.retry_at)
        assert :ok = Store.release(store, lease)
        assert {:deferred, remaining} = Store.claim(store, id, "too-early", 10_000)
        assert remaining > 0
        assert :empty = Store.claim_next(store, "too-early", 10_000)

        Process.send_after(self(), :retry_due, remaining + 100)
        assert_receive :retry_due, 4_000

        assert {:ok, %Snapshot{task: %{id: ^id}}, recovered} =
                 Store.claim_next(store, "worker-b", 10_000)

        assert {:error, :stale_lease} = Store.worker_snapshot(store, id, lease)
        assert {:ok, %Snapshot{}} = Store.worker_snapshot(store, id, recovered)
      end
    end
  end

  defp capacity_test(starter, retryable) do
    quote do
      test "capacity counts atomic creations and separates scopes", context do
        store = unquote(starter).(context, max_tasks: 2, max_active_tasks_per_scope: 1)
        context_for = &contract_context/1
        ids = [ContractTest.id("capacity-a"), ContractTest.id("capacity-b")]

        results =
          ids
          |> Enum.map(fn id ->
            Elixir.Task.async(fn -> ContractTest.create(store, id, "tenant-a", context_for) end)
          end)
          |> Elixir.Task.await_many(15_000)
          |> Enum.zip(ids)
          |> Enum.map(fn {result, id} ->
            ContractTest.retry(result, unquote(retryable), fn ->
              ContractTest.create(store, id, "tenant-a", context_for)
            end)
          end)

        assert Enum.count(results, &match?({:ok, %Snapshot{}}, &1)) == 1

        assert Enum.count(results, fn result ->
                 result == {:error, {:capacity_exceeded, :max_active_tasks_per_scope}}
               end) == 1

        assert {:ok, %Snapshot{}} =
                 ContractTest.create(
                   store,
                   ContractTest.id("capacity-c"),
                   "tenant-b",
                   context_for
                 )

        assert {:error, {:capacity_exceeded, :max_tasks}} =
                 ContractTest.create(
                   store,
                   ContractTest.id("capacity-d"),
                   "tenant-c",
                   context_for
                 )

        winning_id =
          results
          |> Enum.find_value(fn
            {:ok, %Snapshot{task: %{id: id}}} -> id
            _other -> nil
          end)

        foreign = ContractTest.access(store, "tenant-b", {:get, winning_id}, context_for)
        assert :not_found = Store.get(store, winning_id, foreign)

        foreign_cancel =
          ContractTest.access(store, "tenant-b", {:cancel, winning_id}, context_for)

        {:ok, cancel} = Event.cancelled(id: ContractTest.id("foreign-cancel"))

        assert :not_found =
                 Store.transition(store, winning_id, 0, cancel, {:request, foreign_cancel})

        own = ContractTest.access(store, "tenant-a", {:get, winning_id}, context_for)
        assert {:ok, %Snapshot{}} = Store.get(store, winning_id, own)
      end
    end
  end

  defp ttl_test(starter) do
    quote do
      test "creation-based TTL hides tasks before reaping", context do
        store = unquote(starter).(context, [])
        context_for = &contract_context/1
        id = ContractTest.id("ttl")
        created_at = DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.to_iso8601()

        assert {:ok, %Snapshot{}} =
                 ContractTest.create(store, id, "tenant-a", context_for,
                   created_at: created_at,
                   ttl_ms: 1_000
                 )

        read = ContractTest.access(store, "tenant-a", {:get, id}, context_for)
        cancel = ContractTest.access(store, "tenant-a", {:cancel, id}, context_for)
        {:ok, event} = Event.cancelled(id: ContractTest.id("cancel"))
        assert :not_found = Store.get(store, id, read)
        assert :not_found = Store.transition(store, id, 0, event, {:request, cancel})
        assert {:ok, reaped} = Store.reap(store)
        assert id in reaped
      end
    end
  end

  defp input_test(starter) do
    quote do
      test "accepted input responses survive in the snapshot inbox", context do
        store = unquote(starter).(context, [])
        context_for = &contract_context/1
        id = ContractTest.id("input")
        assert {:ok, %Snapshot{}} = ContractTest.create(store, id, "tenant-a", context_for)
        assert {:ok, %Snapshot{}, lease} = Store.claim(store, id, "worker-a", 10_000)

        request = %{
          "method" => "elicitation/create",
          "params" => %{
            "message" => "Continue?",
            "requestedSchema" => %{"type" => "object"}
          }
        }

        {:ok, ask} = Event.input_requested("approval", request, id: ContractTest.id("ask"))

        assert {:ok, %Transition{snapshot: waiting}} =
                 Store.transition(store, id, 0, ask, {:worker, lease})

        assert waiting.task.status == :input_required
        responses = %{"approval" => %{"action" => "accept", "content" => %{}}}
        {:ok, accepted} = Event.input_responses_accepted(responses, id: ContractTest.id("answer"))
        update = ContractTest.access(store, "tenant-a", {:update, id}, context_for)

        assert {:ok, %Transition{snapshot: resumed}} =
                 Store.transition(store, id, 1, accepted, {:request, update})

        assert resumed.task.status == :working
        assert resumed.accepted_input_responses == responses
        read = ContractTest.access(store, "tenant-a", {:get, id}, context_for)
        assert {:ok, ^resumed} = Store.get(store, id, read)
      end
    end
  end
end
