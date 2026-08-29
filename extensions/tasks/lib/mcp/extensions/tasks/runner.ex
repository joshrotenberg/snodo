defmodule MCP.Extensions.Tasks.Runner do
  @moduledoc """
  Independently supervised execution, recovery, and mid-task input coordination.

  Jobs are protected by renewable store claims. A claim generation fences an
  expired worker from committing after another runner has recovered the same
  descriptor. Recovery is intentionally at-least-once: applications should use
  `MCP.Extensions.Tasks.Work.idempotency_key` for external side effects.

  Executors may explicitly return `{:retry, error, status_message}`. The
  descriptor's finite retry policy is applied by the durable transition, the
  claim is released during backoff, and store-authoritative claim eligibility
  remains the source of truth after local timers or process restarts.

  Request contexts and transport handles never enter runner state. An optional
  application-owned `MCP.Extensions.Tasks.WorkExecutor` resolves persisted work
  on both the initial claim and every recovery claim.

  Configure `:instrumentation` with an `MCP.Instrumentation` sink to observe
  job starts/stops and every store transition attempted by the runner. Events
  include task identity and lifecycle classifications, never work input,
  authorization values, results, errors, or input responses.
  """

  use GenServer

  alias MCP.Cancellation
  alias MCP.Error
  alias MCP.Extensions.Tasks.Event
  alias MCP.Extensions.Tasks.Snapshot
  alias MCP.Extensions.Tasks.Store
  alias MCP.Extensions.Tasks.Transition
  alias MCP.Extensions.Tasks.WorkExecutor
  alias MCP.Instrumentation

  @max_transition_attempts 5
  @default_lease_ms 30_000
  @default_recovery_interval_ms 1_000
  @default_recovery_batch_size 100
  @release_retry_interval_ms 100

  @type server :: GenServer.server()
  @type outcome ::
          {:completed, map()}
          | {:failed, map(), String.t() | nil}
          | {:retry, map(), String.t() | nil}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))
  end

  @doc "Claims and starts work after its descriptor-bearing snapshot is visible."
  @spec start_task(server(), Snapshot.t(), (Cancellation.t() -> outcome()), keyword()) ::
          :ok | {:error, term()}
  def start_task(runner, %Snapshot{} = snapshot, fallback_work, opts \\ [])
      when is_function(fallback_work, 1) and is_list(opts) do
    GenServer.call(runner, {:start_task, snapshot, fallback_work, opts}, :infinity)
  end

  @doc "Parks the calling worker or replays persisted input after recovery."
  @spec await_input(server(), String.t(), String.t(), map(), Cancellation.t()) ::
          {:ok, map()} | {:error, term()}
  def await_input(runner, task_id, key, request, %Cancellation{} = execution_token)
      when is_binary(task_id) and is_binary(key) and is_map(request) do
    GenServer.call(
      runner,
      {:await_input, task_id, key, request, execution_token},
      :infinity
    )
  end

  @doc "Accepts persisted outstanding responses and wakes matching local workers."
  @spec update(server(), String.t(), map(), Store.access()) ::
          :ok | :not_found | {:error, term()}
  def update(runner, task_id, responses, access)
      when is_binary(task_id) and is_map(responses) do
    GenServer.call(runner, {:update, task_id, responses, access}, :infinity)
  end

  @doc "Commits cancellation, then cooperatively signals and stops local work."
  @spec cancel(server(), String.t(), Store.access()) ::
          :ok | :not_found | {:error, term()}
  def cancel(runner, task_id, access) when is_binary(task_id) do
    GenServer.call(runner, {:cancel, task_id, access}, :infinity)
  end

  @doc "Runs creation-based TTL cleanup and stops any matching local jobs."
  @spec reap(server()) :: {:ok, [String.t()]} | {:error, term()}
  def reap(runner), do: GenServer.call(runner, :reap, :infinity)

  @impl true
  def init(opts) do
    store = opts |> Keyword.fetch!(:store) |> Store.validate_ref!()
    executor = validate_executor(Keyword.get(opts, :executor))
    recover? = Keyword.get(opts, :recover, false)
    owner_id = Keyword.get_lazy(opts, :owner_id, &generate_owner_id/0)
    lease_ms = positive_option!(opts, :lease_ms, @default_lease_ms)
    heartbeat_ms = positive_option!(opts, :heartbeat_ms, max(div(lease_ms, 3), 1))

    if heartbeat_ms >= lease_ms do
      raise ArgumentError, ":heartbeat_ms must be shorter than :lease_ms"
    end

    if recover? and is_nil(executor) do
      raise ArgumentError, ":recover requires an :executor"
    end

    unless is_binary(owner_id) and owner_id != "" do
      raise ArgumentError, ":owner_id must be a non-empty string"
    end

    {:ok, supervisor} = Task.Supervisor.start_link()

    state = %{
      store: store,
      supervisor: supervisor,
      executor: executor,
      recover?: recover?,
      owner_id: owner_id,
      lease_ms: lease_ms,
      heartbeat_ms: heartbeat_ms,
      recovery_interval_ms:
        positive_option!(opts, :recovery_interval_ms, @default_recovery_interval_ms),
      recovery_batch_size:
        positive_option!(opts, :recovery_batch_size, @default_recovery_batch_size),
      reap_interval_ms: optional_positive_option!(opts, :reap_interval_ms),
      instrumentation: opts |> Keyword.get(:instrumentation) |> Instrumentation.normalize!(),
      jobs: %{},
      jobs_by_ref: %{},
      waiters: %{}
    }

    {:ok, state, {:continue, :bootstrap}}
  end

  @impl true
  def handle_continue(:bootstrap, state) do
    next =
      state
      |> maybe_schedule_recovery(0)
      |> maybe_schedule_reap()

    {:noreply, next}
  end

  @impl true
  def handle_call({:start_task, snapshot, fallback_work, _opts}, _from, state) do
    task_id = snapshot.task.id

    case Map.fetch(state.jobs, task_id) do
      {:ok, _recovery_won_creation_race} ->
        {:reply, :ok, state}

      :error ->
        case Store.claim(state.store, task_id, state.owner_id, state.lease_ms) do
          {:ok, %Snapshot{} = claimed, lease} ->
            {:reply, :ok, spawn_job(state, claimed, lease, fallback_work)}

          :unavailable ->
            {:reply, :ok, state}

          {:deferred, remaining_ms} ->
            schedule_retry_due(task_id, remaining_ms)
            {:reply, :ok, state}

          :not_found ->
            {:reply, {:error, :not_found}, state}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end
    end
  end

  def handle_call({:await_input, task_id, key, request, execution_token}, from, state) do
    cond do
      not Map.has_key?(state.jobs, task_id) ->
        {:reply, {:error, :not_running}, state}

      not current_execution?(state, task_id, execution_token) ->
        {:reply, {:error, :stale_worker}, state}

      waiter_registered?(state, task_id, key) ->
        {:reply, {:error, :duplicate_input_key}, state}

      true ->
        await_authoritative_input(state, task_id, key, request, from)
    end
  end

  def handle_call({:update, task_id, responses, access}, _from, state) do
    with {:ok, event} <- Event.input_responses_accepted(responses),
         {:ok, %Transition{} = transition, next} <-
           request_transition(state, task_id, event, access) do
      accepted = Map.get(transition.effects, :accepted_input_responses, %{})
      {:reply, :ok, deliver_input_responses(next, task_id, accepted)}
    else
      :not_found -> {:reply, :not_found, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:cancel, task_id, access}, _from, state) do
    with {:ok, event} <- Event.cancelled(),
         {:ok, %Transition{} = transition, next} <-
           request_transition(state, task_id, event, access) do
      stopped =
        if transition.snapshot.task.status == :cancelled,
          do: stop_job(next, task_id, :cancelled),
          else: next

      {:reply, :ok, stopped}
    else
      :not_found -> {:reply, :not_found, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:reap, _from, state) do
    case reap_store(state) do
      {:ok, reaped, next} -> {:reply, {:ok, reaped}, next}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_info(:recover, state) do
    next =
      state
      |> recover_available()
      |> maybe_schedule_recovery()

    {:noreply, next}
  end

  def handle_info(:reap, state) do
    next =
      case reap_store(state) do
        {:ok, _reaped, reaped_state} -> reaped_state
        {:error, _reason} -> state
      end

    {:noreply, maybe_schedule_reap(next)}
  end

  def handle_info({:retry_due, task_id}, state) do
    next =
      if Map.has_key?(state.jobs, task_id) do
        state
      else
        case Store.claim(state.store, task_id, state.owner_id, state.lease_ms) do
          {:ok, %Snapshot{} = snapshot, lease} -> spawn_job(state, snapshot, lease, nil)
          {:deferred, remaining_ms} -> schedule_retry_due(state, task_id, remaining_ms)
          _not_due_claimed_terminal_or_unavailable -> state
        end
      end

    {:noreply, next}
  end

  def handle_info({:retry_release, task_id, lease}, state) do
    next =
      case Store.release(state.store, lease) do
        :ok -> schedule_retry_due(state, task_id, 0)
        {:error, :stale_lease} -> schedule_retry_due(state, task_id, 0)
        {:error, _transient} -> schedule_retry_release(state, task_id, lease)
      end

    {:noreply, next}
  end

  def handle_info({:renew_claim, task_id, job_ref}, state) do
    case Map.fetch(state.jobs, task_id) do
      {:ok, %{ref: ^job_ref} = job} ->
        case Store.renew(state.store, job.lease, state.lease_ms) do
          {:ok, renewed} ->
            next =
              state
              |> put_job_lease(task_id, renewed)
              |> reconcile_inputs(task_id)

            schedule_renewal(next, task_id, job_ref)
            {:noreply, next}

          {:error, _stale_or_unavailable} ->
            {:noreply, stop_job(state, task_id, :stale_lease)}
        end

      _missing_or_replaced ->
        {:noreply, state}
    end
  end

  def handle_info({ref, outcome}, state) when is_reference(ref) do
    case current_job_by_ref(state, ref) do
      {:ok, task_id} ->
        Process.demonitor(ref, [:flush])
        {store_result, transitioned} = settle(state, task_id, outcome)
        {release_result, lease, released} = release_job_claim(transitioned, task_id)

        next =
          released
          |> instrument_job_stop(
            task_id,
            classify_job_outcome(outcome),
            store_result,
            release_result
          )
          |> fail_waiters(task_id, :finished)
          |> remove_job(task_id, ref)
          |> maybe_schedule_retry(store_result, release_result, lease)

        {:noreply, next}

      :stale ->
        Process.demonitor(ref, [:flush])
        {:noreply, drop_job_ref(state, ref)}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case current_job_by_ref(state, ref) do
      {:ok, task_id} ->
        error = Error.to_json_rpc(Error.internal("Task worker terminated", reason))

        {store_result, transitioned} =
          settle(state, task_id, {:failed, error, "Task worker terminated"})

        {release_result, _lease, released} = release_job_claim(transitioned, task_id)

        next =
          released
          |> instrument_job_stop(task_id, :worker_terminated, store_result, release_result)
          |> fail_waiters(task_id, :worker_terminated)
          |> remove_job(task_id, ref)

        {:noreply, next}

      :stale ->
        {:noreply, drop_job_ref(state, ref)}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    Enum.each(state.jobs, fn {_task_id, job} ->
      terminate_worker(job, :runner_stopped)
      _released = Store.release(state.store, job.lease)
    end)

    if Process.alive?(state.supervisor), do: Supervisor.stop(state.supervisor, :normal)

    :ok
  end

  defp await_authoritative_input(state, task_id, key, request, from) do
    job = Map.fetch!(state.jobs, task_id)

    case Store.worker_snapshot(state.store, task_id, job.lease) do
      {:ok, %Snapshot{} = snapshot} ->
        handle_input_state(state, snapshot, task_id, key, request, from)

      :not_found ->
        {:reply, {:error, :not_found}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp handle_input_state(state, snapshot, task_id, key, request, from) do
    case classify_input(snapshot, key, request) do
      {:ready, response} ->
        {:reply, {:ok, response}, state}

      :reattach ->
        park_waiter(state, task_id, key, from)

      :new ->
        request_new_input(state, task_id, key, request, from)

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp classify_input(%Snapshot{} = snapshot, key, request) do
    cond do
      Map.get(snapshot.accepted_input_responses, key) &&
          Map.get(snapshot.input_history, key) == request ->
        {:ready, Map.fetch!(snapshot.accepted_input_responses, key)}

      Map.get(snapshot.task.input_requests, key) == request &&
          Map.get(snapshot.input_history, key) == request ->
        :reattach

      Map.has_key?(snapshot.input_history, key) ->
        {:error, :duplicate_input_key}

      snapshot.task.status in [:completed, :failed, :cancelled] ->
        {:error, :terminal}

      true ->
        :new
    end
  end

  defp request_new_input(state, task_id, key, request, from) do
    with {:ok, event} <- Event.input_requested(key, request),
         {:ok, %Transition{} = transition, next} <-
           worker_transition(state, task_id, event) do
      case transition.outcome do
        :applied -> park_waiter(next, task_id, key, from)
        _unchanged -> {:reply, {:error, :terminal}, next}
      end
    else
      :not_found -> {:reply, {:error, :not_found}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp settle(state, task_id, outcome) do
    case settlement_event(outcome, state.executor) do
      {:ok, event} ->
        case worker_transition(state, task_id, event) do
          {:ok, %Transition{} = transition, next} -> {{:ok, transition}, next}
          other -> {other, state}
        end

      {:error, reason} ->
        {{:error, reason}, state}
    end
  end

  defp park_waiter(state, task_id, key, from) do
    waiter = %{from: from}

    waiting =
      Map.update(state.waiters, task_id, %{key => waiter}, fn task_waiters ->
        Map.put(task_waiters, key, waiter)
      end)

    {:noreply, %{state | waiters: waiting}}
  end

  defp settlement_event({:completed, result}, _executor) when is_map(result) do
    case Event.completed(result) do
      {:ok, event} -> {:ok, event}
      {:error, _invalid_result} -> invalid_outcome_event("Task worker returned a non-JSON result")
    end
  end

  defp settlement_event({:failed, error, status_message}, _executor) when is_map(error) do
    case Event.failed(error, status_message) do
      {:ok, event} -> {:ok, event}
      {:error, _invalid_error} -> invalid_outcome_event("Task worker returned a non-JSON error")
    end
  end

  defp settlement_event({:retry, _error, _status_message}, nil) do
    invalid_outcome_event("Task worker requested retry without a configured durable executor")
  end

  defp settlement_event({:retry, error, status_message}, _executor) when is_map(error) do
    case Event.retry_requested(error, status_message) do
      {:ok, event} -> {:ok, event}
      {:error, _invalid_error} -> invalid_outcome_event("Task worker returned a non-JSON error")
    end
  end

  defp settlement_event(_other, _executor) do
    invalid_outcome_event("Task worker returned an invalid outcome")
  end

  defp invalid_outcome_event(message) do
    error = Error.to_json_rpc(Error.internal(message))
    Event.failed(error, message)
  end

  defp worker_transition(state, task_id, event) do
    do_worker_transition(state, task_id, event, @max_transition_attempts)
  end

  defp do_worker_transition(_state, _task_id, _event, 0),
    do: {:error, :transition_conflict_limit}

  defp do_worker_transition(state, task_id, event, attempts_left) do
    case Map.fetch(state.jobs, task_id) do
      {:ok, job} ->
        case instrumented_transition(
               state,
               task_id,
               job.revision,
               event,
               {:worker, job.lease}
             ) do
          {:ok, %Transition{} = transition} ->
            next = put_job_revision(state, task_id, transition.snapshot.revision)
            {:ok, transition, next}

          {:conflict, %Snapshot{} = current} ->
            state
            |> put_job_revision(task_id, current.revision)
            |> do_worker_transition(task_id, event, attempts_left - 1)

          :not_found ->
            :not_found

          {:error, reason} ->
            {:error, reason}
        end

      :error ->
        {:error, :not_running}
    end
  end

  defp request_transition(state, task_id, event, access) do
    case Store.get(state.store, task_id, access) do
      {:ok, %Snapshot{} = snapshot} ->
        do_request_transition(
          state,
          task_id,
          snapshot.revision,
          event,
          access,
          @max_transition_attempts
        )

      :not_found ->
        :not_found

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp do_request_transition(_state, _task_id, _revision, _event, _access, 0),
    do: {:error, :transition_conflict_limit}

  defp do_request_transition(state, task_id, revision, event, access, attempts_left) do
    case instrumented_transition(
           state,
           task_id,
           revision,
           event,
           {:request, access}
         ) do
      {:ok, %Transition{} = transition} ->
        next = put_job_revision(state, task_id, transition.snapshot.revision)
        {:ok, transition, next}

      {:conflict, %Snapshot{} = current} ->
        state
        |> put_job_revision(task_id, current.revision)
        |> do_request_transition(
          task_id,
          current.revision,
          event,
          access,
          attempts_left - 1
        )

      :not_found ->
        :not_found

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp recover_available(%{recover?: false} = state), do: state

  defp recover_available(state) do
    Enum.reduce_while(1..state.recovery_batch_size, state, fn _attempt, current ->
      case Store.claim_next(current.store, current.owner_id, current.lease_ms) do
        {:ok, %Snapshot{} = snapshot, lease} ->
          recovered =
            current
            |> stop_job(snapshot.task.id, :reclaimed)
            |> spawn_job(snapshot, lease, nil)

          {:cont, recovered}

        :empty ->
          {:halt, current}

        {:error, _reason} ->
          {:halt, current}
      end
    end)
  end

  defp spawn_job(state, snapshot, lease, fallback_work) do
    token = Cancellation.new()
    work = execution_function(state.executor, snapshot, fallback_work)

    task = Task.Supervisor.async_nolink(state.supervisor, fn -> work.(token) end)

    job = %{
      pid: task.pid,
      ref: task.ref,
      revision: snapshot.revision,
      lease: lease,
      token: token,
      started_at: System.monotonic_time()
    }

    next = %{
      state
      | jobs: Map.put(state.jobs, snapshot.task.id, job),
        jobs_by_ref: Map.put(state.jobs_by_ref, task.ref, snapshot.task.id)
    }

    schedule_renewal(next, snapshot.task.id, task.ref)

    Instrumentation.emit(
      state.instrumentation,
      [:mcp_ex, :tasks, :runner, :job, :start],
      %{jobs: map_size(next.jobs), system_time: System.system_time()},
      %{
        task_id: snapshot.task.id,
        revision: snapshot.revision,
        source: if(is_nil(fallback_work), do: :recovery, else: :request)
      }
    )

    next
  end

  defp execution_function(nil, _snapshot, fallback_work) when is_function(fallback_work, 1),
    do: fallback_work

  defp execution_function(nil, _snapshot, nil) do
    fn _cancellation ->
      error = Error.to_json_rpc(Error.internal("Recovered work has no configured executor"))
      {:failed, error, "Recovered work has no configured executor"}
    end
  end

  defp execution_function(executor, %Snapshot{work: work}, _fallback_work) do
    fn cancellation ->
      case WorkExecutor.invoke(executor, work, cancellation) do
        {:ok, outcome} ->
          outcome

        {:error, reason} ->
          error = Error.to_json_rpc(Error.internal("Durable task executor failed", reason))
          {:failed, error, "Durable task executor failed"}
      end
    end
  end

  defp deliver_input_responses(state, task_id, responses) do
    Enum.reduce(responses, state, fn {key, response}, acc ->
      case get_in(acc.waiters, [task_id, key]) do
        nil ->
          acc

        waiter ->
          GenServer.reply(waiter.from, {:ok, response})
          update_in(acc.waiters, &drop_waiter(&1, task_id, key))
      end
    end)
  end

  defp reconcile_inputs(state, task_id) do
    case Map.fetch(state.jobs, task_id) do
      {:ok, job} ->
        case Store.worker_snapshot(state.store, task_id, job.lease) do
          {:ok, snapshot} ->
            deliver_input_responses(state, task_id, snapshot.accepted_input_responses)

          _missing_or_stale ->
            state
        end

      :error ->
        state
    end
  end

  defp reap_store(state) do
    case Store.reap(state.store) do
      {:ok, task_ids} ->
        next = Enum.reduce(task_ids, state, &stop_job(&2, &1, :expired))
        {:ok, task_ids, next}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp stop_job(state, task_id, reason) do
    case Map.fetch(state.jobs, task_id) do
      {:ok, job} ->
        terminate_worker(job, reason)
        release_result = Store.release(state.store, job.lease)

        state
        |> instrument_job_stop(
          task_id,
          classify_stop_reason(reason),
          :not_settled,
          release_result
        )
        |> fail_waiters(task_id, reason)
        |> remove_job(task_id, job.ref)

      :error ->
        state
    end
  end

  defp terminate_worker(job, reason) do
    Cancellation.cancel(job.token, reason)

    if Process.alive?(job.pid) do
      Process.exit(job.pid, :kill)
    end

    Process.demonitor(job.ref, [:flush])
    :ok
  end

  defp release_job_claim(state, task_id) do
    case Map.fetch(state.jobs, task_id) do
      {:ok, job} ->
        {Store.release(state.store, job.lease), job.lease, state}

      :error ->
        {{:error, :missing_job}, nil, state}
    end
  end

  defp fail_waiters(state, task_id, reason) do
    task_waiters = Map.get(state.waiters, task_id, %{})

    Enum.each(task_waiters, fn {_key, waiter} ->
      GenServer.reply(waiter.from, {:error, reason})
    end)

    %{state | waiters: Map.delete(state.waiters, task_id)}
  end

  defp remove_job(state, task_id, ref) do
    %{
      state
      | jobs: Map.delete(state.jobs, task_id),
        jobs_by_ref: Map.delete(state.jobs_by_ref, ref)
    }
  end

  defp drop_job_ref(state, ref) do
    %{state | jobs_by_ref: Map.delete(state.jobs_by_ref, ref)}
  end

  defp current_job_by_ref(state, ref) do
    with {:ok, task_id} <- Map.fetch(state.jobs_by_ref, ref),
         {:ok, %{ref: ^ref}} <- Map.fetch(state.jobs, task_id) do
      {:ok, task_id}
    else
      _missing_or_replaced -> :stale
    end
  end

  defp current_execution?(state, task_id, %Cancellation{} = execution_token) do
    case Map.fetch(state.jobs, task_id) do
      {:ok, %{token: ^execution_token}} -> true
      _missing_or_replaced -> false
    end
  end

  defp current_execution?(_state, _task_id, _execution_token), do: false

  defp put_job_revision(state, task_id, revision) do
    case Map.fetch(state.jobs, task_id) do
      {:ok, job} -> put_in(state.jobs[task_id], %{job | revision: revision})
      :error -> state
    end
  end

  defp put_job_lease(state, task_id, lease) do
    case Map.fetch(state.jobs, task_id) do
      {:ok, job} -> put_in(state.jobs[task_id], %{job | lease: lease})
      :error -> state
    end
  end

  defp instrumented_transition(state, task_id, revision, event, authority) do
    started_at = System.monotonic_time()
    result = Store.transition(state.store, task_id, revision, event, authority)

    Instrumentation.emit(
      state.instrumentation,
      [:mcp_ex, :tasks, :store, :transition],
      %{duration: System.monotonic_time() - started_at},
      %{
        task_id: task_id,
        expected_revision: revision,
        event_kind: event.kind,
        authority: elem(authority, 0),
        outcome: classify_transition_outcome(result)
      }
    )

    result
  end

  defp instrument_job_stop(state, task_id, outcome, store_result, release_result) do
    case Map.fetch(state.jobs, task_id) do
      {:ok, job} ->
        Instrumentation.emit(
          state.instrumentation,
          [:mcp_ex, :tasks, :runner, :job, :stop],
          %{
            duration: System.monotonic_time() - job.started_at,
            jobs: max(map_size(state.jobs) - 1, 0)
          },
          %{
            task_id: task_id,
            outcome: outcome,
            store_outcome: classify_store_result(store_result),
            release_outcome: classify_release_result(release_result)
          }
        )

        state

      :error ->
        state
    end
  end

  defp classify_transition_outcome({:ok, %Transition{outcome: outcome}}), do: outcome
  defp classify_transition_outcome({:conflict, %Snapshot{}}), do: :conflict
  defp classify_transition_outcome(:not_found), do: :not_found
  defp classify_transition_outcome({:error, _reason}), do: :error

  defp classify_job_outcome({:completed, _result}), do: :completed
  defp classify_job_outcome({:failed, _error, _message}), do: :failed
  defp classify_job_outcome({:retry, _error, _message}), do: :retry
  defp classify_job_outcome(_invalid), do: :invalid

  defp classify_stop_reason(reason)
       when reason in [:cancelled, :expired, :reclaimed, :runner_stopped, :stale_lease],
       do: reason

  defp classify_stop_reason(_reason), do: :stopped

  defp classify_store_result({:ok, %Transition{outcome: outcome}}), do: outcome
  defp classify_store_result({:error, _reason}), do: :error
  defp classify_store_result(:not_settled), do: :not_settled
  defp classify_store_result(_other), do: :other

  defp classify_release_result(:ok), do: :ok
  defp classify_release_result({:error, _reason}), do: :error

  defp waiter_registered?(state, task_id, key) do
    state.waiters
    |> Map.get(task_id, %{})
    |> Map.has_key?(key)
  end

  defp drop_waiter(waiters, task_id, key) do
    case Map.fetch(waiters, task_id) do
      {:ok, task_waiters} ->
        remaining = Map.delete(task_waiters, key)

        if map_size(remaining) == 0,
          do: Map.delete(waiters, task_id),
          else: Map.put(waiters, task_id, remaining)

      :error ->
        waiters
    end
  end

  defp schedule_renewal(state, task_id, job_ref) do
    Process.send_after(self(), {:renew_claim, task_id, job_ref}, state.heartbeat_ms)
  end

  defp maybe_schedule_recovery(state, delay \\ nil)

  defp maybe_schedule_recovery(%{recover?: false} = state, _delay), do: state

  defp maybe_schedule_recovery(state, delay) do
    Process.send_after(self(), :recover, delay || state.recovery_interval_ms)
    state
  end

  defp maybe_schedule_reap(%{reap_interval_ms: nil} = state), do: state

  defp maybe_schedule_reap(state) do
    Process.send_after(self(), :reap, state.reap_interval_ms)
    state
  end

  defp maybe_schedule_retry(
         state,
         {:ok, %Transition{} = transition},
         release_result,
         lease
       ) do
    snapshot = transition.snapshot

    with false <- MCP.Extensions.Tasks.Task.terminal?(snapshot.task),
         %{
           disposition: :scheduled,
           retry_at: retry_at,
           delay_ms: delay_ms,
           retry_count: retry_count
         } <- Map.get(transition.effects, :retry),
         true <- snapshot.retry_at == retry_at,
         true <- snapshot.retry_count == retry_count do
      continue_local_retry(state, transition, delay_ms, release_result, lease)
    else
      _not_scheduled -> state
    end
  end

  defp maybe_schedule_retry(state, _store_result, _release_result, _lease), do: state

  defp continue_local_retry(state, transition, delay_ms, :ok, _lease) do
    delay = if transition.outcome == :duplicate, do: 0, else: delay_ms
    schedule_retry_due(state, transition.snapshot.task.id, delay)
  end

  defp continue_local_retry(state, transition, _delay_ms, {:error, :stale_lease}, _lease) do
    schedule_retry_due(state, transition.snapshot.task.id, 0)
  end

  defp continue_local_retry(state, transition, _delay_ms, {:error, _reason}, lease)
       when not is_nil(lease) do
    schedule_retry_release(state, transition.snapshot.task.id, lease)
  end

  defp continue_local_retry(state, _transition, _delay_ms, _release_result, _lease), do: state

  defp schedule_retry_due(state, task_id, remaining_ms) do
    schedule_retry_due(task_id, remaining_ms)
    state
  end

  defp schedule_retry_due(task_id, remaining_ms) do
    Process.send_after(self(), {:retry_due, task_id}, remaining_ms)
    :ok
  end

  defp schedule_retry_release(state, task_id, lease) do
    Process.send_after(self(), {:retry_release, task_id, lease}, @release_retry_interval_ms)
    state
  end

  defp validate_executor(nil), do: nil
  defp validate_executor(executor), do: WorkExecutor.validate_ref!(executor)

  defp positive_option!(opts, key, default) do
    case Keyword.get(opts, key, default) do
      value when is_integer(value) and value > 0 -> value
      _invalid -> raise ArgumentError, "#{inspect(key)} must be a positive integer"
    end
  end

  defp optional_positive_option!(opts, key) do
    case Keyword.get(opts, key) do
      nil -> nil
      value when is_integer(value) and value > 0 -> value
      _invalid -> raise ArgumentError, "#{inspect(key)} must be nil or a positive integer"
    end
  end

  defp generate_owner_id do
    18
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end
end
