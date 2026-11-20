defmodule Snodo.Server.Executor do
  @moduledoc """
  Optional, transport-neutral execution policy around the synchronous server core.

  The executor knows nothing about JSON-RPC, protocol dialects, sessions, or
  transports. Callers submit a function that receives a cooperative
  `Snodo.Cancellation` token. The executor bounds concurrent work, optionally
  queues admitted work, enforces execution deadlines, and reports terminal
  outcomes back to the submitting process while both it and the executor remain
  alive. Work is cancelled without delivery when its reply owner terminates.

  Work that outlives its execution, such as an open subscription stream, can
  hold a counted slot with `acquire_slot/4`. The executor releases the slot when
  its owner exits.

  Direct callers can continue to invoke `Snodo.Server.dispatch/3` without
  starting this or any other process.
  """

  use GenServer

  alias Snodo.Cancellation

  @event_tag :mcp_execution

  @type server :: GenServer.server()
  @type execution_ref :: reference()
  @type execution_key :: term()
  @type execution_timeout :: non_neg_integer() | :infinity
  @type outcome ::
          {:completed, term()}
          | {:cancelled, term()}
          | {:timed_out, non_neg_integer()}
          | :queue_timed_out
          | {:failed, term()}
  @type event ::
          {:mcp_execution, pid(), execution_ref(), execution_key(), outcome()}

  @default_max_concurrency 32
  @default_max_queue 256
  @default_timeout 30_000

  @doc """
  Starts an executor linked to the calling process.

  Options:

    * `:name` - a name to register the executor under.
    * `:max_concurrency` - the most work that runs at once. A positive
      integer, default 32.
    * `:max_queue` - the most admitted work that waits for a free slot. A
      non-negative integer, default 256. When both limits are reached,
      `submit/4` returns `{:error, :overloaded}`.
    * `:default_timeout` - the total time in milliseconds from admission
      through execution for work submitted without `:timeout`. A non-negative
      integer or `:infinity`, default 30,000.
    * `:max_queue_wait` - an additional queue wait cap in milliseconds. A
      non-negative integer or `:infinity`, default `:infinity`. The effective
      queue limit is the smaller of this cap and the resolved submit timeout.
      A job that reaches its queue deadline reports `:queue_timed_out`.

  An invalid option raises `ArgumentError` in the executor process, and the
  start fails.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) when is_list(opts) do
    GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))
  end

  @doc """
  Submits one unit of work.

  `key` must be unique across running and queued executions. The supplied
  function runs in a supervised task and receives a cancellation token. On
  completion, the executor sends an `t:event/0` message to `:reply_to`, which
  defaults to the submitting process. Reply-owner termination or executor
  shutdown ends that delivery guarantee and tears down the work instead.
  The `:timeout` option overrides the executor's `:default_timeout` and includes
  time spent in the queue. A running job has only the remaining time to finish.
  """
  @spec submit(server(), execution_key(), (Cancellation.t() -> term()), keyword()) ::
          {:ok, execution_ref()} | {:error, :duplicate_key | :overloaded}
  def submit(server, key, work, opts \\ []) when is_function(work, 1) and is_list(opts) do
    reply_to = Keyword.get(opts, :reply_to, self())
    timeout = Keyword.get(opts, :timeout, :default)

    unless is_pid(reply_to) do
      raise ArgumentError, ":reply_to must be a pid"
    end

    unless timeout == :default or valid_timeout?(timeout) do
      raise ArgumentError, ":timeout must be a non-negative integer, :infinity, or :default"
    end

    GenServer.call(server, {:submit, key, work, reply_to, timeout})
  end

  @doc "Cancels queued or running work identified by its caller-supplied key."
  @spec cancel(server(), execution_key(), term()) :: :ok | {:error, :not_found}
  def cancel(server, key, reason \\ nil) do
    GenServer.call(server, {:cancel, key, reason})
  end

  @doc """
  Takes one of `limit` slots in `pool` for `owner`, which defaults to the caller.

  A pool is any term; each pool is counted separately. Slots are independent of
  `:max_concurrency` and `:max_queue`. The executor monitors `owner` and returns
  the slot to the pool when `owner` exits, for any reason. Returns
  `{:error, :exhausted}` when `pool` already has `limit` slots taken.
  """
  @spec acquire_slot(server(), term(), pos_integer(), pid()) :: :ok | {:error, :exhausted}
  def acquire_slot(server, pool, limit, owner \\ self()) do
    case acquire_slot_with_executor(server, pool, limit, owner) do
      {:ok, _executor} -> :ok
      {:error, :exhausted} = error -> error
    end
  end

  @doc false
  @spec acquire_slot_with_executor(server(), term(), pos_integer(), pid()) ::
          {:ok, pid()} | {:error, :exhausted}
  def acquire_slot_with_executor(server, pool, limit, owner \\ self()) do
    unless is_integer(limit) and limit > 0 do
      raise ArgumentError, "slot limit must be a positive integer"
    end

    unless is_pid(owner) do
      raise ArgumentError, "slot owner must be a pid"
    end

    GenServer.call(server, {:acquire_slot, pool, limit, owner})
  end

  @doc "Returns the current bounded-execution counters and limits."
  @spec stats(server()) :: %{
          running: non_neg_integer(),
          queued: non_neg_integer(),
          max_concurrency: pos_integer(),
          max_queue: non_neg_integer()
        }
  def stats(server), do: GenServer.call(server, :stats)

  @impl true
  def init(opts) do
    max_concurrency = Keyword.get(opts, :max_concurrency, @default_max_concurrency)
    max_queue = Keyword.get(opts, :max_queue, @default_max_queue)
    default_timeout = Keyword.get(opts, :default_timeout, @default_timeout)
    max_queue_wait = Keyword.get(opts, :max_queue_wait, :infinity)

    validate_options!(max_concurrency, max_queue, default_timeout, max_queue_wait)
    {:ok, task_supervisor} = Task.Supervisor.start_link()

    {:ok,
     %{
       task_supervisor: task_supervisor,
       max_concurrency: max_concurrency,
       max_queue: max_queue,
       default_timeout: default_timeout,
       max_queue_wait: max_queue_wait,
       queue_deadlines: :gb_sets.empty(),
       queue_timer: nil,
       running: 0,
       queued: 0,
       queue: :queue.new(),
       jobs: %{},
       jobs_by_key: %{},
       jobs_by_task_ref: %{},
       jobs_by_owner_monitor: %{},
       slots: %{},
       slot_counts: %{}
     }}
  end

  @impl true
  def handle_call({:submit, key, work, reply_to, requested_timeout}, _from, state) do
    state = state |> expire_queued_jobs() |> schedule_queue_timer()

    cond do
      Map.has_key?(state.jobs_by_key, key) ->
        {:reply, {:error, :duplicate_key}, state}

      state.running >= state.max_concurrency and state.queued >= state.max_queue ->
        {:reply, {:error, :overloaded}, state}

      true ->
        execution_ref = make_ref()
        owner_monitor = Process.monitor(reply_to)

        now = System.monotonic_time(:millisecond)
        timeout = resolve_timeout(requested_timeout, state.default_timeout)

        job = %{
          ref: execution_ref,
          key: key,
          work: work,
          reply_to: reply_to,
          owner_monitor: owner_monitor,
          token: Cancellation.new(),
          timeout: timeout,
          deadline: deadline(now, timeout),
          queue_deadline: deadline(now, min(timeout, state.max_queue_wait)),
          status: :admitted,
          pending_outcome: nil,
          terminal_delivery?: true,
          pid: nil,
          task_ref: nil,
          timer: nil
        }

        state = put_job(state, job)

        state =
          if state.running < state.max_concurrency do
            start_admitted_job(state, job)
          else
            state |> enqueue_job(job) |> expire_queued_jobs() |> schedule_queue_timer()
          end

        {:reply, {:ok, execution_ref}, state}
    end
  end

  def handle_call({:cancel, key, reason}, _from, state) do
    case Map.fetch(state.jobs_by_key, key) do
      {:ok, execution_ref} ->
        {:reply, :ok, cancel_job(state, execution_ref, reason)}

      :error ->
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:acquire_slot, pool, limit, owner}, _from, state) do
    taken = Map.get(state.slot_counts, pool, 0)

    if taken >= limit do
      {:reply, {:error, :exhausted}, state}
    else
      monitor = Process.monitor(owner)

      state = %{
        state
        | slots: Map.put(state.slots, monitor, pool),
          slot_counts: Map.put(state.slot_counts, pool, taken + 1)
      }

      {:reply, {:ok, self()}, state}
    end
  end

  def handle_call(:stats, _from, state) do
    stats = %{
      running: state.running,
      queued: state.queued,
      max_concurrency: state.max_concurrency,
      max_queue: state.max_queue
    }

    {:reply, stats, state}
  end

  @impl true
  def handle_info({task_ref, result}, state) when is_reference(task_ref) do
    case Map.fetch(state.jobs_by_task_ref, task_ref) do
      {:ok, execution_ref} ->
        case Map.fetch(state.jobs, execution_ref) do
          {:ok, %{status: :running}} ->
            Process.demonitor(task_ref, [:flush])
            {:noreply, finish_running_job(state, execution_ref, {:completed, result})}

          {:ok, %{status: :stopping}} ->
            {:noreply, state}

          :error ->
            {:noreply, state}
        end

      :error ->
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, monitor, :process, owner, reason}, state) do
    case Map.fetch(state.jobs_by_task_ref, monitor) do
      {:ok, execution_ref} ->
        job = Map.fetch!(state.jobs, execution_ref)

        case job.status do
          :running ->
            {:noreply,
             finish_running_job(
               state,
               execution_ref,
               {:failed, reason},
               demonitor?: false
             )}

          :stopping ->
            {:noreply,
             finish_running_job(
               state,
               execution_ref,
               job.pending_outcome,
               demonitor?: false,
               deliver?: job.terminal_delivery?
             )}
        end

      :error ->
        cond do
          Map.has_key?(state.jobs_by_owner_monitor, monitor) ->
            {:noreply, abandon_owner(state, owner, reason)}

          Map.has_key?(state.slots, monitor) ->
            {:noreply, release_slot(state, monitor)}

          true ->
            {:noreply, state}
        end
    end
  end

  def handle_info({:execution_timeout, execution_ref}, state) do
    case Map.fetch(state.jobs, execution_ref) do
      {:ok, %{status: :running} = job} ->
        Cancellation.cancel(job.token)
        {:noreply, stop_running_job(state, job, {:timed_out, job.timeout})}

      _not_running ->
        {:noreply, state}
    end
  end

  def handle_info({:timeout, timer, :queue_deadline}, %{queue_timer: {_, timer}} = state) do
    {:noreply,
     state |> Map.put(:queue_timer, nil) |> expire_queued_jobs() |> schedule_queue_timer()}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if Process.alive?(state.task_supervisor) do
      Supervisor.stop(state.task_supervisor, :normal)
    end

    :ok
  end

  defp put_job(state, job) do
    %{
      state
      | jobs: Map.put(state.jobs, job.ref, job),
        jobs_by_key: Map.put(state.jobs_by_key, job.key, job.ref),
        jobs_by_owner_monitor: Map.put(state.jobs_by_owner_monitor, job.owner_monitor, job.ref)
    }
  end

  defp start_admitted_job(state, job) do
    if expired?(job.deadline) do
      state |> forget_unstarted_job(job) |> deliver(job, {:timed_out, job.timeout})
    else
      start_job(state, job)
    end
  end

  defp start_job(state, job) do
    task =
      Task.Supervisor.async_nolink(state.task_supervisor, fn ->
        job.work.(job.token)
      end)

    timer = start_timeout(job.ref, job.deadline)

    running_job = %{
      job
      | status: :running,
        pid: task.pid,
        task_ref: task.ref,
        timer: timer
    }

    %{
      state
      | jobs: Map.put(state.jobs, job.ref, running_job),
        jobs_by_task_ref: Map.put(state.jobs_by_task_ref, task.ref, job.ref),
        running: state.running + 1
    }
  end

  defp enqueue_job(state, job) do
    queued_job = %{job | status: :queued}

    %{
      state
      | jobs: Map.put(state.jobs, job.ref, queued_job),
        queue: :queue.in(job.ref, state.queue),
        queue_deadlines: put_queue_deadline(state.queue_deadlines, job),
        queued: state.queued + 1
    }
  end

  defp cancel_job(state, execution_ref, reason) do
    job = Map.fetch!(state.jobs, execution_ref)
    Cancellation.cancel(job.token)

    case job.status do
      :running ->
        stop_running_job(state, job, {:cancelled, reason})

      :queued ->
        state
        |> remove_queued_job(job)
        |> deliver(job, {:cancelled, reason})
        |> fill_capacity()
    end
  end

  defp finish_running_job(state, execution_ref, outcome, opts \\ []) do
    job = Map.fetch!(state.jobs, execution_ref)

    if Keyword.get(opts, :demonitor?, true) and is_reference(job.task_ref) do
      Process.demonitor(job.task_ref, [:flush])
    end

    cancel_timeout(job.timer)

    state = remove_running_job(state, job)

    state =
      if Keyword.get(opts, :deliver?, true),
        do: deliver(state, job, outcome),
        else: state

    fill_capacity(state)
  end

  defp remove_running_job(state, job) do
    Process.demonitor(job.owner_monitor, [:flush])

    %{
      state
      | jobs: Map.delete(state.jobs, job.ref),
        jobs_by_key: delete_key_if_matches(state.jobs_by_key, job.key, job.ref),
        jobs_by_task_ref: Map.delete(state.jobs_by_task_ref, job.task_ref),
        jobs_by_owner_monitor: Map.delete(state.jobs_by_owner_monitor, job.owner_monitor),
        running: state.running - 1
    }
  end

  defp remove_queued_job(state, job) do
    state = forget_unstarted_job(state, job)

    %{
      state
      | queue: delete_queue_reference(state.queue, job.ref),
        queue_deadlines: drop_queue_deadline(state.queue_deadlines, job),
        queued: state.queued - 1
    }
  end

  defp delete_queue_reference(queue, execution_ref) do
    :queue.filter(&(&1 != execution_ref), queue)
  end

  defp delete_key_if_matches(jobs_by_key, key, execution_ref) do
    case jobs_by_key do
      %{^key => ^execution_ref} -> Map.delete(jobs_by_key, key)
      _different_or_absent -> jobs_by_key
    end
  end

  defp abandon_owner(state, owner, reason) do
    execution_refs =
      for {execution_ref, %{reply_to: ^owner}} <- state.jobs do
        execution_ref
      end

    execution_refs
    |> Enum.reduce(state, &abandon_job(&2, &1, reason))
    |> fill_capacity()
  end

  defp abandon_job(state, execution_ref, reason) do
    case Map.fetch(state.jobs, execution_ref) do
      {:ok, job} ->
        Cancellation.cancel(job.token)

        case job.status do
          :running ->
            stop_running_job(
              state,
              job,
              {:cancelled, {:reply_owner_down, reason}},
              deliver?: false
            )

          :stopping ->
            stopping_job = %{job | terminal_delivery?: false}
            %{state | jobs: Map.put(state.jobs, job.ref, stopping_job)}

          :queued ->
            remove_queued_job(state, job)
        end

      :error ->
        state
    end
  end

  defp release_slot(state, monitor) do
    {pool, slots} = Map.pop!(state.slots, monitor)

    slot_counts =
      case Map.fetch!(state.slot_counts, pool) do
        1 -> Map.delete(state.slot_counts, pool)
        taken -> Map.put(state.slot_counts, pool, taken - 1)
      end

    %{state | slots: slots, slot_counts: slot_counts}
  end

  defp fill_capacity(state) do
    state |> start_queued_jobs() |> schedule_queue_timer()
  end

  defp start_queued_jobs(%{running: running, max_concurrency: max} = state)
       when running >= max,
       do: state

  defp start_queued_jobs(state) do
    case :queue.peek(state.queue) do
      {:value, execution_ref} ->
        state |> start_queue_head(execution_ref) |> start_queued_jobs()

      :empty ->
        state
    end
  end

  defp start_queue_head(state, execution_ref) do
    case Map.fetch(state.jobs, execution_ref) do
      {:ok, %{status: :queued} = job} ->
        state = dequeue_job(state, job)

        if expired?(min(job.queue_deadline, job.deadline)) do
          expire_queued_job(state, job)
        else
          start_job(state, job)
        end

      _stale ->
        state
        |> drop_queue_head()
        |> Map.update!(
          :queue_deadlines,
          &:gb_sets.filter(fn {_, ref} -> ref != execution_ref end, &1)
        )
    end
  end

  defp dequeue_job(state, job) do
    state
    |> drop_queue_head()
    |> Map.update!(:queue_deadlines, &drop_queue_deadline(&1, job))
  end

  defp drop_queue_head(state) do
    %{state | queue: :queue.drop(state.queue), queued: state.queued - 1}
  end

  defp expire_queued_job(state, job) do
    state |> forget_unstarted_job(job) |> deliver(job, :queue_timed_out)
  end

  defp forget_unstarted_job(state, job) do
    Process.demonitor(job.owner_monitor, [:flush])

    %{
      state
      | jobs: Map.delete(state.jobs, job.ref),
        jobs_by_key: delete_key_if_matches(state.jobs_by_key, job.key, job.ref),
        jobs_by_owner_monitor: Map.delete(state.jobs_by_owner_monitor, job.owner_monitor)
    }
  end

  defp expire_queued_jobs(state) do
    case collect_expired_jobs(state, []) do
      {state, []} ->
        state

      {state, expired} ->
        expired = Map.new(expired, &{&1, true})
        queue = :queue.filter(fn ref -> not Map.has_key?(expired, ref) end, state.queue)
        %{state | queue: queue, queued: state.queued - map_size(expired)}
    end
  end

  defp collect_expired_jobs(state, expired) do
    case earliest_queue_deadline(state) do
      {deadline, execution_ref} ->
        if expired?(deadline) do
          deadlines = :gb_sets.delete({deadline, execution_ref}, state.queue_deadlines)
          state = %{state | queue_deadlines: deadlines}

          state = expire_job_by_ref(state, execution_ref)
          collect_expired_jobs(state, [execution_ref | expired])
        else
          {state, expired}
        end

      nil ->
        {state, expired}
    end
  end

  defp expire_job_by_ref(state, ref) do
    case Map.fetch(state.jobs, ref) do
      {:ok, %{status: :queued} = job} -> expire_queued_job(state, job)
      _stale -> state
    end
  end

  # FIFO order controls execution. A later submission can have an earlier
  # deadline, so the timer follows the deadline index independently.
  defp earliest_queue_deadline(state) do
    unless :gb_sets.is_empty(state.queue_deadlines), do: :gb_sets.smallest(state.queue_deadlines)
  end

  defp put_queue_deadline(deadlines, %{queue_deadline: :infinity}), do: deadlines

  defp put_queue_deadline(deadlines, job),
    do: :gb_sets.add({job.queue_deadline, job.ref}, deadlines)

  defp drop_queue_deadline(deadlines, %{queue_deadline: :infinity}), do: deadlines

  defp drop_queue_deadline(deadlines, job),
    do: :gb_sets.delete_any({job.queue_deadline, job.ref}, deadlines)

  defp schedule_queue_timer(state) do
    next = earliest_queue_deadline(state)

    case {state.queue_timer, next} do
      {{deadline, _timer}, {deadline, _ref}} ->
        state

      {nil, nil} ->
        state

      {old_timer, next} ->
        if old_timer, do: cancel_timeout(elem(old_timer, 1))
        %{state | queue_timer: start_queue_timer(next)}
    end
  end

  defp start_queue_timer(nil), do: nil

  defp start_queue_timer({deadline, _ref}),
    do: {deadline, :erlang.start_timer(deadline, self(), :queue_deadline, abs: true)}

  defp deadline(_now, :infinity), do: :infinity
  defp deadline(now, timeout), do: now + timeout

  defp expired?(:infinity), do: false
  defp expired?(deadline), do: System.monotonic_time(:millisecond) >= deadline

  defp deliver(state, job, outcome) do
    send(job.reply_to, {@event_tag, self(), job.ref, job.key, outcome})
    state
  end

  defp stop_running_job(state, job, outcome, opts \\ []) do
    kill_task(job)
    cancel_timeout(job.timer)

    stopping_job = %{
      job
      | status: :stopping,
        pending_outcome: outcome,
        terminal_delivery?: Keyword.get(opts, :deliver?, true),
        timer: nil
    }

    %{
      state
      | jobs: Map.put(state.jobs, job.ref, stopping_job),
        jobs_by_key: delete_key_if_matches(state.jobs_by_key, job.key, job.ref)
    }
  end

  defp kill_task(job) do
    if is_pid(job.pid) and Process.alive?(job.pid), do: Process.exit(job.pid, :kill)
    :ok
  end

  defp start_timeout(_execution_ref, :infinity), do: nil

  defp start_timeout(execution_ref, deadline) do
    Process.send_after(self(), {:execution_timeout, execution_ref}, deadline, abs: true)
  end

  defp cancel_timeout(nil), do: :ok

  defp cancel_timeout(timer) do
    _cancelled_or_expired = Process.cancel_timer(timer, async: true, info: false)
    :ok
  end

  defp resolve_timeout(:default, default), do: default
  defp resolve_timeout(timeout, _default), do: timeout

  defp validate_options!(max_concurrency, max_queue, default_timeout, max_queue_wait) do
    unless is_integer(max_concurrency) and max_concurrency > 0 do
      raise ArgumentError, ":max_concurrency must be a positive integer"
    end

    unless is_integer(max_queue) and max_queue >= 0 do
      raise ArgumentError, ":max_queue must be a non-negative integer"
    end

    unless valid_timeout?(max_queue_wait) do
      raise ArgumentError, ":max_queue_wait must be a non-negative integer or :infinity"
    end

    unless valid_timeout?(default_timeout) do
      raise ArgumentError, ":default_timeout must be a non-negative integer or :infinity"
    end
  end

  defp valid_timeout?(:infinity), do: true
  defp valid_timeout?(timeout), do: is_integer(timeout) and timeout >= 0
end
