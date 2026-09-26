# SQLite Tasks store

`snodo_tasks_sqlite` is the optional, single-host embedded persistence package
for `snodo_tasks`. It implements `Snodo.Extensions.Tasks.Store` with a
file-backed SQLite database and an application-owned `Ecto.Repo`.

The package never starts a Repo, creates a database file, or runs a migration.
Those remain application deployment decisions. The adapter is intentionally
named for SQLite rather than Ecto: its guarantees rely on SQLite `IMMEDIATE`
transactions, WAL behavior, foreign-key enforcement, and a database clock.

## Dependencies and Repo ownership

Add this package and `ecto_sqlite3` to the host application:

```elixir
{:snodo_tasks_sqlite, "~> 0.1.0"},
{:ecto_sqlite3, "~> 0.24"}
```

Then configure and supervise the Repo normally:

```elixir
defmodule MyApp.Repo do
  use Ecto.Repo,
    otp_app: :my_app,
    adapter: Ecto.Adapters.SQLite3
end
```

That facade creates the current version-two schema from an empty database. To
upgrade an existing version-one file, wrap the data-preserving step in its own
application migration:

```elixir
defmodule MyApp.Repo.Migrations.UpgradeMcpTasksToV2 do
  use Ecto.Migration

  def up do
    Snodo.Extensions.Tasks.Store.SQLite.Migration.V2.up()
  end

  def down do
    Snodo.Extensions.Tasks.Store.SQLite.Migration.V2.down()
  end
end
```

`Migration.V1` remains immutable for historical fixtures. `Migration.V2`
preserves Tasks and events while adding the commit-time ledger index and
updating schema metadata. The current facade's `down/0` remains destructive
because it owns the complete fresh-install schema.

```elixir
config :my_app, MyApp.Repo,
  database: Path.expand("../data/mcp.sqlite3", __DIR__),
  journal_mode: :wal,
  foreign_keys: :on,
  busy_timeout: 5_000,
  pool_size: 5
```

`ecto_sqlite3` is an optional package dependency so this sibling retains a
dependency-light compile boundary. A host that uses the adapter must include
`ecto_sqlite3`; it supplies Exqlite as the driver. JSON encoding uses Jason.
The four JSON columns are constrained to strict JSON in SQLite but mapped as
raw Ecto strings: the adapter owns decoding so invalid or out-of-range JSON is
reported through its corruption boundary rather than raising while Ecto
materializes a row.

Use a real file. The adapter rejects an in-memory database during
`check_schema/1`: the Ecto SQLite adapter documents that an in-memory database
can be destroyed by a querying-process crash, which is incompatible with this
store's durability boundary.

The application must configure a positive `:busy_timeout`. Current Exqlite
implements it with a cancellable custom busy handler. `PRAGMA busy_timeout`
does not expose that handler's configured duration, so `check_schema/1` cannot
introspect it without replacing it.

## Migration

Call the shipped migration explicitly from an application-owned migration:

```elixir
defmodule MyApp.Repo.Migrations.AddMcpTasks do
  use Ecto.Migration

  def up do
    Snodo.Extensions.Tasks.Store.SQLite.Migration.up()
  end

  def down do
    Snodo.Extensions.Tasks.Store.SQLite.Migration.down()
  end
end
```

SQLite and `ecto_sqlite3` do not support table prefixes. The migration has no
prefix option. It creates:

- `mcp_tasks`, containing one versioned Snapshot plus typed status, revision,
  TTL, retry-availability, and claim projections;
- `mcp_task_events`, an ordered applied-event ledger with unique event IDs and
  revisions plus a commit-time lookup index, deleted with its Task through a
  foreign-key cascade; and
- `mcp_task_store_metadata`, which records the adapter schema version.

SQLite has no native instant type. Every physical time projection is an
integer count of Unix-epoch microseconds. The SQLite wall clock currently has
millisecond resolution; the wider representation preserves exact Snapshot and
event timestamps, lease arithmetic, and strictly increasing commit times.

Migration execution is never automatic. Deploy schema changes before starting
code that requires them. `SQLite.check_schema/1` verifies the current metadata,
a file-backed database, WAL mode, and foreign-key enforcement.

## Store and runner setup

Build immutable store configuration around the already-running Repo:

```elixir
alias Snodo.Extensions.Tasks.Runner
alias Snodo.Extensions.Tasks.Store.SQLite

sqlite =
  SQLite.new!(
    repo: MyApp.Repo,
    scope: fn context ->
      %{
        "tenant" => context.auth[:tenant_id],
        "subject" => context.auth[:subject]
      }
    end,
    timeout: 15_000,
    reap_batch_size: 500
  )

:ok = SQLite.check_schema(sqlite)
store_ref = {SQLite, sqlite}

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

Pass `store_ref` and `runner` to the Tasks extension exactly as with Memory,
DETS, or PostgreSQL.

## Authorization scope

`Snodo.Context` crosses the adapter only through `authorize/3`. The application
scope callback must return JSON-safe data: null, booleans, finite numbers,
strings, lists, or maps with string keys. Scalar scopes are supported and
stored in a versioned JSON object envelope. Atoms, tuples, PIDs, references,
functions, and bearer-token structures are rejected during authorization.

Persist stable tenant and principal identifiers only. Do not project a full
Context or authentication credentials into scope or Work input. Cross-scope
reads and request mutations are concealed as not-found. The adapter loads a
row by its primary Task ID and compares decoded scope values in Elixir; it does
not rely on textual JSON equality. Worker claims intentionally span scopes,
matching the generic Tasks store contract.

## Serialization, recovery, and contention

SQLite does not support Ecto query locks, row-level locks, or PostgreSQL's
`SKIP LOCKED`. The adapter instead establishes this boundary:

- every mutation begins `Repo.transact(..., mode: :immediate)` before reading
  the Task row or database clock;
- SQLite's single writer serializes creation, claiming, renewal, release,
  transition, and reaping across every Repo connection and local process;
- consistent read operations use deferred read transactions so WAL readers can
  proceed while a writer is active;
- after a waiting writer acquires the reservation, it samples SQLite UTC time,
  preventing pre-wait lease, retry, and TTL decisions;
- a lease is fenced by Task ID, owner ID, UUID token, monotonically increasing
  generation, and exact persisted expiration; and
- applied state and its event ledger commit in one transaction, with expected
  revision supplying compare-and-set behavior and event ID supplying replay.

Do not call a write callback from inside an application-owned Repo transaction.
Nested DBConnection transactions join the outer transaction and cannot upgrade
its mode to `IMMEDIATE`; the adapter rejects this as
`{:error, :nested_write_transaction_unsupported}`. This also prevents a Store
callback from reporting success before an outer transaction later rolls back.
Read callbacks invoked inside an application transaction reuse its pinned
connection and consistent snapshot without opening a nested transaction.

When another writer holds the database, Exqlite waits up to the Repo's
`:busy_timeout`. Exhaustion is normalized to `{:error, :database_busy}` and the
transaction leaves the aggregate and ledger untouched. Keep Tasks
transactions short, choose the Repo timeout above its busy timeout, and treat
the error as bounded application backpressure.

`claim_next/3` cannot skip a row held by another writer: it waits for the one
database writer, then chooses the oldest committed available Task. This is a
deliberate correctness/performance tradeoff, not a multi-consumer queue claim.

Store restart does not invalidate healthy claims. Crashed workers become
recoverable at their database-authoritative lease deadline and receive a
higher generation. Graceful workers release immediately. Execution remains at
least once, so executors must deduplicate external effects with
`Work.idempotency_key`.

## Deployment boundary

WAL readers and writers must share SQLite's local shared-memory files. Do not
place this database on a network filesystem or use it from different hosts.
Copying or backing up a live WAL database also requires SQLite-aware backup
handling; the `-wal` file is part of committed state while connections are
open.

This adapter is a good fit for a desktop application, local service, appliance,
or single-host deployment that wants an Ecto-owned embedded task store. Use the
PostgreSQL sibling when independent hosts, row-level locking, `SKIP LOCKED`, or
higher concurrent write throughput are requirements.

SQLite WAL allows concurrent readers but still permits only one writer. See
the official [SQLite WAL](https://sqlite.org/wal.html),
[transaction](https://sqlite.org/lang_transaction.html), and
[Ecto SQLite adapter](https://ecto-sqlite3.hexdocs.pm/) documentation.

## Corruption and operations

The database constrains row shape and uniqueness. The adapter also decodes each
Snapshot and event through the Tasks codecs; checks aggregate identity,
authorization envelope, typed projections, claim shape, and complete ledger
semantics; and fails closed as `{:corrupt_store, task_id, reason}`. It never
repairs or discards data automatically.

`SQLite.audit/2` validates a bounded page from consistent read snapshots:

```elixir
{:ok, report} = SQLite.audit(sqlite, limit: 500, after: previous_cursor)
```

Use `next_cursor` until it is `nil`. Creation and transitions are replay-safe
through their primary/event keys. As with any database, a lost commit
acknowledgement can be ambiguous; an ambiguously acknowledged claim remains
unavailable until its lease expires.

## Package checks

```sh
mix quality
mix quality.types
mix tasks.sqlite.contract
mix example.sqlite
```

The SQLite integration suite uses real temporary files and an ordinary Repo
pool. It does not use SQL Sandbox or `:memory`, because either would hide the
independent-connection serialization and crash-recovery behavior this adapter
must prove. The contract task runs that suite and verifies all seven local
evidence groups. The example performs an explicit migration, persists Work
through a Repo/Runner restart, completes it after recovery, migrates down, and
removes its temporary database plus WAL sidecars.
