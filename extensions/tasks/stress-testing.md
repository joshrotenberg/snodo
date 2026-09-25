# Tasks contention and soak testing

The Tasks package includes a deterministic diagnostic harness for repeatable
correctness workloads:

```sh
cd extensions/tasks
mix tasks.stress
mix tasks.stress --tasks 100 --writers 16 --rounds 10
mix tasks.stress --tasks 100 --writers 16 --rounds 10 --json
```

The defaults are 25 tasks, eight writers per contended Task, three runner
rounds, and a 30-second per-phase timeout. All numeric options must be positive.
The JSON form is intended for CI artifacts and comparison tooling; its report
schema starts at version 1.

## Workloads

`casContention` creates each Task at revision zero, gives a valid worker lease
to all writers, releases them together with unique terminal events, and checks
the store's compare-and-set result. The exact invariant is one applied writer,
`writers - 1` conflicts, one committed history event, and one terminal snapshot
per Task.

`runnerSoak` creates a full batch of descriptor-bearing Tasks per round, starts
them through one independently supervised Runner, waits until every worker is
live, and releases the batch together. It then uses the instrumentation stream
to prove:

- every expected job emitted one start and one stop;
- every runner-issued completion transition was applied;
- every Task reached the completed state;
- peak live jobs reached the configured batch size; and
- the last stop event reported zero remaining jobs.

Rounds provide a deterministic work budget rather than a wall-clock loop. This
makes failures reproducible and keeps the same command useful for a small CI
check or a larger scheduled soak.

## Report interpretation

The `ok` field is derived only from exact correctness invariants. Durations are
reported in microseconds as observations:

- `durationUs` is wall time for the scenario;
- `observedJobDurationUs` is the sum of native-unit job durations carried by
  instrumentation stop events; and
- `peakJobs` and `finalJobs` come from the Runner's bounded lifecycle event
  measurements.

There is deliberately no latency or throughput threshold. Scheduler load,
hardware, VM flags, and instrumentation sinks all affect timing. A deployment
may compare JSON artifacts against its own budget, but the framework's default
gate does not turn machine speed into correctness.

## Scope and next evidence

The built-in harness exercises `Store.Memory`, Runner lifecycle accounting,
and the common Store contract. It is a fast contention baseline, not a claim
about production capacity, multi-node scheduling, or database behavior.

PostgreSQL and SQLite already have real transactional race evidence. Their next
operational lane should emit the same versioned report concepts while varying
database versions, pool sizes, writer counts, recovery interruptions, and
migration state. PostgreSQL can measure multi-connection claim throughput;
SQLite should preserve its explicit single-writer scope and measure bounded
busy behavior rather than imply parallel-writer support.
