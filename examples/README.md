# Executable examples

The numbered examples are small, standalone programs built only on public APIs.
Examples 1–6 use standalone core `mcp_ex`; examples 07–09 and 17 use the independent
`:mcp_ex_tasks` child package and its one-way core dependency. Example 10 uses
the optional `:mcp_ex_tasks_postgres` sibling and a live application-owned
`Ecto.Repo`. Example 11 uses the optional `:mcp_ex_tasks_sqlite` sibling with
an application-owned Repo and temporary local database file. Example 12 returns
to standalone core `mcp_ex` for Resources, example 13 adds Prompts, and example
14 composes both through Completion, and example 15 applies one pagination
policy to every list surface. Example 16 adds an application-owned subscription
source and the complete stream lifecycle; example 17 lets Tasks extend that
lifecycle without entering the core profile; example 18 supplies an opt-in,
bounded producer for application changes; and example 19 observes dispatch and
subscription pressure without adding a metrics dependency. Run a core example as a walkthrough:

```sh
mix run examples/01_direct_tools.exs
```

Run its deterministic acceptance mode:

```sh
mix run examples/01_direct_tools.exs --check
```

Or run the complete no-external-service set, with every script launched in a
fresh Elixir VM. The root task delegates examples 07–09 and 17 to Tasks and example
11 to the SQLite sibling; examples 12–16 and 18–19 remain in core:

```sh
mix examples
```

Example 10 is deliberately opt-in. From the PostgreSQL package, point it at a
dedicated database whose schema it may modify:

```sh
cd extensions/tasks_postgres
MCP_TASKS_DATABASE_URL=ecto://postgres:postgres@127.0.0.1:55432/mcp_ex_tasks \
  mix example.postgres
```

It creates a uniquely named schema, runs the explicit migration, checks the
schema, completes one Task, and removes that exact schema and Repo on exit.

Example 11 needs no database service or environment variable:

```sh
cd extensions/tasks_sqlite
mix example.sqlite
```

It creates one exact temporary SQLite file, runs the explicit migration,
persists a Task and its Work descriptor across a Repo/Runner restart, completes
the recovered Task, migrates down, and removes the database plus WAL sidecars.

Run the Tasks example directly from its package environment with:

```sh
cd extensions/tasks
mix examples
```

The current full gate requires a POSIX host with `sh` and `mkfifo` because the
stdio example uses a named pipe to close the child process's input while still
verifying its final stdout and exit status. The remaining default examples do
not have that requirement.

| Example | Public surfaces exercised |
|---|---|
| [`01_direct_tools.exs`](01_direct_tools.exs) | Tool/server DSL, discovery, list, direct call, process-free runtime |
| [`02_structured_schema.exs`](02_structured_schema.exs) | Untouched JSON Schema, custom validator, structured output, pre-handler rejection |
| [`03_context_and_state.exs`](03_context_and_state.exs) | Application-owned Agent state, typed request context, vendor metadata, sessionless execution |
| [`04_stdio_concurrency.exs`](04_stdio_concurrency.exs) | Real stdio subprocess, independent work, cancellation, response suppression, clean follow-up |
| [`05_http_tools.exs`](05_http_tools.exs) | Native Streamable HTTP listener, pinned headers, discovery/list/call, executor reuse |
| [`06_custom_extension.exs`](06_custom_extension.exs) | Exact-versioned extension registration, negotiation, context, shaping, collision protection |
| [`07_tasks_memory.exs`](07_tasks_memory.exs) | Independently packaged Tasks, application-owned store/runner, polling, cancellation, authorization-scoped lookup |
| [`08_tasks_durable.exs`](08_tasks_durable.exs) | Serializable work, safe principal projection, DETS reopen, fenced recovery, stable idempotency identity |
| [`09_tasks_retry.exs`](09_tasks_retry.exs) | Persisted exact-delay retry policy, store-authoritative backoff, Runner restart, stable retry identity |
| [`10_tasks_postgres.exs`](10_tasks_postgres.exs) | Application-owned Ecto Repo, explicit migration, PostgreSQL store, public Tasks calls, Runner/WorkExecutor completion |
| [`11_tasks_sqlite.exs`](11_tasks_sqlite.exs) | Application-owned Ecto Repo, explicit SQLite migration, local durable restart/recovery, public Tasks calls |
| [`12_resources.exs`](12_resources.exs) | Static and explicitly matched URI-template resources, separate discovery, JSON reads, cache hints, missing-resource errors |
| [`13_prompts.exs`](13_prompts.exs) | Five `hexpm-mcp`-shaped prompt definitions, cached discovery, flat required arguments, multi-turn messages |
| [`14_completions.exs`](14_completions.exs) | Definition-owned prompt and resource-template completion, contextual arguments, truthful capability advertisement, bounded results |
| [`15_pagination.exs`](15_pagination.exs) | Shared stateless pagination across Tools, Prompts, Resources, and Resource Templates; stable ordering, cache hints, cursor isolation |
| [`16_subscriptions.exs`](16_subscriptions.exs) | Application-owned pull source, truthful filter acknowledgement, bounded list/resource events, subscription metadata, graceful completion |
| [`17_tasks_subscriptions.exs`](17_tasks_subscriptions.exs) | Negotiated extension-owned `taskIds`, authorization-scoped admission, complete `notifications/tasks` snapshots over the shared lifecycle |
| [`18_subscription_hub.exs`](18_subscription_hub.exs) | Reusable application-supervised producer, bounded filter-aware queues, mutable resource update, fresh read, clean completion |
| [`19_instrumentation.exs`](19_instrumentation.exs) | Dependency-free sink, dispatch timing/outcomes, subscription queue/drop measurements, bounded metadata |

The unnumbered stdio files remain interoperability and subprocess acceptance
fixtures. DETS in example 08 is deliberately a local single-node reference
adapter, not a distributed database. Recovery re-executes work at least once;
applications use the stable idempotency key to deduplicate external effects.
Example 09 uses a fake Memory-store clock so its minute-long persisted backoff
is verified instantly and deterministically.
Example 10 is excluded from root `mix examples` because it requires a live
PostgreSQL database; it runs in the PostgreSQL package's opt-in live quality
lane instead.
Example 11 is included because its file-backed SQLite database is embedded,
temporary, and cleaned up by the example itself.
Example 12 mirrors the future `hexpm-mcp` rewrite shape with local fixture data:
`toolbox://groups` is static and `hex://{name}/info` uses an explicit
application-owned matcher. It requires no network access.
Example 13 mirrors the target application's five guided workflows and uses only
local prompt text, so it also requires no network access.
Example 14 uses local package and release fixtures to show partial matching and
context-dependent completion without URI-template expansion or network access.
Example 15 uses a one-entry page size to make every cursor boundary visible,
including omission on final pages and rejection across list methods.
Example 16 uses a small application-owned GenServer source and the public
`MCP.Subscription` lifecycle API. Stdio cancellation and native long-lived HTTP
SSE are exercised separately by the contract suite.
Example 17 runs from `extensions/tasks`, reads current snapshots through the
application-owned store boundary, and demonstrates that Tasks contributes only
its filter and event wire shape while core retains source, backpressure,
cancellation, and completion ownership.
Example 18 starts `MCP.Subscription.Hub` as application state, updates a mutable
resource, publishes the corresponding protocol-neutral event with a helper,
and verifies the notification is followed by a fresh resource read. The hub
does not detect changes or make the immutable router a state owner.
Example 19 configures one sink on the immutable runtime and application-owned
hub, verifies dispatch start/stop outcomes, and deliberately overflows a
one-event listener queue to observe bounded pressure without exposing request
payloads or adding a metrics dependency.
