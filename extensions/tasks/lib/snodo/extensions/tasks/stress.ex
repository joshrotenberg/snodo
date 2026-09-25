defmodule Snodo.Extensions.Tasks.Stress do
  @moduledoc """
  Deterministic correctness workloads for Tasks contention and runner soak.

  The harness exercises the in-memory store reference implementation. It
  reports exact lifecycle invariants separately from observed timings so the
  same workload can run in CI and on developer machines without flaky latency
  thresholds. Database adapters should apply the same report shape in their
  own environment-specific soak jobs.

  This is diagnostic evidence, not a production capacity claim.
  """

  alias Snodo.Context
  alias Snodo.Extensions.Tasks.Event
  alias Snodo.Extensions.Tasks.Runner
  alias Snodo.Extensions.Tasks.Snapshot
  alias Snodo.Extensions.Tasks.Store
  alias Snodo.Extensions.Tasks.Store.Memory
  alias Snodo.Extensions.Tasks.Task, as: ProtocolTask
  alias Snodo.Extensions.Tasks.Transition
  alias Snodo.Extensions.Tasks.Work
  alias Snodo.Protocol.V2026_07_28
  alias Snodo.Transport.Context, as: TransportContext

  @default_tasks 25
  @default_writers 8
  @default_rounds 3
  @default_timeout_ms 30_000
  @job_start [:snodo, :tasks, :runner, :job, :start]
  @job_stop [:snodo, :tasks, :runner, :job, :stop]
  @store_transition [:snodo, :tasks, :store, :transition]

  defmodule Sink do
    @moduledoc false

    @behaviour Snodo.Instrumentation

    @impl true
    def handle_event(event_name, measurements, metadata, collector) do
      Agent.update(collector, &[{event_name, measurements, metadata} | &1])
    end
  end

  @type report :: %{required(String.t()) => term()}

  @doc "Runs deterministic CAS-contention and runner-soak workloads."
  @spec run(keyword()) :: report()
  def run(opts \\ []) when is_list(opts) do
    config = validate_options!(opts)
    {:ok, collector} = Agent.start_link(fn -> [] end)
    {:ok, store} = Memory.start_link()
    store_ref = {Memory, store}

    try do
      {:ok, runner} =
        Runner.start_link(
          store: store_ref,
          owner_id: "stress-runner",
          lease_ms: max(config.timeout_ms * 2, 60_000),
          heartbeat_ms: max(config.timeout_ms, 1),
          instrumentation: {Sink, collector}
        )

      try do
        build_report(config, store_ref, store, runner, collector)
      after
        stop_process(runner)
      end
    after
      stop_process(store)
      stop_process(collector)
    end
  end

  defp build_report(config, store_ref, store, runner, collector) do
    context = context()
    cas = run_cas_contention(config, store_ref, store, context)
    runner_soak = run_runner_soak(config, store_ref, runner, collector, context)

    invariants = %{
      "casExactlyOneWinnerPerTask" =>
        cas.applied == config.tasks and
          cas.conflicts == config.tasks * (config.writers - 1) and cas.unexpected == 0,
      "casOneCommittedEventPerTask" =>
        cas.committed_events == config.tasks and cas.terminal_tasks == config.tasks,
      "runnerAllJobsTerminal" => runner_soak.completed == runner_soak.expected_jobs,
      "runnerEventsBalanced" =>
        runner_soak.started == runner_soak.expected_jobs and
          runner_soak.stopped == runner_soak.expected_jobs,
      "runnerDrained" => runner_soak.final_jobs == 0,
      "runnerTransitionsApplied" =>
        runner_soak.applied_transitions == runner_soak.expected_jobs and
          runner_soak.other_transitions == 0
    }

    %{
      "schemaVersion" => 1,
      "workload" => "snodo_tasks_memory",
      "config" => %{
        "tasks" => config.tasks,
        "writersPerTask" => config.writers,
        "rounds" => config.rounds,
        "timeoutMs" => config.timeout_ms
      },
      "scenarios" => %{
        "casContention" => stringify_keys(cas),
        "runnerSoak" => stringify_keys(runner_soak)
      },
      "invariants" => invariants,
      "ok" => Enum.all?(invariants, fn {_name, passed?} -> passed? end)
    }
  end

  defp run_cas_contention(config, store_ref, store, context) do
    started_at = System.monotonic_time()

    counts =
      Enum.reduce(1..config.tasks, initial_cas_counts(), fn task_number, totals ->
        task_id = "stress-cas-#{task_number}"
        {snapshot, lease, read_access} = create_and_claim!(store_ref, context, task_id)
        results = contend(store_ref, snapshot, lease, config.writers, config.timeout_ms)
        {:ok, history} = Memory.history(store, task_id, read_access)
        {:ok, final} = Store.get(store_ref, task_id, read_access)

        results
        |> Enum.reduce(totals, &count_cas_result/2)
        |> Map.update!(:committed_events, &(&1 + length(history)))
        |> Map.update!(:terminal_tasks, &(&1 + terminal_count(final)))
      end)

    counts
    |> Map.put(:attempts, config.tasks * config.writers)
    |> Map.put(:duration_us, elapsed_microseconds(started_at))
  end

  defp contend(store_ref, snapshot, lease, writers, timeout_ms) do
    gate = make_ref()
    owner = self()

    tasks =
      Enum.map(1..writers, fn writer ->
        event = completed_event!(snapshot.task.id, writer)

        Task.async(fn ->
          send(owner, {:stress_cas_ready, gate, self()})

          receive do
            {:stress_cas_go, ^gate} ->
              Store.transition(
                store_ref,
                snapshot.task.id,
                snapshot.revision,
                event,
                {:worker, lease}
              )
          end
        end)
      end)

    _ready = await_ready(:stress_cas_ready, gate, writers, timeout_ms)
    Enum.each(tasks, &send(&1.pid, {:stress_cas_go, gate}))
    Task.await_many(tasks, timeout_ms)
  end

  defp run_runner_soak(config, store_ref, runner, collector, context) do
    started_at = System.monotonic_time()

    completed =
      Enum.reduce(1..config.rounds, 0, fn round, completed_so_far ->
        batch = create_runner_batch!(config, store_ref, context, round)
        gate = make_ref()
        start_runner_batch!(runner, batch, gate)
        workers = await_ready(:stress_runner_ready, gate, config.tasks, config.timeout_ms)
        Enum.each(workers, fn {_task_id, worker} -> send(worker, {:stress_runner_go, gate}) end)
        completed = await_completed!(store_ref, batch, config.timeout_ms)
        expected_stops = round * config.tasks

        wait_until!(
          fn -> count_events(collector, @job_stop) == expected_stops end,
          config.timeout_ms,
          "runner stop instrumentation"
        )

        completed_so_far + completed
      end)

    events = Agent.get(collector, &Enum.reverse/1)
    starts = select_events(events, @job_start)
    stops = select_events(events, @job_stop)
    transitions = select_events(events, @store_transition)
    expected_jobs = config.tasks * config.rounds

    %{
      expected_jobs: expected_jobs,
      started: length(starts),
      stopped: length(stops),
      completed: completed,
      peak_jobs: maximum_measurement(starts, :jobs),
      final_jobs: last_measurement(stops, :jobs),
      applied_transitions: count_metadata(transitions, :outcome, :applied),
      other_transitions:
        Enum.count(transitions, fn {_name, _measurements, metadata} ->
          metadata.outcome != :applied
        end),
      observed_job_duration_us: sum_native_durations(stops),
      duration_us: elapsed_microseconds(started_at)
    }
  end

  defp create_runner_batch!(config, store_ref, context, round) do
    Enum.map(1..config.tasks, fn task_number ->
      task_id = "stress-runner-#{round}-#{task_number}"
      create_task!(store_ref, context, task_id)
    end)
  end

  defp start_runner_batch!(runner, batch, gate) do
    owner = self()

    Enum.each(batch, fn {%Snapshot{} = snapshot, _read_access} ->
      task_id = snapshot.task.id

      work = fn _cancellation ->
        send(owner, {:stress_runner_ready, gate, task_id, self()})

        receive do
          {:stress_runner_go, ^gate} -> {:completed, tool_result(task_id, 1)}
        end
      end

      case Runner.start_task(runner, snapshot, work) do
        :ok -> :ok
        {:error, reason} -> raise "runner rejected stress task: #{inspect(reason)}"
      end
    end)
  end

  defp await_completed!(store_ref, batch, timeout_ms) do
    wait_until!(
      fn -> Enum.all?(batch, &completed?(store_ref, &1)) end,
      timeout_ms,
      "runner tasks to complete"
    )

    Enum.count(batch, &completed?(store_ref, &1))
  end

  defp completed?(store_ref, {%Snapshot{task: %{id: task_id}}, read_access}) do
    match?(
      {:ok, %Snapshot{task: %{status: :completed}}},
      Store.get(store_ref, task_id, read_access)
    )
  end

  defp create_and_claim!(store_ref, context, task_id) do
    {_snapshot, read_access} = create_task!(store_ref, context, task_id)

    case Store.claim(store_ref, task_id, "stress-cas", 60_000) do
      {:ok, %Snapshot{} = claimed, lease} -> {claimed, lease, read_access}
      other -> raise "could not claim stress task: #{inspect(other)}"
    end
  end

  defp create_task!(store_ref, context, task_id) do
    create_access = authorize!(store_ref, context, {:create, task_id})
    read_access = authorize!(store_ref, context, {:get, task_id})
    task = ProtocolTask.new!(id: task_id, created_at: ProtocolTask.timestamp(), ttl_ms: nil)
    work = Work.new!(task_id, "stress", %{"taskId" => task_id})

    case Store.create(store_ref, task, work, create_access) do
      {:ok, %Snapshot{} = snapshot} -> {snapshot, read_access}
      {:error, reason} -> raise "could not create stress task: #{inspect(reason)}"
    end
  end

  defp authorize!(store_ref, context, action) do
    case Store.authorize(store_ref, context, action) do
      {:ok, access} -> access
      {:error, reason} -> raise "could not authorize stress task: #{inspect(reason)}"
    end
  end

  defp completed_event!(task_id, writer) do
    case Event.completed(tool_result(task_id, writer), id: "#{task_id}-writer-#{writer}") do
      {:ok, event} -> event
      {:error, reason} -> raise "could not build stress event: #{inspect(reason)}"
    end
  end

  defp tool_result(task_id, writer) do
    %{
      "content" => [%{"type" => "text", "text" => "stress complete"}],
      "isError" => false,
      "structuredContent" => %{"taskId" => task_id, "writer" => writer}
    }
  end

  defp await_ready(kind, gate, count, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_await_ready(kind, gate, count, deadline, [])
  end

  defp do_await_ready(_kind, _gate, 0, _deadline, ready), do: ready

  defp do_await_ready(kind, gate, remaining, deadline, ready) do
    timeout = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^kind, ^gate, worker} ->
        do_await_ready(kind, gate, remaining - 1, deadline, [worker | ready])

      {^kind, ^gate, task_id, worker} ->
        do_await_ready(kind, gate, remaining - 1, deadline, [{task_id, worker} | ready])
    after
      timeout -> raise "timed out waiting for #{kind} workers"
    end
  end

  defp wait_until!(check, timeout_ms, description) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_until!(check, deadline, description)
  end

  defp do_wait_until!(check, deadline, description) do
    if check.() do
      :ok
    else
      if System.monotonic_time(:millisecond) >= deadline do
        raise "timed out waiting for #{description}"
      else
        Process.sleep(1)
        do_wait_until!(check, deadline, description)
      end
    end
  end

  defp initial_cas_counts do
    %{applied: 0, conflicts: 0, unexpected: 0, committed_events: 0, terminal_tasks: 0}
  end

  defp count_cas_result({:ok, %Transition{outcome: :applied}}, counts),
    do: Map.update!(counts, :applied, &(&1 + 1))

  defp count_cas_result({:conflict, %Snapshot{}}, counts),
    do: Map.update!(counts, :conflicts, &(&1 + 1))

  defp count_cas_result(_unexpected, counts),
    do: Map.update!(counts, :unexpected, &(&1 + 1))

  defp terminal_count(%Snapshot{task: task}), do: if(ProtocolTask.terminal?(task), do: 1, else: 0)

  defp select_events(events, name), do: Enum.filter(events, &(elem(&1, 0) == name))

  defp count_events(collector, name) do
    Agent.get(
      collector,
      &Enum.count(&1, fn {event, _measurements, _metadata} -> event == name end)
    )
  end

  defp count_metadata(events, key, value) do
    Enum.count(events, fn {_name, _measurements, metadata} -> Map.get(metadata, key) == value end)
  end

  defp maximum_measurement([], _key), do: 0

  defp maximum_measurement(events, key) do
    events
    |> Enum.map(fn {_name, measurements, _metadata} -> Map.fetch!(measurements, key) end)
    |> Enum.max()
  end

  defp last_measurement([], _key), do: 0

  defp last_measurement(events, key) do
    {_name, measurements, _metadata} = List.last(events)
    Map.fetch!(measurements, key)
  end

  defp sum_native_durations(events) do
    events
    |> Enum.reduce(0, fn {_name, measurements, _metadata}, total ->
      total + Map.fetch!(measurements, :duration)
    end)
    |> System.convert_time_unit(:native, :microsecond)
  end

  defp elapsed_microseconds(started_at) do
    System.monotonic_time()
    |> Kernel.-(started_at)
    |> System.convert_time_unit(:native, :microsecond)
  end

  defp context do
    %Context{
      protocol_version: V2026_07_28.version(),
      protocol: V2026_07_28,
      server_info: %{},
      transport: %TransportContext{transport: :direct}
    }
  end

  defp validate_options!(opts) do
    allowed = [:tasks, :writers, :rounds, :timeout_ms]

    unless Keyword.keyword?(opts) and Keyword.keys(opts) -- allowed == [] do
      raise ArgumentError, "stress options must use only #{inspect(allowed)}"
    end

    config = %{
      tasks: Keyword.get(opts, :tasks, @default_tasks),
      writers: Keyword.get(opts, :writers, @default_writers),
      rounds: Keyword.get(opts, :rounds, @default_rounds),
      timeout_ms: Keyword.get(opts, :timeout_ms, @default_timeout_ms)
    }

    Enum.each(config, fn {name, value} ->
      unless is_integer(value) and value > 0 do
        raise ArgumentError, ":#{name} must be a positive integer"
      end
    end)

    config
  end

  defp stringify_keys(map) do
    Map.new(map, fn {key, value} -> {key |> Atom.to_string() |> camelize(), value} end)
  end

  defp camelize(key) do
    [first | rest] = String.split(key, "_")
    first <> Enum.map_join(rest, &String.capitalize/1)
  end

  defp stop_process(process) do
    if Process.alive?(process), do: GenServer.stop(process, :normal, 5_000)
  catch
    :exit, _reason -> :ok
  end
end
