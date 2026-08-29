defmodule MCP.Server.Executor do
  @moduledoc """
  Optional, transport-neutral execution policy around the synchronous server core.

  The executor knows nothing about JSON-RPC, protocol dialects, sessions, or
  transports. Callers submit a function that receives a cooperative
  `MCP.Cancellation` token. The executor bounds concurrent work, optionally
  queues admitted work, enforces execution deadlines, and reports terminal
  outcomes back to the submitting process while both it and the executor remain
  alive. Work is cancelled without delivery when its reply owner terminates.

  Direct callers can continue to invoke `MCP.Server.dispatch/3` without
  starting this or any other process.
  """

  use GenServer

  alias MCP.Cancellation

  @event_tag :mcp_execution

  @type server :: GenServer.server()
  @type execution_ref :: reference()
  @type execution_key :: term()
  @type execution_timeout :: non_neg_integer() | :infinity
  @type outcome ::
          {:completed, term()}
          | {:cancelled, term()}
          | {:timed_out, non_neg_integer()}
          | {:failed, term()}
  @type event ::
          {:mcp_execution, pid(), execution_ref(), execution_key(), outcome()}

  @default_max_concurrency 32
  @default_max_queue 256
  @default_timeout 30_000

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

    validate_options!(max_concurrency, max_queue, default_timeout)
    {:ok, task_supervisor} = Task.Supervisor.start_link()

    {:ok,
     %{
       task_supervisor: task_supervisor,
       max_concurrency: max_concurrency,
       max_queue: max_queue,
       default_timeout: default_timeout,
       running: 0,
       queued: 0,
       queue: :queue.new(),
       jobs: %{},
       jobs_by_key: %{},
       jobs_by_task_ref: %{},
       jobs_by_owner_monitor: %{}
     }}
  end

  @impl true
  def handle_call({:submit, key, work, reply_to, requested_timeout}, _from, state) do
    cond do
      Map.has_key?(state.jobs_by_key, key) ->
        {:reply, {:error, :duplicate_key}, state}

      state.running >= state.max_concurrency and state.queued >= state.max_queue ->
        {:reply, {:error, :overloaded}, state}

      true ->
        execution_ref = make_ref()
        owner_monitor = Process.monitor(reply_to)

        job = %{
          ref: execution_ref,
          key: key,
          work: work,
          reply_to: reply_to,
          owner_monitor: owner_monitor,
          token: Cancellation.new(),
          timeout: resolve_timeout(requested_timeout, state.default_timeout),
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
            start_job(state, job)
          else
            enqueue_job(state, job)
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
        if Map.has_key?(state.jobs_by_owner_monitor, monitor) do
          {:noreply, abandon_owner(state, owner, reason)}
        else
          {:noreply, state}
        end
    end
  end

  def handle_info({:execution_timeout, execution_ref}, state) do
    case Map.fetch(state.jobs, execution_ref) do
      {:ok, %{status: :running} = job} ->
        Cancellation.cancel(job.token, "execution timeout")
        {:noreply, stop_running_job(state, job, {:timed_out, job.timeout})}

      _not_running ->
        {:noreply, state}
    end
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

  defp start_job(state, job) do
    task =
      Task.Supervisor.async_nolink(state.task_supervisor, fn ->
        job.work.(job.token)
      end)

    timer = start_timeout(job.ref, job.timeout)

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
        queued: state.queued + 1
    }
  end

  defp cancel_job(state, execution_ref, reason) do
    job = Map.fetch!(state.jobs, execution_ref)
    Cancellation.cancel(job.token, reason)

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
    Process.demonitor(job.owner_monitor, [:flush])

    %{
      state
      | jobs: Map.delete(state.jobs, job.ref),
        jobs_by_key: delete_key_if_matches(state.jobs_by_key, job.key, job.ref),
        jobs_by_owner_monitor: Map.delete(state.jobs_by_owner_monitor, job.owner_monitor),
        queue: delete_queue_reference(state.queue, job.ref),
        queued: state.queued - 1
    }
  end

  defp delete_queue_reference(queue, execution_ref) do
    queue
    |> :queue.to_list()
    |> Enum.reject(&(&1 == execution_ref))
    |> :queue.from_list()
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
        Cancellation.cancel(job.token, {:reply_owner_down, reason})

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

  defp fill_capacity(%{running: running, max_concurrency: max} = state)
       when running >= max,
       do: state

  defp fill_capacity(state) do
    case take_queued_job(state) do
      {:ok, job, state} ->
        state
        |> start_job(job)
        |> fill_capacity()

      :empty ->
        state
    end
  end

  defp take_queued_job(state) do
    case :queue.out(state.queue) do
      {{:value, execution_ref}, queue} ->
        state = %{state | queue: queue}

        case Map.fetch(state.jobs, execution_ref) do
          {:ok, %{status: :queued} = job} ->
            {:ok, job, %{state | queued: state.queued - 1}}

          _cancelled_tombstone ->
            take_queued_job(state)
        end

      {:empty, _queue} ->
        :empty
    end
  end

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

  defp start_timeout(execution_ref, timeout) do
    Process.send_after(self(), {:execution_timeout, execution_ref}, timeout)
  end

  defp cancel_timeout(nil), do: :ok

  defp cancel_timeout(timer) do
    _cancelled_or_expired = Process.cancel_timer(timer, async: true, info: false)
    :ok
  end

  defp resolve_timeout(:default, default), do: default
  defp resolve_timeout(timeout, _default), do: timeout

  defp validate_options!(max_concurrency, max_queue, default_timeout) do
    unless is_integer(max_concurrency) and max_concurrency > 0 do
      raise ArgumentError, ":max_concurrency must be a positive integer"
    end

    unless is_integer(max_queue) and max_queue >= 0 do
      raise ArgumentError, ":max_queue must be a non-negative integer"
    end

    unless valid_timeout?(default_timeout) do
      raise ArgumentError, ":default_timeout must be a non-negative integer or :infinity"
    end
  end

  defp valid_timeout?(:infinity), do: true
  defp valid_timeout?(timeout), do: is_integer(timeout) and timeout >= 0
end
