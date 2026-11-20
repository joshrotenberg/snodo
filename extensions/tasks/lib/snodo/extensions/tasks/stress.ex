defmodule Snodo.Extensions.Tasks.Stress do
  @moduledoc """
  Deterministic correctness workloads for Tasks contention and runner soak.

  The harness runs against any `Snodo.Extensions.Tasks.Store`. Without a
  `:store` option it starts a private `Store.Memory` process. Callers that
  own a database pass a store reference they have already configured, so this
  module never depends on a particular database. In this repository the
  PostgreSQL and SQLite packages have Mix tasks (`mix tasks.postgres.stress`,
  `mix tasks.sqlite.stress`) that prepare a database and call `run/1`; those
  tasks are not part of the published packages.

  The report separates exact lifecycle invariants from observed timings so the
  same workload can run in CI and on developer machines without flaky latency
  thresholds.

  This is diagnostic evidence, not a production capacity claim.

  ## Options

    * `:tasks`, `:writers`, `:rounds` - positive integers that size the
      workload (defaults 25, 8, and 3).
    * `:timeout_ms` - a positive integer (default 30,000). It bounds each
      wait the harness performs: readiness of one batch of writers or
      workers, Runner completion and instrumentation for one round, one
      fencing Task, and each busy-retry loop. Every wait gets a fresh
      deadline, so a whole run can take much longer, and a store call that
      blocks is not interrupted until the surrounding wait expires.
    * `:store` - a `{module, state}` store reference. The module must also
      export `history/3`, returning `{:ok, entries}` in commit order where each
      entry is a map with an `:event` key holding the committed
      `Snodo.Extensions.Tasks.Event`, for the read access returned by
      `authorize/3` for `{:get, task_id}`. The store must accept at least
      `:tasks` active tasks in one scope and keep every Task the run creates.
      Task IDs carry a random per-run prefix, so a store that already holds
      tasks can be reused.
    * `:workload` - the label reported as `"workload"` (default
      `"snodo_tasks_memory"`).
    * `:busy?` - an arity-1 predicate that marks a store result as documented
      backpressure that did not change state, such as SQLite's
      `{:error, :database_busy}`. In the CAS race a busy result is a lost
      attempt, counted as `busy`, and never an applied transition. Workload
      setup and the fencing steps retry busy results and report the total as
      `busyRetries`; the harness then checks the stored state, so a store that
      commits and still reports busy fails the run.

  Fixed limits: harness claims use a 60,000 ms lease; the Runner uses a lease
  of `max(2 * timeout_ms, 60_000)` ms and a heartbeat of `timeout_ms`; busy
  retries back off from 1 ms up to 50 ms between attempts.
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

  @schema_version 2
  @default_tasks 25
  @default_writers 8
  @default_rounds 3
  @default_timeout_ms 30_000
  @claim_lease_ms 60_000
  @max_samples 5
  @harness_options [:tasks, :writers, :rounds, :timeout_ms]
  @allowed_options @harness_options ++ [:store, :workload, :busy?]
  @cli_switches [
    tasks: :integer,
    writers: :integer,
    rounds: :integer,
    timeout_ms: :integer,
    json: :boolean
  ]
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

  @doc "Runs deterministic CAS-contention, lease-fencing, and runner-soak workloads."
  @spec run(keyword()) :: report()
  def run(opts \\ []) when is_list(opts) do
    # Validate everything before starting a linked process, so a caller that
    # rescues an ArgumentError does not inherit a stray Agent.
    config = validate_options!(opts)
    given_store = validate_store!(Keyword.get(opts, :store))
    {:ok, collector} = Agent.start_link(fn -> [] end)

    try do
      {store_ref, owned_store} = open_store(given_store)

      try do
        run_with_runner(config, store_ref, collector)
      after
        if owned_store, do: stop_process(owned_store)
      end
    after
      stop_process(collector)
    end
  end

  defp run_with_runner(config, store_ref, collector) do
    {:ok, runner} =
      Runner.start_link(
        store: store_ref,
        owner_id: "stress-runner-#{config.run_id}",
        max_jobs: config.tasks,
        lease_ms: max(config.timeout_ms * 2, 60_000),
        heartbeat_ms: max(config.timeout_ms, 1),
        instrumentation: {Sink, collector}
      )

    try do
      build_report(config, store_ref, runner, collector)
    after
      stop_process(runner)
    end
  end

  @doc false
  # Shared command-line parsing for the stress Mix tasks in this repository.
  @spec parse_args([String.t()], keyword()) ::
          {:ok, keyword(), keyword(), boolean()} | {:error, :invalid_arguments}
  def parse_args(args, extra \\ []) when is_list(args) and is_list(extra) do
    case OptionParser.parse(args, strict: @cli_switches ++ extra) do
      {opts, [], []} ->
        {json, opts} = Keyword.pop(opts, :json, false)
        {harness, extra_opts} = Keyword.split(opts, @harness_options)
        {:ok, harness, extra_opts, json}

      _invalid ->
        {:error, :invalid_arguments}
    end
  end

  @doc false
  # The human-readable report lines printed by the stress Mix tasks.
  @spec format_report(report()) :: [String.t()]
  def format_report(report) do
    config = report["config"]
    cas = report["scenarios"]["casContention"]
    fencing = report["scenarios"]["leaseFencing"]
    runner = report["scenarios"]["runnerSoak"]

    [
      "Tasks stress (#{report["workload"]}, #{report["store"]}): #{config["tasks"]} tasks, " <>
        "#{config["writersPerTask"]} writers, #{config["rounds"]} runner rounds",
      "CAS: #{cas["applied"]} applied, #{cas["conflicts"]} conflicts, #{cas["busy"]} busy, " <>
        "#{cas["unexpected"]} unexpected, #{cas["verifiedTasks"]}/#{config["tasks"]} tasks " <>
        "verified in #{cas["durationUs"]}µs (#{cas["attemptsPerSecond"]} attempts/s, " <>
        format_latency(cas["latencyUs"]) <> ")",
      "Fencing: #{fencing["staleTransitionsRejected"]} stale transitions and " <>
        "#{fencing["staleRenewalsRejected"]} stale renewals rejected, " <>
        "#{fencing["liveTransitionsApplied"]} live transitions applied, " <>
        "#{fencing["verifiedTasks"]}/#{config["tasks"]} tasks verified, " <>
        "#{fencing["unexpected"]} unexpected in " <>
        "#{fencing["durationUs"]}µs (claim " <> format_latency(fencing["claimLatencyUs"]) <> ")",
      "Runner: #{runner["completed"]}/#{runner["expectedJobs"]} completed, " <>
        "peak #{runner["peakJobs"]}, final #{runner["finalJobs"]} jobs, " <>
        "#{runner["releaseFailures"]} release failures in " <>
        "#{runner["durationUs"]}µs (#{runner["jobsPerSecond"]} jobs/s)",
      "Busy retries: #{report["busyRetries"]}",
      "Invariants: #{if(report["ok"], do: "passed", else: "failed")}"
    ] ++ failed_invariant_lines(report)
  end

  defp format_latency(%{"p50" => p50, "p95" => p95, "p99" => p99, "max" => max}),
    do: "p50 #{p50}µs, p95 #{p95}µs, p99 #{p99}µs, max #{max}µs"

  defp failed_invariant_lines(report) do
    for {name, false} <- Enum.sort(report["invariants"]), do: "  failed: #{name}"
  end

  defp validate_store!(nil), do: nil

  defp validate_store!({module, _state} = ref) when is_atom(module) do
    _ref = Store.validate_ref!(ref)

    unless function_exported?(module, :history, 3) do
      raise ArgumentError, "stress store module #{inspect(module)} does not export history/3"
    end

    ref
  end

  defp validate_store!(_invalid),
    do: raise(ArgumentError, ":store must be a {module, state} task store reference")

  defp open_store(nil) do
    # Each round holds every task's worker open at once, so the limits are
    # sized to the workload rather than to the defaults.
    {:ok, store} =
      Memory.start_link(
        scope: :shared,
        max_tasks: :infinity,
        max_active_tasks_per_scope: :infinity
      )

    {{Memory, store}, store}
  end

  defp open_store(ref), do: {ref, nil}

  defp build_report(config, {module, _state} = store_ref, runner, collector) do
    context = context()
    cas = run_cas_contention(config, store_ref, context)
    fencing = run_lease_fencing(config, store_ref, context)
    runner_soak = run_runner_soak(config, store_ref, runner, collector, context)

    invariants = %{
      "casExactlyOneWinnerPerTask" => cas.winner_tasks == config.tasks and cas.unexpected == 0,
      "casLedgerMatchesWinnerPerTask" => cas.ledger_tasks == config.tasks,
      "fencingStaleLeaseRejected" =>
        fencing.stale_transitions_rejected == config.tasks and
          fencing.stale_renewals_rejected == config.tasks and
          fencing.untouched_after_stale == config.tasks,
      "fencingLiveLeaseApplied" =>
        fencing.live_transitions_applied == config.tasks and fencing.unexpected == 0,
      "fencingLedgerMatchesLiveWriter" => fencing.ledger_tasks == config.tasks,
      "runnerAllJobsTerminal" => runner_soak.completed == runner_soak.expected_jobs,
      "runnerEventsBalanced" =>
        runner_soak.started == runner_soak.expected_jobs and
          runner_soak.stopped == runner_soak.expected_jobs,
      "runnerPeakReachedBatch" => runner_soak.peak_jobs == config.tasks,
      "runnerDrained" => runner_soak.final_jobs == 0,
      "runnerReleasesSucceeded" => runner_soak.release_failures == 0,
      "runnerTransitionsApplied" =>
        runner_soak.applied_transitions == runner_soak.expected_jobs and
          runner_soak.other_transitions == 0
    }

    %{
      "schemaVersion" => @schema_version,
      "workload" => config.workload,
      "store" => inspect(module),
      "config" => %{
        "tasks" => config.tasks,
        "writersPerTask" => config.writers,
        "rounds" => config.rounds,
        "timeoutMs" => config.timeout_ms
      },
      "scenarios" => %{
        "casContention" => stringify_keys(cas),
        "leaseFencing" => stringify_keys(fencing),
        "runnerSoak" => stringify_keys(runner_soak)
      },
      "busyRetries" => :counters.get(config.busy_retries, 1),
      "invariants" => invariants,
      "ok" => Enum.all?(invariants, fn {_name, passed?} -> passed? end)
    }
  end

  ## CAS contention

  defp run_cas_contention(config, store_ref, context) do
    started_at = System.monotonic_time()

    {counts, latencies} =
      Enum.reduce(1..config.tasks, {initial_cas_counts(), []}, fn task_number,
                                                                  {totals, latencies} ->
        task_id = task_id(config, "cas", task_number)
        {snapshot, lease, read_access} = create_and_claim!(config, store_ref, context, task_id)
        results = contend(store_ref, snapshot, lease, config.writers, config.timeout_ms)
        totals = verify_cas_task(totals, config, store_ref, task_id, read_access, results)
        {totals, Enum.map(results, fn {_writer, _result, us} -> us end) ++ latencies}
      end)

    duration_us = elapsed_microseconds(started_at)
    attempts = config.tasks * config.writers

    counts
    |> Map.put(:attempts, attempts)
    |> Map.put(:duration_us, duration_us)
    |> Map.put(:attempts_per_second, per_second(attempts, duration_us))
    |> Map.put(:latency_us, percentiles(latencies))
  end

  # Totals across Tasks can balance out (two winners on one Task, none on
  # another), so each Task is checked on its own: exactly one writer reported
  # applied, every other writer lost, and that writer's event is the only
  # ledger entry and the completed result.
  defp verify_cas_task(totals, config, store_ref, task_id, read_access, results) do
    classified =
      Enum.map(results, fn {writer, result, _us} -> {writer, classify_cas(config, result)} end)

    applied = for {writer, :applied} <- classified, do: writer
    conflicts = Enum.count(classified, &match?({_writer, :conflict}, &1))
    busy = Enum.count(classified, &match?({_writer, :busy}, &1))
    unexpected = for {_writer, {:unexpected, result}} <- classified, do: result
    {ledger_ids, final} = final_state(store_ref, task_id, read_access)

    winner? = length(applied) == 1 and conflicts + busy == config.writers - 1

    ledger? =
      case applied do
        [writer] ->
          ledger_ids == [event_id(task_id, writer)] and completed_writer(final) == writer

        _none_or_many ->
          false
      end

    totals
    |> Map.update!(:applied, &(&1 + length(applied)))
    |> Map.update!(:conflicts, &(&1 + conflicts))
    |> Map.update!(:busy, &(&1 + busy))
    |> Map.update!(:committed_events, &(&1 + length(ledger_ids)))
    |> Map.update!(:terminal_tasks, &(&1 + terminal_count(final)))
    |> count_if(:winner_tasks, winner?)
    |> count_if(:ledger_tasks, ledger?)
    |> record_unexpected_results(unexpected)
    |> record_mismatch(winner? and ledger?, fn ->
      "#{task_id}: applied writers #{inspect(applied)}, ledger #{inspect(ledger_ids)}, " <>
        "completed writer #{inspect(completed_writer(final))}"
    end)
  end

  defp classify_cas(_config, {:ok, %Transition{outcome: :applied}}), do: :applied
  defp classify_cas(_config, {:conflict, %Snapshot{}}), do: :conflict

  defp classify_cas(config, other),
    do: if(config.busy?.(other), do: :busy, else: {:unexpected, other})

  defp contend(store_ref, snapshot, lease, writers, timeout_ms) do
    gate = make_ref()
    owner = self()

    tasks =
      Enum.map(1..writers, fn writer ->
        event = completed_event!(snapshot.task.id, writer)
        Task.async(fn -> cas_writer(owner, gate, store_ref, snapshot, lease, writer, event) end)
      end)

    _ready = await_ready(:stress_cas_ready, gate, writers, timeout_ms)
    Enum.each(tasks, &send(&1.pid, {:stress_cas_go, gate}))
    Task.await_many(tasks, timeout_ms)
  end

  defp cas_writer(owner, gate, store_ref, snapshot, lease, writer, event) do
    send(owner, {:stress_cas_ready, gate, self()})

    receive do
      {:stress_cas_go, ^gate} ->
        {result, us} =
          timed(fn ->
            Store.transition(
              store_ref,
              snapshot.task.id,
              snapshot.revision,
              event,
              {:worker, lease}
            )
          end)

        {writer, result, us}
    end
  end

  ## Lease fencing

  # Each Task is claimed, released, and claimed again by a second owner. The
  # first lease must then be refused for both a lifecycle transition and a
  # renewal, the Task must be unchanged afterwards, and the second lease must
  # commit the only ledger event. Tasks run `writers` at a time so a pooled
  # store sees concurrent claim traffic.
  defp run_lease_fencing(config, store_ref, context) do
    started_at = System.monotonic_time()

    results =
      1..config.tasks
      |> Task.async_stream(
        fn task_number ->
          fence_task(config, store_ref, context, task_id(config, "fence", task_number))
        end,
        max_concurrency: config.writers,
        timeout: config.timeout_ms,
        ordered: false
      )
      |> Enum.map(fn {:ok, result} -> result end)

    counts = Enum.reduce(results, initial_fencing_counts(), &count_fencing/2)
    duration_us = elapsed_microseconds(started_at)

    counts
    |> Map.put(:tasks, config.tasks)
    |> Map.put(:duration_us, duration_us)
    |> Map.put(:claim_latency_us, percentiles(Enum.flat_map(results, & &1.claim_latencies)))
  end

  defp fence_task(config, store_ref, context, task_id) do
    {_snapshot, read_access} = create_task!(config, store_ref, context, task_id)
    {_first, stale_lease, first_us} = claim!(config, store_ref, task_id, "stress-fence-a")

    case retry_busy(config, fn -> Store.release(store_ref, stale_lease) end) do
      :ok ->
        fence_released_task(config, store_ref, task_id, read_access, stale_lease, first_us)

      other ->
        failed_fence(store_ref, task_id, read_access, [first_us], [other])
    end
  end

  defp fence_released_task(config, store_ref, task_id, read_access, stale_lease, first_us) do
    {%Snapshot{} = live, live_lease, second_us} =
      claim!(config, store_ref, task_id, "stress-fence-b")

    stale_transition =
      retry_busy(config, fn ->
        Store.transition(
          store_ref,
          task_id,
          live.revision,
          completed_event!(task_id, 1),
          {:worker, stale_lease}
        )
      end)

    stale_renewal =
      retry_busy(config, fn -> Store.renew(store_ref, stale_lease, @claim_lease_ms) end)

    # A retried call that committed before reporting busy would leave a trace
    # here even when its final result looks right.
    untouched? = untouched?(store_ref, task_id, read_access, live, stale_lease, live_lease)

    live_transition =
      retry_busy(config, fn ->
        Store.transition(
          store_ref,
          task_id,
          live.revision,
          completed_event!(task_id, 2),
          {:worker, live_lease}
        )
      end)

    {ledger_ids, final} = final_state(store_ref, task_id, read_access)

    %{
      task_id: task_id,
      claim_latencies: [first_us, second_us],
      stale_transition?: stale_transition == {:error, :stale_lease},
      stale_renewal?: stale_renewal == {:error, :stale_lease},
      untouched?: untouched?,
      live_transition?: match?({:ok, %Transition{outcome: :applied}}, live_transition),
      ledger?: ledger_ids == [event_id(task_id, 2)] and completed_writer(final) == 2,
      ledger_ids: ledger_ids,
      final: final,
      unexpected:
        Enum.reject(
          [stale_transition, stale_renewal, live_transition],
          &(&1 == {:error, :stale_lease} or match?({:ok, %Transition{outcome: :applied}}, &1))
        )
    }
  end

  defp untouched?(store_ref, task_id, read_access, live, stale_lease, live_lease) do
    revision = live.revision

    match?(
      {:ok, %Snapshot{revision: ^revision, task: %{status: :working}}},
      Store.get(store_ref, task_id, read_access)
    ) and
      not match?({:ok, _snapshot}, Store.worker_snapshot(store_ref, task_id, stale_lease)) and
      match?({:ok, _snapshot}, Store.worker_snapshot(store_ref, task_id, live_lease))
  end

  defp failed_fence(store_ref, task_id, read_access, claim_latencies, unexpected) do
    {ledger_ids, final} = final_state(store_ref, task_id, read_access)

    %{
      task_id: task_id,
      claim_latencies: claim_latencies,
      stale_transition?: false,
      stale_renewal?: false,
      untouched?: false,
      live_transition?: false,
      ledger?: false,
      ledger_ids: ledger_ids,
      final: final,
      unexpected: unexpected
    }
  end

  defp count_fencing(result, totals) do
    verified? =
      result.stale_transition? and result.stale_renewal? and result.untouched? and
        result.live_transition? and result.ledger?

    totals
    |> count_if(:stale_transitions_rejected, result.stale_transition?)
    |> count_if(:stale_renewals_rejected, result.stale_renewal?)
    |> count_if(:untouched_after_stale, result.untouched?)
    |> count_if(:live_transitions_applied, result.live_transition?)
    |> count_if(:ledger_tasks, result.ledger?)
    |> Map.update!(:committed_events, &(&1 + length(result.ledger_ids)))
    |> Map.update!(:terminal_tasks, &(&1 + terminal_count(result.final)))
    |> record_unexpected_results(result.unexpected)
    |> record_mismatch(verified?, fn ->
      "#{result.task_id}: stale transition #{result.stale_transition?}, stale renewal " <>
        "#{result.stale_renewal?}, untouched #{result.untouched?}, live applied " <>
        "#{result.live_transition?}, ledger #{inspect(result.ledger_ids)}"
    end)
  end

  ## Runner soak

  defp run_runner_soak(config, store_ref, runner, collector, context) do
    started_at = System.monotonic_time()

    completed =
      Enum.reduce(1..config.rounds, 0, fn round, completed_so_far ->
        batch = create_runner_batch!(config, store_ref, context, round)
        gate = make_ref()
        start_runner_batch!(config, runner, batch, gate)
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

    duration_us = elapsed_microseconds(started_at)
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
      final_jobs: live_runner_jobs(runner),
      release_failures:
        Enum.count(stops, fn {_name, _measurements, metadata} ->
          metadata.release_outcome != :ok
        end),
      applied_transitions: count_metadata(transitions, :outcome, :applied),
      other_transitions:
        Enum.count(transitions, fn {_name, _measurements, metadata} ->
          metadata.outcome != :applied
        end),
      observed_job_duration_us: sum_native_durations(stops),
      duration_us: duration_us,
      jobs_per_second: per_second(completed, duration_us)
    }
  end

  # The stop event's `jobs` measurement is computed before the Runner removes
  # the job, so drain is read from the Runner itself. `:sys.get_state/1` is a
  # synchronous call: it returns only after every message the Runner received
  # before it, including each job's result, has been handled.
  defp live_runner_jobs(runner), do: map_size(:sys.get_state(runner).jobs)

  defp create_runner_batch!(config, store_ref, context, round) do
    Enum.map(1..config.tasks, fn task_number ->
      create_task!(config, store_ref, context, task_id(config, "runner-#{round}", task_number))
    end)
  end

  defp start_runner_batch!(config, runner, batch, gate) do
    owner = self()

    Enum.each(batch, fn {%Snapshot{} = snapshot, _read_access} ->
      start_runner_task!(config, runner, snapshot, owner, gate)
    end)
  end

  defp start_runner_task!(config, runner, snapshot, owner, gate) do
    work = fn _cancellation -> runner_work(owner, gate, snapshot.task.id) end
    start = fn -> Runner.start_task(runner, snapshot, work) end

    # Runner.start_task claims through the store, so it can see backpressure.
    case retry_busy(config, start) do
      :ok -> :ok
      {:error, reason} -> raise "runner rejected stress task: #{inspect(reason)}"
    end
  end

  defp runner_work(owner, gate, task_id) do
    send(owner, {:stress_runner_ready, gate, task_id, self()})

    receive do
      {:stress_runner_go, ^gate} -> {:completed, tool_result(task_id, 1)}
    end
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

  ## Store helpers

  defp create_and_claim!(config, store_ref, context, task_id) do
    {_snapshot, read_access} = create_task!(config, store_ref, context, task_id)
    {claimed, lease, _us} = claim!(config, store_ref, task_id, "stress-cas")
    {claimed, lease, read_access}
  end

  defp claim!(config, store_ref, task_id, owner_id) do
    claim = fn -> Store.claim(store_ref, task_id, owner_id, @claim_lease_ms) end

    case timed(fn -> retry_busy(config, claim) end) do
      {{:ok, %Snapshot{} = claimed, lease}, us} -> {claimed, lease, us}
      {other, _us} -> raise "could not claim stress task: #{inspect(other)}"
    end
  end

  defp create_task!(config, store_ref, context, task_id) do
    create_access = authorize!(store_ref, context, {:create, task_id})
    read_access = authorize!(store_ref, context, {:get, task_id})
    task = ProtocolTask.new!(id: task_id, created_at: ProtocolTask.timestamp(), ttl_ms: nil)
    work = Work.new!(task_id, "stress", %{"taskId" => task_id})

    case retry_busy(config, fn -> Store.create(store_ref, task, work, create_access) end) do
      {:ok, %Snapshot{} = snapshot} -> {snapshot, read_access}
      {:error, reason} -> raise "could not create stress task: #{inspect(reason)}"
    end
  end

  # Workload setup and the fencing steps retry documented backpressure until
  # the timeout, counting each retry. Only the CAS race leaves busy results
  # unretried, because a retry there would change which writer wins. Callers
  # check the stored state afterwards rather than trusting the final result.
  defp retry_busy(config, fun) do
    deadline = System.monotonic_time(:millisecond) + config.timeout_ms
    do_retry_busy(config, fun, deadline, 1)
  end

  defp do_retry_busy(config, fun, deadline, attempt) do
    result = fun.()

    if config.busy?.(result) and System.monotonic_time(:millisecond) < deadline do
      :counters.add(config.busy_retries, 1, 1)
      Process.sleep(min(attempt, 50))
      do_retry_busy(config, fun, deadline, attempt + 1)
    else
      result
    end
  end

  defp authorize!(store_ref, context, action) do
    case Store.authorize(store_ref, context, action) do
      {:ok, access} -> access
      {:error, reason} -> raise "could not authorize stress task: #{inspect(reason)}"
    end
  end

  defp final_state({module, state} = store_ref, task_id, read_access) do
    ledger_ids =
      case module.history(state, task_id, read_access) do
        {:ok, entries} -> Enum.map(entries, fn %{event: %Event{id: id}} -> id end)
        other -> raise "could not read stress task history: #{inspect(other)}"
      end

    case Store.get(store_ref, task_id, read_access) do
      {:ok, %Snapshot{} = final} -> {ledger_ids, final}
      other -> raise "could not read stress task: #{inspect(other)}"
    end
  end

  defp completed_writer(%Snapshot{
         task: %{status: :completed, result: %{"structuredContent" => %{"writer" => writer}}}
       }),
       do: writer

  defp completed_writer(_snapshot), do: nil

  defp event_id(task_id, writer), do: "#{task_id}-writer-#{writer}"

  defp completed_event!(task_id, writer) do
    case Event.completed(tool_result(task_id, writer), id: event_id(task_id, writer)) do
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

  defp task_id(config, kind, number), do: "stress-#{config.run_id}-#{kind}-#{number}"

  ## Waiting

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

  ## Counting

  defp initial_cas_counts do
    %{
      applied: 0,
      conflicts: 0,
      busy: 0,
      unexpected: 0,
      unexpected_samples: [],
      winner_tasks: 0,
      ledger_tasks: 0,
      verified_tasks: 0,
      mismatch_samples: [],
      committed_events: 0,
      terminal_tasks: 0
    }
  end

  defp initial_fencing_counts do
    %{
      stale_transitions_rejected: 0,
      stale_renewals_rejected: 0,
      untouched_after_stale: 0,
      live_transitions_applied: 0,
      ledger_tasks: 0,
      verified_tasks: 0,
      unexpected: 0,
      unexpected_samples: [],
      mismatch_samples: [],
      committed_events: 0,
      terminal_tasks: 0
    }
  end

  defp count_if(counts, key, true), do: Map.update!(counts, key, &(&1 + 1))
  defp count_if(counts, _key, false), do: counts

  # Samples are inspected strings so the report stays JSON-encodable.
  defp record_unexpected_results(counts, results) do
    %{
      counts
      | unexpected: counts.unexpected + length(results),
        unexpected_samples:
          add_samples(counts.unexpected_samples, Enum.map(results, &inspect(&1, limit: 20)))
    }
  end

  defp record_mismatch(counts, true, _describe),
    do: Map.update!(counts, :verified_tasks, &(&1 + 1))

  defp record_mismatch(counts, false, describe),
    do: %{counts | mismatch_samples: add_samples(counts.mismatch_samples, [describe.()])}

  defp add_samples(samples, new), do: Enum.take(samples ++ new, @max_samples)

  defp terminal_count(%Snapshot{task: task}), do: if(ProtocolTask.terminal?(task), do: 1, else: 0)

  defp timed(fun) do
    started_at = System.monotonic_time()
    result = fun.()
    {result, elapsed_microseconds(started_at)}
  end

  defp percentiles([]), do: %{"p50" => 0, "p95" => 0, "p99" => 0, "max" => 0}

  defp percentiles(samples) do
    sorted = samples |> Enum.sort() |> List.to_tuple()
    count = tuple_size(sorted)
    rank = fn percentile -> elem(sorted, max(ceil(percentile * count / 100) - 1, 0)) end

    %{
      "p50" => rank.(50),
      "p95" => rank.(95),
      "p99" => rank.(99),
      "max" => elem(sorted, count - 1)
    }
  end

  defp per_second(_count, 0), do: 0
  defp per_second(count, duration_us), do: div(count * 1_000_000, duration_us)

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
    unless Keyword.keyword?(opts) and Keyword.keys(opts) -- @allowed_options == [] do
      raise ArgumentError, "stress options must use only #{inspect(@allowed_options)}"
    end

    sizes = %{
      tasks: Keyword.get(opts, :tasks, @default_tasks),
      writers: Keyword.get(opts, :writers, @default_writers),
      rounds: Keyword.get(opts, :rounds, @default_rounds),
      timeout_ms: Keyword.get(opts, :timeout_ms, @default_timeout_ms)
    }

    Enum.each(sizes, fn {name, value} ->
      unless is_integer(value) and value > 0 do
        raise ArgumentError, ":#{name} must be a positive integer"
      end
    end)

    workload = Keyword.get(opts, :workload, "snodo_tasks_memory")
    busy? = Keyword.get(opts, :busy?, fn _result -> false end)

    unless is_binary(workload) and workload != "" do
      raise ArgumentError, ":workload must be a non-empty string"
    end

    unless is_function(busy?, 1) do
      raise ArgumentError, ":busy? must be an arity-1 function"
    end

    Map.merge(sizes, %{
      workload: workload,
      busy?: busy?,
      busy_retries: :counters.new(1, [:atomics]),
      run_id: run_id()
    })
  end

  # Random rather than counter-based, so concurrent Mix processes sharing one
  # database never reuse a Task ID.
  defp run_id, do: Base.encode32(:crypto.strong_rand_bytes(10), case: :lower, padding: false)

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
