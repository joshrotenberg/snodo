# Tasks extension

This independent `:snodo_tasks` Mix package implements the released SEP-2663
Tasks extension for MCP `2026-07-28` without adding task methods or capabilities
to the core protocol catalog. Its only runtime dependency is the `snodo` core;
the core does not compile or depend on Tasks. See
[Packages](https://github.com/joshrotenberg/snodo#packages) for how to depend on
it.

The package owns its source, tests, contract evidence, formatting, Credo, and
Dialyzer gates. From this directory, run:

```sh
mix quality
mix quality.types
mix tasks.contract
mix examples
mix tasks.stress
```

The package maintains 10 local contract groups. The root
`mix quality`, `mix quality.types`, and `mix examples` commands delegate to the
child package where appropriate.

`mix tasks.stress` is a separately invoked, deterministic correctness workload
for many-writer compare-and-set contention and repeated Runner batches. It
produces exact invariant results plus descriptive timings, and accepts `--json`
for artifact collection. See
[`stress-testing.md`](https://github.com/joshrotenberg/snodo/blob/main/extensions/tasks/stress-testing.md).

The frozen Tasks conformance fixture combines core and extension tools. Start
it from this directory so both applications are available:

```sh
MCP_PORT=3001 mix run ../../conformance/fixture_server.exs
```

## What is implemented

- bilateral `io.modelcontextprotocol/tasks` capability negotiation with empty
  settings;
- server-directed task creation around selected `tools/call` operations;
- application policy per tool: `:sync`, `:optional`, or `:required`;
- flat `CreateTaskResult` and `DetailedTask` wire shapes;
- `tasks/get`, `tasks/update`, and `tasks/cancel`;
- application-owned store and independently supervised runner boundaries;
- versioned, JSON-safe `Work` descriptors persisted atomically with each Task;
- application-owned `WorkExecutor` resolution on initial and recovery claims;
- immutable exact-delay retry policies persisted with work descriptors;
- explicit executor-requested retry, restart-safe backoff, and atomic
  retry-exhaustion failure;
- versioned, validated, JSON-safe state-transition events;
- revisioned compare-and-set transitions, duplicate event-ID idempotency, and
  atomic terminal-state races;
- action-scoped opaque request access plus renewable, generation-fenced worker
  claims with exact-task leases;
- exact-task claiming, claim-next recovery, renewal, release, and
  creation-based TTL reaping through the generic store contract;
- mid-task input parking, partial fulfillment, and lifetime-unique input keys;
- store-authoritative input acceptance with a persisted accepted-response inbox
  and deterministic recovery replay;
- a detached execution context that drops request-only transport authority,
  identifiers, metadata, and cancellation state before work starts;
- both volatile `Store.Memory` and local durable `Store.Dets` adapters;
- Streamable HTTP `Mcp-Name` admission mirrored from `params.taskId`;
- tool-domain errors as completed `isError` results and protocol failures as
  failed Tasks.

Removed v1 methods (`tasks/list`, `tasks/result`) remain method-not-found. The
legacy `tools/call.params.task` hint is tolerated and ignored. There is no
legacy `capabilities.tasks` or `tools/list` task-support decoration.

## Application setup

The runtime never starts task infrastructure implicitly. Start and supervise a
store and runner in the application, then pass their references as extension
options:

```elixir
alias Snodo.Extensions.Tasks
alias Snodo.Extensions.Tasks.Runner
alias Snodo.Extensions.Tasks.Store.Memory

{:ok, store} =
  Memory.start_link(
    scope: fn context -> {context.auth[:tenant_id], context.auth[:subject]} end
  )

store_ref = {Memory, store}
{:ok, runner} =
  Runner.start_link(
    store: store_ref,
    instrumentation: {MyApp.MCPInstrumentation, []}
  )

runtime =
  Snodo.Server.Runtime.new(
    router: router,
    protocols: [Snodo.Protocol.V2026_07_28],
    extensions: [
      {Tasks,
       store: store_ref,
       runner: runner,
       task_support: %{
         "quick_report" => :optional,
         "durable_export" => :required
       }}
    ],
    server_info: %{"name" => "example", "version" => "0.1.0"},
    capabilities: %{
      "tools" => %{},
      "extensions" => %{Tasks.id() => %{}}
    }
  )
```

The optional instrumentation sink receives bounded job start/stop and timed
store-transition events. It never receives work input, access values, results,
errors, or input responses. The shared event catalog and a `:telemetry` bridge
are documented in [the instrumentation guide](https://github.com/joshrotenberg/snodo/blob/main/guides/instrumentation.md).
The included stress harness consumes those same events to prove balanced job
lifecycle and runner drain behavior without making latency thresholds part of
correctness.

An optional tool runs synchronously when the request does not declare Tasks and
runs in the Tasks runner when it does. A required tool returns JSON-RPC
`-32021` without the per-request declaration.

Policy values may also be `{mode, task_options}` or an arity-2 function of
`(params, context)`. This lets an application choose sync/task execution per
invocation without putting policy on the wire.

## Durable work and recovery

Every Task is created with a `Snodo.Extensions.Tasks.Work` descriptor containing
an application-defined `type`, JSON-safe `input`, and stable
`idempotency_key`. A versioned immutable `RetryPolicy` is part of that
descriptor; its default is an empty delay list, so executor failures do not
retry unless the application opts in. The default descriptor records a
`tools/call` name and arguments. Within the Tasks integration, the builder's
idempotency key must equal the supplied Task ID so initial and recovered
attempts expose one dedupe identity. Applications that need durable
authorization or tenancy identity can supply an arity-4 `:work_builder`
extension option:

```elixir
work_builder = fn task_id, tool_name, arguments, context ->
  Snodo.Extensions.Tasks.Work.new(task_id, "my_app/tool-call", %{
    "tool" => tool_name,
    "arguments" => arguments,
    "principal" => %{
      "tenant" => context.auth[:tenant_id],
      "subject" => context.auth[:subject]
    }
  })
end
```

Pass that function as `work_builder: work_builder` beside `store`, `runner`, and
`task_support` in the `{Tasks, ...}` extension options shown above.

The builder is the application's explicit security boundary: project only the
stable identity required to resume work. Do not persist `Snodo.Context`, request
transport handles, bearer tokens, or the complete authentication structure.
The descriptor and initial Task snapshot are committed atomically before the
creation result is returned.

For restartable execution, configure a `{module, state}` `WorkExecutor` and
enable recovery on the independently supervised runner:

```elixir
alias Snodo.Extensions.Tasks.Runner
alias Snodo.Extensions.Tasks.Store.Dets

{:ok, store} =
  Dets.start_link(
    path: "/var/lib/my_app/mcp-tasks.dets",
    scope: fn context -> context.auth[:tenant_id] end
  )

store_ref = {Dets, store}

{:ok, runner} =
  Runner.start_link(
    store: store_ref,
    executor: {MyApp.TaskWorkExecutor, application_state},
    recover: true,
    lease_ms: 30_000,
    heartbeat_ms: 10_000,
    reap_interval_ms: 60_000
  )
```

The executor's runtime state is rebuilt by the application and is never stored
in the work descriptor. Its `execute/3` callback receives the descriptor, a
cooperative cancellation token, and the configured state, then returns the
runner's completed, failed, or explicit retry outcome. The runner claims work,
renews its lease while active, releases it after a graceful finish, and uses
`claim_next/3` to recover unclaimed or expired work. A reclaimed Task receives
a higher claim generation, so the prior worker can no longer commit lifecycle
events.
`Store.Dets` also advances a persisted boot epoch when reopened, immediately
fencing leases from the previous store process.

Configure exact retry timing either on a descriptor or through the extension's
global/per-tool `:retry_policy` option:

```elixir
alias Snodo.Extensions.Tasks.RetryPolicy
alias Snodo.Extensions.Tasks.Work

policy = RetryPolicy.new!([250, 1_000, 5_000])

work =
  Work.new!(task_id, "my_app/export", %{"exportId" => export_id},
    retry_policy: policy
  )
```

`RetryPolicy.fixed!/2` and `exponential!/3` are conveniences that expand to the
same exact persisted list. An executor requests the next entry explicitly:

```elixir
{:retry, json_rpc_error, "Export backend is temporarily unavailable"}
```

The `retry_requested` store transition uses `delays_ms[retry_count]`, anchors
`retry_at` to the store-assigned commit timestamp, and atomically increments
the private retry count. If no entry remains, that same transition fails the
Task with the executor's supplied error instead of creating a race between
scheduling and terminal settlement. During backoff the runner releases its
claim. Local timers improve responsiveness, while `claim/4`, `claim_next/3`,
and periodic recovery consult persisted `retry_at` using the store's clock, so
a runner restart cannot run work early or lose a scheduled retry.

Valid `{:failed, error, status_message}` outcomes remain terminal. Exceptions,
throws, exits, invalid executor returns, and cancellation do not implicitly
consume retry policy; they fail closed or follow the existing cancellation
and claim-recovery paths. A fallback closure cannot request retry without a
configured durable `WorkExecutor`, because there would be no restartable
execution boundary for the next claim.

Runner results and input calls are also bound to the exact local execution
attempt. A replacement removes the old job identity, rejects its execution
token, promptly terminates its supervised BEAM process, and only then installs
the recovered worker. A late result or input request therefore cannot borrow
the replacement generation's lease.

Those operations are adapter-neutral: `Store.claim/4`, `claim_next/3`,
`renew/3`, `release/2`, `worker_snapshot/3`, and `reap/1` define the same
contract for Memory, DETS, and the optional PostgreSQL and SQLite siblings.

Recovery is intentionally **at least once**, not exactly once. A worker may
perform an external side effect and fail before recording completion. Claim
generation prevents stale framework commits, but the application must use
`Work.idempotency_key` to deduplicate external effects and design its executor
for replay. The finite delay list bounds committed application-requested
retries. Ambiguous redelivery after a hard runner/node failure does not consume
that list, so physical executor invocations can still repeat under repeated
crashes; that distinction is inherent in the at-least-once model.

## Mid-task input

Ordinary MRTR and task-owned input are separate lifecycles. Complete ordinary
`Snodo.Result.input_required/1` exchanges synchronously before selecting task
execution; once inside a task, use `Tasks.await_input/3` and `tasks/update`.
Workers enforce the selected dialect's result admission and fail with a
protocol error if they return ordinary `input_required` or another task handle
as their final result. There is no automatic continuation bridge between the
two lifecycles. `await_input/3` remains a low-level lifecycle API: applications
must authorize the interaction and validate returned content before effects.

A tool executing inside a Task can suspend on an input request:

```elixir
request =
  Snodo.Elicitation.form("Confirm export", %{
    "type" => "object",
    "properties" => %{"confirmed" => %{"type" => "boolean"}},
    "required" => ["confirmed"]
  })

with {:ok, response} <- Tasks.await_input(context, "export-confirmation", request) do
  {:ok, Snodo.Result.structured(%{"confirmation" => response})}
end
```

The Task becomes `input_required`; a matching `tasks/update.inputResponses`
wakes the worker. Unknown or already-answered update keys are ignored. The
snapshot retains both the original request and its accepted response: after
recovery, repeating the same key and structurally identical request returns the
persisted response without another input event, while repeating an outstanding
request reattaches to it. Reusing the key with a different request is rejected.

## Lifecycle guarantees

```text
working -> input_required | completed | failed | cancelled
input_required -> working | completed | failed | cancelled
completed | failed | cancelled -> immutable
```

The Task snapshot and work descriptor are visible before the creation result is
returned. Completion and cancellation race through revisioned compare-and-set
events, and a late worker result cannot resurrect a cancelled Task. Retrying
the same event ID is idempotent and returns its original committed revision.
The runner is independent of the request-scoped executor, so work can outlive
the request that returned the task handle.

`Snodo.Context` crosses the store boundary only for `authorize/3`. The store
returns an opaque access value bound to one action; reads and request mutations
use that value rather than retaining the context. A runner separately acquires
an unguessable, renewable lease restricted to worker lifecycle events for that
exact Task and claim generation. The worker receives a detached context without
request transport handles, request ID, session, progress, original metadata,
or request cancellation authority.

Input responses are first accepted by the authoritative store transition. They
are persisted in the snapshot's private inbox before a local waiter is woken,
so acceptance is not inferred from runner-local state. Both included adapters
hide cross-scope access as not-found and implement the same revision,
event-replay, authority, claim, and reaping contract.

## Persistence and TTL policy

- `Store.Memory` is the fast volatile adapter. `Store.Dets` persists the full
  aggregate as versioned JSON binaries and syncs creation, transitions, claims,
  renewal, release, and reaping before acknowledging them.
- Adapter and runner calls wait for the authoritative reply instead of using
  the default five-second `GenServer.call/3` timeout, so a slow sync cannot
  report a timeout after silently committing a claim or mutation.
- `Store.Dets` is a local, single-node reference adapter, not a production
  distributed store. Its GenServer serializes operations in one BEAM, DETS has
  a 2 GB file limit, and it does not coordinate claims across nodes. The
  separate [`:snodo_tasks_postgres`](https://github.com/joshrotenberg/snodo/blob/main/extensions/tasks_postgres/README.md) package
  implements the same contract with an application-owned `Ecto.Repo`, row
  locks, database time, and fenced leases without adding Ecto to this package.
  The separate [`:snodo_tasks_sqlite`](https://github.com/joshrotenberg/snodo/blob/main/extensions/tasks_sqlite/README.md) package keeps
  the same Repo/migration ownership while providing file-backed, single-host
  durability through SQLite `IMMEDIATE` transactions and one serialized writer.
- `Store.reap/1` and the runner's optional `:reap_interval_ms` implement this
  project’s cleanup policy: the whole aggregate becomes removable at
  `createdAt + ttlMs`, including if it is active, while `ttlMs: nil` is never
  automatically reaped. The Tasks protocol permits a server to make an expired
  Task unavailable or delete it; it does not require every implementation to
  use this adapter's eager deletion policy.
- Retry/backoff remains at-least-once rather than exactly once. Applications
  own idempotent external effects and decide when their executor explicitly
  returns `{:retry, error, status_message}`.

## Remaining boundaries

- `taskIds` filters and `notifications/tasks` reuse core's application-owned
  subscription source, backpressure, cancellation, and transport lifecycle.
  Tasks validates peer negotiation, admits only store-visible IDs, exposes
  `Tasks.status_event/2`, and owns the final wire shape. Applications still
  decide how store or domain changes are published into their chosen source;
  the Runner does not impose a PubSub system.
- Authentication is not invented by the extension. A transport/application
  supplies `context.auth`; `authorize/3` derives application-specific opaque
  access and the store enforces it on later operations.
- The framework signals the execution token, promptly terminates the supervised
  worker process, and protects Task state atomically. Spawned or external side
  effects remain cooperatively cancellable application work.

See the focused tests under `test/tasks_*` and the executable memory, durable
recovery, retry, and subscription walkthroughs:

- [`07_tasks_memory.exs`](https://github.com/joshrotenberg/snodo/blob/main/examples/07_tasks_memory.exs)
- [`08_tasks_durable.exs`](https://github.com/joshrotenberg/snodo/blob/main/examples/08_tasks_durable.exs)
- [`09_tasks_retry.exs`](https://github.com/joshrotenberg/snodo/blob/main/examples/09_tasks_retry.exs)
- [`17_tasks_subscriptions.exs`](https://github.com/joshrotenberg/snodo/blob/main/examples/17_tasks_subscriptions.exs)
