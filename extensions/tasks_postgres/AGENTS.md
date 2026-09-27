# AGENTS.md: snodo_tasks_postgres

The PostgreSQL store for the Tasks extension. [README.md](README.md) covers usage, the migration, and the evidence lanes. The root [AGENTS.md](../../AGENTS.md) applies here too.

## Two test lanes

- `mix quality` (run by the root `mix quality`) needs no database. It runs the database-independent tests and excludes the live tests.
- `mix quality.postgres` runs the live lane against a real PostgreSQL database: migration lifecycle, transaction concurrency, lease fencing, database-clock retry and TTL behavior, and crash recovery, followed by the executable example. It needs `SNODO_TASKS_DATABASE_URL` and fails with a configuration error without it.

```sh
docker run --rm -d --name snodo-pg -p 55432:5432 \
  -e POSTGRES_USER=postgres -e POSTGRES_PASSWORD=postgres -e POSTGRES_DB=snodo_tasks \
  postgres:18-alpine
SNODO_TASKS_DATABASE_URL=ecto://postgres:postgres@127.0.0.1:55432/snodo_tasks \
  mix quality.postgres
```

CI runs the live lane on PostgreSQL 14, 16, and 18. Run it for any change to this package or to the store contract in `snodo_tasks`.

## Rules

- The live suite does not use the SQL Sandbox: row locking between independent sessions is what it tests. Each run creates and drops its own schema.
- The table name `mcp_tasks` is a wire-level name and does not change.
- Schema changes are new versioned migrations. Existing migrations are not edited.
