# PostgreSQL Tasks store

`snodo_tasks_postgres` is the optional, multi-node persistence package for
`snodo_tasks`. It implements `Snodo.Extensions.Tasks.Store` with PostgreSQL row
locks and an application-owned `Ecto.Repo`.

The package never starts a Repo, creates a database, or runs a migration. Those
remain application deployment decisions. The adapter is intentionally named
for PostgreSQL rather than Ecto: its guarantees rely on JSONB, `timestamptz`,
database clock functions, and `FOR UPDATE SKIP LOCKED`.

## Dependencies and Repo ownership

Add this package and a PostgreSQL driver to the host application, then
configure and supervise the Repo normally:

```elixir
defmodule MyApp.Repo do
  use Ecto.Repo,
    otp_app: :my_app,
    adapter: Ecto.Adapters.Postgres
end
```

`postgrex` is an optional package dependency so this sibling can retain a
dependency-light compile boundary. A host that actually uses the adapter must
include `postgrex` and start a Repo backed by `Ecto.Adapters.Postgres`. JSONB
encoding uses Jason.

## Migration

Call the shipped migration explicitly from an application-owned migration:

```elixir
defmodule MyApp.Repo.Migrations.AddMcpTasks do
  use Ecto.Migration

  def up do
    Snodo.Extensions.Tasks.Store.Postgres.Migration.up()
  end

  def down do
    Snodo.Extensions.Tasks.Store.Postgres.Migration.down()
  end
end
```

For a PostgreSQL schema other than the Repo default, pass the same prefix to
both migration and adapter:

```elixir
Snodo.Extensions.Tasks.Store.Postgres.Migration.up(prefix: "automation")
```

That facade creates the current version-two schema from an empty database. To
upgrade an existing version-one installation, wrap the data-preserving step in
its own application migration:

```elixir
defmodule MyApp.Repo.Migrations.UpgradeMcpTasksToV2 do
  use Ecto.Migration

  def up do
    Snodo.Extensions.Tasks.Store.Postgres.Migration.V2.up(prefix: "automation")
  end

  def down do
    Snodo.Extensions.Tasks.Store.Postgres.Migration.V2.down(prefix: "automation")
  end
end
```

`Migration.V1` remains immutable for historical fixtures. `Migration.V2`
preserves Tasks and events while adding the commit-time ledger index and
updating schema metadata. The current facade's `down/1` remains destructive
because it owns the complete fresh-install schema.

The migration creates:

- `mcp_tasks`, containing one versioned JSONB Snapshot aggregate plus typed
  status, revision, TTL, retry-availability, and claim projections;
- `mcp_task_events`, an ordered applied-event ledger with unique event IDs and
  revisions plus a commit-time lookup index, deleted transactionally with its
  Task; and
- `mcp_task_store_metadata`, which records the adapter schema version.

Every physical column that represents an instant uses PostgreSQL
`timestamptz` at PostgreSQL's default six-digit fractional precision. The Ecto
schemas expose those columns as `:utc_datetime_usec`, so Postgrex loads them as
precision-six UTC `DateTime` values while PostgreSQL comparisons remain
independent of each session's display timezone.

Migration execution is never automatic. Deploy schema changes before starting
code that requires them. `Postgres.check_schema/1` provides an explicit
readiness check.

## Store and runner setup

Build immutable store configuration around the already-running Repo:

```elixir
alias Snodo.Extensions.Tasks.Runner
alias Snodo.Extensions.Tasks.Store.Postgres

postgres =
  Postgres.new!(
    repo: MyApp.Repo,
    prefix: "automation",
    scope: fn context ->
      %{
        "tenant" => context.auth[:tenant_id],
        "subject" => context.auth[:subject]
      }
    end,
    timeout: 15_000,
    lock_timeout_ms: 5_000,
    reap_batch_size: 500
  )

:ok = Postgres.check_schema(postgres)
store_ref = {Postgres, postgres}

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

Pass `store_ref` and `runner` to the Tasks extension exactly as with Memory or
DETS.

The Repo module is configuration, not a connection checked out in advance.
Ecto's pool supplies a transaction connection for each callback, so several
runners and BEAM nodes can use the same store concurrently.

## Authorization scope

`Snodo.Context` crosses the adapter only through `authorize/3`. The application
scope callback must return JSON-safe data: null, booleans, finite numbers,
strings, lists, or maps with string keys. Scalar scopes such as `"tenant-a"`
are supported and stored in a versioned JSON object envelope. Atoms, tuples,
PIDs, references, functions, and bearer-token structures are rejected during
authorization rather than failing later during creation.

Persist stable tenant and principal identifiers only. Do not project the full
Context or authentication credentials into either scope or Work input.
Cross-scope reads and request mutations are concealed as not-found. Claims are
application-worker authority and intentionally span scopes, matching the
generic Tasks store contract.

## Concurrency and recovery guarantees

- Exact claiming locks one Task row before deciding availability.
- `claim_next/3` orders recoverable work by creation time and uses
  `FOR UPDATE SKIP LOCKED`, allowing competing runners to move past a row
  already owned by another transaction.
- Lease deadlines and retry availability use PostgreSQL's clock. After any
  potentially waiting row lock, the adapter reads `clock_timestamp()` again so
  it never judges a lease using a pre-wait timestamp.
- A lease is fenced by Task ID, owner ID, UUID token, monotonically increasing
  generation, and exact persisted expiration. Renewal returns a replacement
  lease, making its previous expiration stale.
- Applied state and its event ledger record commit in one Ecto transaction.
  Expected revision supplies compare-and-set behavior; a duplicate event ID
  replays its original revision, timestamp, and effects.
- Retry deadlines are projected from the versioned Snapshot into `retry_at`.
  Both exact and next-task claims exclude work whose retry deadline is still in
  the future.
- TTL reaping is deliberately bounded by `:reap_batch_size`; `reap/1` returns
  the IDs deleted by that call. Foreign-key cascade removes their event rows in
  the same transaction.

PostgreSQL store restart does not use the DETS boot-epoch rule. A global epoch
would invalidate healthy claims on other nodes. Crashed workers become
recoverable at their database-authoritative lease deadline and receive a
higher generation. Graceful workers release immediately.

Execution is still at least once. A process can perform an external effect and
fail before recording completion, so application executors must deduplicate
with `Work.idempotency_key`.

## Corruption and operations

The database constrains row shape and uniqueness, while the adapter decodes
every accessed Snapshot and event through the Tasks package codecs. It also
checks the aggregate key and authorization envelope, typed projections against
the JSONB aggregate, and complete ledger semantics against the retry policy and
final Snapshot. Unsupported versions, manual edits, projection drift, partial
claims, mismatched event effects, and ledger gaps fail closed as
`{:corrupt_store, task_id, reason}`. Data is never repaired or discarded
automatically.

`Postgres.audit/2` validates a bounded page under short `FOR SHARE` locks:

```elixir
{:ok, report} = Postgres.audit(postgres, limit: 500, after: previous_cursor)
```

Use `next_cursor` until it is `nil`. Schedule audits with care because they
briefly block mutations to the row being checked.

Database commit acknowledgement can be ambiguous if a connection drops while
the server commits. Creation and transitions are replay-safe through their
primary/event keys. An ambiguously acknowledged claim can remain unavailable
until lease expiry; an ambiguously renewed claim may make the caller's prior
lease stale. The framework favors fencing and correctness over guessing that a
mutation failed.

## Package checks

The local contract does not need a database:

```sh
mix quality
mix quality.types
mix tasks.postgres.contract
```

That default lane has 15 database-independent tests and one adapter evidence
group; it excludes the 14 live tests.

The live transaction lane is deliberately separate from default unit quality.
Point it at a dedicated PostgreSQL database:

```sh
SNODO_TASKS_DATABASE_URL=ecto://postgres:postgres@127.0.0.1:55432/snodo_tasks \
  mix quality.postgres
```

`mix tasks.postgres.live` runs the same live evidence without the preceding
format, compile, and executable-example gates. `mix example.postgres` runs only
[`10_tasks_postgres.exs`](https://github.com/joshrotenberg/snodo/blob/main/examples/10_tasks_postgres.exs). All three
commands fail with a direct configuration error when `SNODO_TASKS_DATABASE_URL`
is absent.

```sh
SNODO_TASKS_DATABASE_URL=ecto://postgres:postgres@127.0.0.1:55432/snodo_tasks \
  mix example.postgres
```

The suite starts an ordinary application-owned `Ecto.Repo` pool, creates a
unique schema, explicitly runs the shipped migration, and removes the schema at
the end. It does not use SQL Sandbox: a shared Sandbox connection would mask
the independent-session row locking that exact-claim races and `SKIP LOCKED`
must prove. The seven live evidence groups cover migration lifecycle, scoped
concealment, transaction concurrency, event idempotency, lease fencing,
database-clock retry/TTL behavior, and two-Runner crash recovery.
Those groups currently contain 14 live tests, including data-preserving
version-one upgrade, rollback, and re-upgrade evidence.

The executable example follows the same ownership and cleanup rules while
focusing on the setup path: it checks the migrated schema, creates a Task through
the public extension API, and completes persisted Work through an
application-owned executor. `mix quality.postgres` runs it after the live
contract.
