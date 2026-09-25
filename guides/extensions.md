# Extensions

An extension adds negotiated behavior without changing the core protocol
profile. It implements `Snodo.Extension`, declares exact-versioned
`Snodo.Extension.Method` values, and is installed on the server:

```elixir
use Snodo.Server,
  name: "my-server",
  version: "1.0.0",
  extensions: [MyApp.Extension]
```

Runtime construction rejects duplicate extension IDs, methods that collide with
any core method (including unsupported and MRTR-only ones), and collisions
between extensions. An installed route runs only when both peers advertise the
extension and its callback accepts the negotiation. An advertised, compatible
extension may also wrap core dispatch and contribute HTTP policy through generic
hooks. An installed but unadvertised extension does nothing.

See `examples/06_custom_extension.exs`.

## Tasks

`snodo_tasks` implements the `io.modelcontextprotocol/tasks` extension on those
hooks. It augments `tools/call`, keeps `tasks/get`, `tasks/update`, and
`tasks/cancel` outside the core catalog, and adds `taskIds` filters and
`notifications/tasks` to subscriptions.

The application owns the store and runner. The package includes memory and
DETS stores; `snodo_tasks_postgres` and `snodo_tasks_sqlite` add
transactional stores behind an application-owned Ecto Repo. Recovery is
at-least-once, so work must use its stable idempotency key for external
effects.

- [Tasks package](https://github.com/joshrotenberg/snodo/blob/main/extensions/tasks/README.md), including the
  [stress-testing harness](https://github.com/joshrotenberg/snodo/blob/main/extensions/tasks/stress-testing.md)
- [PostgreSQL store](https://github.com/joshrotenberg/snodo/blob/main/extensions/tasks_postgres/README.md)
- [SQLite store](https://github.com/joshrotenberg/snodo/blob/main/extensions/tasks_sqlite/README.md)

Examples 07, 08, 09, and 17 run from `extensions/tasks`; example 10 from
`extensions/tasks_postgres` with a live database; example 11 from
`extensions/tasks_sqlite`.
