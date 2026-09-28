# Writing a Tasks store

`Snodo.Extensions.Tasks.Store` is the persistence boundary between the Tasks
runner, request handlers, and an application-owned backend. A store reference is
`{module, state}`. The module implements the behavior callbacks; `state` may be
a process, database configuration, or another application-owned value. Keep
database drivers in your application or a sibling package. `snodo_tasks` has no
database dependency.

## Data and authority

`create/4` commits a `Task` and its JSON-safe `Work` descriptor together before
returning the first `Snapshot`. Persist both, the snapshot revision, event IDs
and their original committed revisions, claim identity and generation, retry
state, input history, and the accepted-response inbox. Acknowledging a create
or transition before these are durable can lose work after a restart.

Only `authorize/3` receives `Snodo.Context`. Derive a scope from the request
principal and return an opaque access value bound to the requested action and
task ID. `get/3` and request-authority `transition/5` check that value; a task
in another scope returns `:not_found`. Do not retain a request context in a
worker lease or work descriptor. A shared scope deliberately gives every
principal with a task ID access to that task.

Worker leases are separate authority. `claim/4` claims one exact task;
`claim_next/3` finds recoverable work after a runner restart. Give each new
claim a higher generation and fence every prior lease. `worker_snapshot/3`,
`renew/3`, `release/2`, and worker-authority `transition/5` check the exact
task, lease identity, owner, generation, and deadline. A lease cannot authorize
request actions. An expired claim can be recovered without waiting for the old
runner, and an adapter restart may invalidate old leases immediately.

## Atomic changes and time

Compare the supplied revision and commit each valid event and snapshot change
in one serialized operation. At one revision, competing writers must produce
one applied event and conflicts for the others. A retry of the same event ID
returns `:duplicate` with its original event revision; reusing that ID for a
different event is an error. Persist input responses in
`Snapshot.accepted_input_responses` in the same transaction that acknowledges
them. This lets a recovered worker replay an answer without prompting again.

The store assigns `Transition.committed_at` using its authoritative clock. The
`retry_requested` event anchors `retry_at` to that time, and both exact and
recovery claims defer work until it is due. Use the same clock for lease expiry
and the creation-based TTL boundary. Once `createdAt + ttlMs` has elapsed,
`get/3` and request transitions return `:not_found` even before `reap/1`
deletes the aggregate. A `nil` TTL never expires. Reaping removes the task,
work, event history, and inbox together. SQL stores should use database time,
not independent application-node clocks.

Enforce `:max_tasks` and `:max_active_tasks_per_scope` inside the atomic create
operation. Return `{:error, {:capacity_exceeded, limit}}` without storing an
aggregate when either count would be exceeded. All limits need documented
defaults and a defined refusal. See the [Tasks README](../README.md#limits).

## Run the shared contract suite

`Snodo.Extensions.Tasks.Store.ContractTest` injects ExUnit tests for the public
behavior. Provide a function that starts a fresh store for each test and accepts
the capacity options supplied by the suite:

```elixir
defmodule MyApp.TaskStoreContractTest do
  use ExUnit.Case, async: false

  use Snodo.Extensions.Tasks.Store.ContractTest,
    start_store: &__MODULE__.start_contract_store/2

  def start_contract_store(_context, options) do
    {:ok, server} =
      MyApp.TaskStore.start_link(
        Keyword.merge(
          [scope: fn context -> context.auth["tenant"] end],
          options
        )
      )

    on_exit(fn -> GenServer.stop(server) end)
    {MyApp.TaskStore, server}
  end
end
```

The suite covers task and work creation, revision conflicts, duplicate events,
claim fencing and recovery, retry deadlines, capacity and scope isolation,
creation-based TTL, and accepted input responses. Memory, DETS, PostgreSQL,
and SQLite run the same checks in this repository. Keep backend-specific tests
for migrations, restart durability, transaction races, and malformed persisted
data.

For contention and runner workload design, see
[`stress-testing.md`](https://github.com/joshrotenberg/snodo/blob/main/extensions/tasks/stress-testing.md).
The included `Snodo.Extensions.Tasks.Stress` harness, run with
`mix tasks.stress`, exercises Memory. Adapt its
compare-and-set and runner workloads to your backend, with multiple real
connections or processes where the backend supports them. Check exact state
invariants; treat timing measurements as observations rather than pass/fail
thresholds.
