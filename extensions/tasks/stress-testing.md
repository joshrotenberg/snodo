# Tasks contention and soak testing

The Tasks package includes a deterministic diagnostic harness for repeatable
correctness workloads. `Snodo.Extensions.Tasks.Stress.run/1` runs against any
`Snodo.Extensions.Tasks.Store`. In this repository each store package has a
Mix task that prepares its store and calls it:

```sh
cd extensions/tasks
mix tasks.stress
mix tasks.stress --tasks 100 --writers 16 --rounds 10
mix tasks.stress --tasks 100 --writers 16 --rounds 10 --json

cd extensions/tasks_sqlite
mix tasks.sqlite.stress --tasks 200 --writers 16 --rounds 10

cd extensions/tasks_postgres
SNODO_TASKS_DATABASE_URL=ecto://postgres:postgres@127.0.0.1:55432/snodo_tasks \
  mix tasks.postgres.stress --tasks 200 --writers 16 --rounds 10
```

The Mix tasks live under each package's `lib/mix`, which the Hex manifests
exclude, so they are not in the published packages. `Stress.run/1` is
published with `snodo_tasks`.

The defaults are 25 tasks, eight writers per contended Task, three runner
rounds, and a 30-second timeout. All numeric options must be positive. The
JSON form is intended for CI artifacts and comparison tooling. The report
schema is at version 2, which added the `leaseFencing` scenario, per-Task
verification, latency percentiles, throughput, `store`, release accounting,
and busy accounting.

## Stores

| Task | Store setup | Extra switches |
|---|---|---|
| `mix tasks.stress` | A private `Store.Memory` process | none |
| `mix tasks.sqlite.stress` | A WAL database file in a new, randomly named temporary directory, migrated, then deleted | `--pool-size` (default 5), `--busy-timeout-ms` (5,000), `--store-timeout-ms` (15,000) |
| `mix tasks.postgres.stress` | A randomly named schema in the `SNODO_TASKS_DATABASE_URL` database, migrated, then dropped | `--pool-size` (default 10, minimum 2 for the migration), `--store-timeout-ms` (15,000), `--lock-timeout-ms` (5,000) |

`snodo_tasks` does not depend on either database package. Another store can
use the harness directly:

```elixir
Snodo.Extensions.Tasks.Stress.run(
  store: {MyStore, state},
  workload: "my_store",
  busy?: &match?({:error, :overloaded}, &1),
  tasks: 100
)
```

The store module must export `history/3`, returning `{:ok, entries}` oldest
first, where each entry is a map with the committed event under `:event`. Its
`access` argument is the value `authorize/3` returned for `{:get, task_id}`.
The [custom store guide](guides/custom-stores.md) gives the full shape. The
store must accept `tasks` active Tasks in one scope and keep every Task the
run creates. Task IDs carry a random per-run prefix, so one database can
serve several runs, including concurrent ones.

`:busy?` marks a store's documented backpressure result, one that leaves state
unchanged. The SQLite task sets it for `{:error, :database_busy}`. The
PostgreSQL store has no such result, so every error there is unexpected.

## Where it runs

The SQLite and PostgreSQL tasks are not part of `mix quality`. Each package's
suite runs a four-Task soak through the task's entry point: the SQLite one in
the normal suite, the PostgreSQL one in `mix quality.postgres`, which the
Compatibility workflow runs on PostgreSQL 14, 16, and 18 for every pull
request. The
[Tasks store soak workflow](https://github.com/joshrotenberg/snodo/blob/main/.github/workflows/tasks-soak.yml)
runs both at 200 tasks, 16 writers, and 10 rounds every week, on PostgreSQL
14, 16, and 18, and can be started by hand with different sizes:

```sh
gh workflow run tasks-soak.yml -f tasks=500 -f writers=32 -f rounds=20
```

It uploads each JSON report and the full log. When a run raises before it
prints a report, only the log is uploaded.

## Workloads

`casContention` creates each Task at revision zero, gives a valid worker lease
to all writers, releases them together with unique terminal events, and checks
the store's compare-and-set result. Each Task is checked on its own, because
totals can balance out across Tasks:

- exactly one writer reported applied, and every other writer reported a
  conflict or a busy loss (`casExactlyOneWinnerPerTask`); and
- the Task's ledger holds exactly one event, that writer's, and the completed
  snapshot carries that writer's result (`casLedgerMatchesWinnerPerTask`).

A busy result is never retried here, because a retry would change which writer
wins. A store that commits and then reports busy leaves a ledger entry that no
applied writer accounts for, and fails the second check.

`leaseFencing` creates each Task, claims it, releases the claim, and claims it
again as a second owner. Then, for each Task:

- the first lease is refused with `{:error, :stale_lease}` for both a
  lifecycle transition and a renewal, and afterwards the Task is still working
  at the second claim's revision, the first lease cannot read it through
  `worker_snapshot/3`, and the second lease can (`fencingStaleLeaseRejected`);
- the second lease commits (`fencingLiveLeaseApplied`); and
- the ledger holds exactly one event, the second owner's, and the completed
  snapshot carries its result (`fencingLedgerMatchesLiveWriter`).

Tasks run `writers` at a time, so a pooled store sees concurrent claim
traffic. Every fencing call retries busy results; the state checks are what
catch a call that changed something and still reported busy.

`runnerSoak` creates a full batch of descriptor-bearing Tasks per round, starts
them through one independently supervised Runner, waits until every worker is
live, and releases the batch together. It then proves:

- every expected job emitted one start and one stop (`runnerEventsBalanced`);
- every Task reached the completed state (`runnerAllJobsTerminal`);
- every runner-issued completion transition was applied
  (`runnerTransitionsApplied`);
- every stop event reported a successful lease release
  (`runnerReleasesSucceeded`);
- peak live jobs reached the batch size (`runnerPeakReachedBatch`); and
- the Runner holds no jobs at the end (`runnerDrained`). This is read from the
  Runner's own state after a synchronous call, not from the last stop event,
  whose `jobs` measurement is taken before the job is removed.

Workload setup (create, claim, release, `Runner.start_task/3`) and the fencing
steps retry busy results. The report counts those retries as `busyRetries`.

Rounds provide a deterministic work budget rather than a wall-clock loop. This
makes failures reproducible and keeps the same command useful for a small CI
check or a larger scheduled soak.

## Timeouts and fixed limits

`--timeout-ms` (`:timeout_ms`) bounds each wait the harness performs, not the
whole run: readiness of one batch of CAS writers or Runner workers, Runner
completion and stop instrumentation for one round, one fencing Task, and each
busy-retry loop. Every wait gets a fresh deadline. A store call that blocks is
not interrupted; it overruns until the surrounding wait expires, and the store
call's own timeout (`--store-timeout-ms`, the Repo pool settings) is what
bounds it.

Fixed values: harness claims use a 60,000 ms lease; the Runner uses a lease of
`max(2 * timeout_ms, 60_000)` ms and a heartbeat of `timeout_ms`; busy retries
back off from 1 ms up to 50 ms between attempts. The SQLite and PostgreSQL
tasks set the Repo's `queue_target` to 500 ms and `queue_interval` to
5,000 ms, because contended writers queue for connections by design.

## Report interpretation

The `ok` field is derived only from the exact invariants named above. Timings
are reported in microseconds as observations:

- `durationUs` is wall time for the scenario;
- `latencyUs` (CAS transition attempts) and `claimLatencyUs` (fencing claims,
  including busy retries) give p50, p95, p99, and maximum;
- `attemptsPerSecond` and `jobsPerSecond` divide a count by `durationUs`;
- `observedJobDurationUs` is the sum of native-unit job durations carried by
  instrumentation stop events; and
- `peakJobs` comes from the Runner's start events; `finalJobs` from its state.

`verifiedTasks` counts Tasks that passed every per-Task check in a scenario.
`mismatchSamples` describes up to five Tasks that did not. `unexpected` counts
any other store result, and `unexpectedSamples` keeps up to five of them as
inspected strings.

`jobsPerSecond` includes the harness polling every Task in the batch until all
are complete, so on a database store it is a lower bound rather than the
store's commit rate.

There is deliberately no latency or throughput threshold. Scheduler load,
hardware, VM flags, and instrumentation sinks all affect timing. A deployment
may compare JSON artifacts against its own budget, but the framework's default
gate does not turn machine speed into correctness.

## Scope

The harness covers single-node contention, lease fencing, and Runner lifecycle
accounting through the common Store contract. It is not a claim about
production capacity. Recorded SQLite results, and where the PostgreSQL results
will come from, are in the
[protocol compliance guide](https://github.com/joshrotenberg/snodo/blob/main/guides/protocol-compliance.md#tasks-store-soak-evidence).

SQLite admits one writer at a time. Its soak measures how the write slot and
busy handling behave under many concurrent callers; it does not imply
parallel-writer support.

Not yet covered: multi-node Runner scheduling, crash or restart during load,
and migration under load. The SQLite and PostgreSQL suites test recovery and
migration for correctness, but not under sustained load.
