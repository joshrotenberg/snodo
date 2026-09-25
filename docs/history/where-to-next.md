# mcp_ex: Where to Next

## 1. Current state

`mcp_ex` is four Mix projects in one tree, six commits deep (`e3cbcc1` initialize → `d815519` docs: record application readiness and client acceptance). All four declare `elixir: "~> 1.18"` and version `0.1.0`:

| Project | app | Runtime deps |
|---|---|---|
| `mix.exs` | `:mcp_ex` | none (credo + dialyxir are dev/test, `runtime: false`) |
| `extensions/tasks/mix.exs` | `:mcp_ex_tasks` | `mcp_ex` (path) |
| `extensions/tasks_postgres/mix.exs` | `:mcp_ex_tasks_postgres` | `mcp_ex_tasks`, `ecto_sql ~> 3.14`, `jason`, optional `postgrex` |
| `extensions/tasks_sqlite/mix.exs` | `:mcp_ex_tasks_sqlite` | `mcp_ex_tasks`, `ecto_sql ~> 3.14`, `jason`, optional `ecto_sqlite3` |

`mix.lock` contains only bunt, credo, dialyxir, erlex, file_system, jason. The core really has zero runtime dependencies.

**Core — mature.** 60 `.ex` files, 12,714 LOC under `lib/`. The shape is exactly what the README claims:

- `lib/mcp/router.ex` (676 LOC) — immutable struct with `tools`/`prompts`/`resources`/`resource_templates`/`resource_names` maps; `register_tool/2`, `register_prompt/2`, `register_resource/2` take **module atoms**, and `dispatch/5` takes semantic operations (`:tools_list`, `{:tools_call, name}`). It owns no process. Duplicate names raise `ArgumentError` at registration.
- `lib/mcp/server.ex` (580 LOC) — the `use MCP.Server` macro plus the raw-map/dialect boundary `dispatch/3`. `__using__` accepts 14 option keys (`lib/mcp/server.ex:42-58`) and `__before_compile__` generates `router/0`, `protocols/0`, `runtime/1`, `child_spec/1`.
- `lib/mcp/server/executor.ex` (502 LOC) — transport-neutral bounded admission, FIFO queue, deadlines, cancellation, owner cleanup.
- `lib/mcp/protocol/v2026_07_28.ex` (1,422 LOC) — the single dialect. `@version "2026-07-28"`, `def era, do: :stateless`, `session: nil` in every built context (`:295`).
- `lib/mcp/protocol/profile.ex` (446) + `inspector.ex` (137) + `registry.ex` (139) — pinned method catalog, pure pre-router inspection, closed allowlist registry.
- Authoring surfaces: `lib/mcp/tool.ex` (244), `lib/mcp/tool/simple.ex` (292), `lib/mcp/resource.ex` (535), `lib/mcp/resource/template.ex` (190), `lib/mcp/prompt.ex` (469), `lib/mcp/completion.ex` (150), `lib/mcp/result.ex` (175).
- `lib/mcp/elicitation.ex` (322) + `lib/mcp/mrtr.ex` (125) + `lib/mcp/mrtr/state.ex` (203) — the ordinary MRTR slice.
- `lib/mcp/subscription*.ex` (338 + hub 403 + event 156 + source 71 + filter 55) — `subscriptions/listen` lifecycle with an application-owned pull source and an optional bounded hub.
- `lib/mcp/extension*.ex` (registry 610 + behaviour 75 + method 91 + route 14) — exact-versioned out-of-tree extension seam with bilateral negotiation and `around_dispatch` middleware.

**Transports — mature but narrow.** `lib/mcp/transport.ex` is a 5-line behaviour (`start_link/1` only). `lib/mcp/transport/stdio.ex` (701 LOC) with `serve/2` and `Framing` (29). HTTP is split: `lib/mcp/transport/streamable_http.ex` (446) is a *pure* adapter (`prepare/3` admission, `execute/3` dispatch) over server-agnostic `Request`/`Response`/`StreamResponse`/`Prepared` structs; `lib/mcp/transport/streamable_http/server.ex` (750) is a dependency-free `gen_tcp` HTTP/1.1 listener, one request per connection. **There is no Plug adapter in-tree** — "Plug" appears only in two moduledoc sentences and one example's fixture data.

**Tasks packages — the heaviest and most-tested part.** `extensions/tasks` has `runner.ex` (981), `store/dets.ex` (1,551), `tasks.ex` (702), plus store/memory (579), snapshot (441), ledger_validator (438), stress (441), retry_policy (170). `tasks_sqlite/store/sqlite.ex` is 1,066 LOC; `tasks_postgres/store/postgres.ex` is 974.

**Tests.** 31 core test files, **271 `test` blocks plus one doctest** (`test/json_value_test.exs:6`), matching `docs/mrtr-elicitation.md:118`'s "**272 passing** (one doctest, 271 tests)". Extensions: 85 Tasks, 23 Postgres (including a 1,079-LOC live suite), 19 SQLite. Total test LOC across all packages: 14,960 — a test tree larger than the core library.

**Conformance/interop.** `conformance/` vendors `requirements/2026-07-28.yaml` at upstream commit `c321dd32035556e6769d3724a8ee97d87c3faaac` (SHA-256 verified by `mix mcp.contract`) plus two checked-in result summaries. `interop/official_client/` pins `@modelcontextprotocol/client` **2.0.0** and has three Node checks: `check.mjs` (echo/cancel over stdio), `check_hexpm.mjs` (target app, stdio + HTTP), `check_mrtr.mjs` (elicitation, stdio + HTTP).

**CI.** One workflow: `.github/workflows/compatibility.yml`. A BEAM matrix (1.18/OTP 27, 1.19/28, 1.20/29) running `mix quality`, plus `quality.types` on the current lane, plus a Postgres 14/16/18 lane running `mix quality.postgres`. **Neither the conformance run nor the interop checks are in CI** — they are checked-in artifacts and local commands.

**Docs.** Ten files in `docs/` (spike-findings 33K, examples-roadmap 18.9K, protocol-compliance 19.4K, target-application-findings 9.7K, static-analysis-plan 8.3K, mrtr-elicitation 7.8K, application-readiness-plan 5.3K, compatibility 4.5K, instrumentation 3.2K, stress-testing 2.9K) plus a 25.9K README and 22 example scripts (20 numbered walkthroughs + two stdio helpers). `mix examples` gates 19 of them (`lib/mix/tasks/examples.ex`: 14 core + 4 Tasks + 1 SQLite); example 10 is opt-in PostgreSQL.

### What the prior docs already concluded

- **`docs/application-readiness-plan.md`** — five milestones. 1 (target app) and 2 (ordinary MRTR/elicitation) are marked complete. **Milestone 3 is "Recommended application stack": "Provide a tested Plug/Bandit integration with streaming, disconnect cleanup, origin/header admission, and application authentication context" and "Select an optional complete JSON Schema backend"** (`:48-54`). Milestones 4 (independent protocol regression) and 5 (application workflows / release readiness) follow.
- **`docs/target-application-findings.md`** — the `hexpm-mcp` port ran entirely on public APIs; "**There is no Plug/Bandit integration yet**" (`:31`). All 24 tools converted to `MCP.Tool.Simple` with **no new DSL options needed**, but the zero-argument tool had to fall back to raw `input_schema` — "demonstrates why the raw declaration path still belongs in the API" (`:100-101`). Four concrete friction items: JSON conversion boundary, required-args vs. validation, template variable handoff, tool-failure-as-result.
- **`docs/spike-findings.md`** — 18 numbered design decisions. Architecture-validation table answers "Can a dialect be added out of tree? **Yes**", and "**Can legacy sessions avoid changing component APIs? Not yet tested.**" (`:276`). Recommended next spike ends: "**A general MRTR API and a legacy `2025-11-25` dialect remain later tests of execution and session boundaries**" (`:392-393`).
- **`docs/protocol-compliance.md`** — eight distinct evidence lanes; official server requirements are "Partial: 22/37 exercised whole scenarios pass; all 37 attempted"; full wire-schema validation is "Not yet measured". Next increments list a complete JSON Schema 2020-12 engine and "more official SDKs".
- **`docs/compatibility.md`** — **note: this is not about protocol versions.** It covers the BEAM matrix, the PostgreSQL major-version matrix, and the `Migration.V1`/`V2` schema chain. It says nothing about MCP protocol compatibility.
- **`docs/examples-roadmap.md`** — explicit deferrals: no examples for progress notifications or authorization until routing/capability/transport/error shapes and conformance lanes exist.

---

## 2. The ergonomics gap (the "cryptic" problem)

### Excerpt A — defining a server with a tool (`examples/01_direct_tools.exs:1-28`)

```elixir
defmodule Examples.DirectTools.Greet do
  use MCP.Tool,
    name: "greet",
    description: "Create a greeting"

  input_schema(%{
    "type" => "object",
    "properties" => %{"name" => %{"type" => "string"}},
    "required" => ["name"],
    "additionalProperties" => false
  })

  @impl true
  def call(%{"name" => name}, _context), do: {:ok, MCP.Result.text("Hello, #{name}!")}
end

defmodule Examples.DirectTools.Server do
  use MCP.Server,
    name: "direct-tools-example",
    version: "0.1.0",
    protocols: [MCP.Protocol.V2026_07_28]

  tool(Examples.DirectTools.Greet)
end
```

What makes it cryptic:
- **One module per tool, minimum.** `MCP.Router.register_tool/2` only accepts a module atom (`lib/mcp/router.ex:45`), and `MCP.Server.tool/1` only accepts a module AST (`lib/mcp/server.ex:74-80`). A three-line tool costs a module, a `use`, a schema, and an `@impl`. A 24-tool server is 24 modules.
- **Hand-written JSON Schema, string keys, camelCase.** The author must know `"additionalProperties"` not `additional_properties`, and that the root must be `"type" => "object"` — which the compile-time check enforces (`lib/mcp/tool.ex:191`).
- **`protocols:` must be spelled out.** The default in `lib/mcp/server.ex:31` is already `[MCP.Protocol.V2026_07_28]`, yet every example and the README pass it explicitly. That's a signal the API reads as "you must understand dialect selection before you can say hello."
- **`MCP.Result` is a 14-constructor tagged union.** `text/2`, `structured/2`, `resource/2`, `tools/1`, `resources/1`, `resource_templates/1`, `resource_read/2`, `prompts/1`, `prompt_get/2`, `completion/2`, `raw/1`, `input_required/1`, `error/2`, `subscription/1`. A handler returning the wrong kind gets `Error.internal("Tool returned the wrong result kind")` at runtime (`lib/mcp/router.ex:443`, `:539`).

`MCP.Tool.Simple` (292 LOC) already fixes the schema half of this:

```elixir
use MCP.Tool.Simple, name: "echo", description: "Echo text", additional_properties: false
argument "text", :string, required: true, min_length: 1
```

It "builds the same raw JSON Schema returned by `MCP.Tool` and leaves `call/2` untouched" (`lib/mcp/tool/simple.ex:5-7`). This is the correct pattern, and it is *only applied to tools*.

### Excerpt B — serving over stdio (`examples/stdio_echo.exs:26-35`)

```elixir
defmodule Example.Server do
  use MCP.Server,
    name: "stdio-echo",
    version: "0.1.0",
    protocols: [MCP.Protocol.V2026_07_28]

  tool(Example.Echo)
end

:ok = MCP.Transport.Stdio.serve(Example.Server.runtime())
```

This one is **fine**. One line. Don't touch it. The ergonomics problem is not the transports.

### Excerpt C — serving over HTTP (`examples/05_http_tools.exs:128-129`)

```elixir
{:ok, listener} = HTTPServer.start_link(runtime: Server.runtime(), port: 0)
{{127, 0, 0, 1}, port, "/mcp"} = HTTPServer.address(listener)
```

Also fine — *if* you are willing to run `MCP.Transport.StreamableHTTP.Server`, a bespoke 750-LOC `gen_tcp` listener whose own moduledoc says "It is intentionally a binding, not a web framework. Each accepted connection carries one request and closes after one response" (`lib/mcp/transport/streamable_http/server.ex:5-7`). For anyone with an existing Phoenix/Bandit app — the realistic deployment case — the instruction is "translate their request into `MCP.Transport.StreamableHTTP.Request` and use the pure adapter directly" (`:11-13`). That translation is unwritten, untested, and undocumented, and it is the single largest concrete gap the readiness plan itself names.

### Excerpt D — exposing a resource (`examples/12_resources.exs:1-18`)

```elixir
defmodule Examples.Resources.ToolboxGroups do
  use MCP.Resource,
    uri: "toolbox://groups",
    name: "Elixir Toolbox groups",
    title: "Toolbox Groups",
    description: "Locally available package-discovery groups",
    mime_type: "application/json",
    annotations: %{"audience" => ["assistant"], "priority" => 0.7}

  @groups [%{"id" => "web", "title" => "Web"}, %{"id" => "data", "title" => "Data"}]

  @impl true
  def read(%{"uri" => uri}, _context) do
    {:ok, MCP.Result.resource_read(MCP.Resource.json(uri, @groups))}
  end
end
```

Three nested layers to return a static JSON blob: `{:ok, ...}` wraps `MCP.Result.resource_read/2` wraps `MCP.Resource.json/3`, and `json/3` needs the URI passed back in even though the router already knows it. Content maps must be JSON-valid with string keys or `MCP.Resource.validate_content!/1` raises; domain structs need an explicit `MCP.JSONValue.encodable!/1` hop, which is exactly finding #1 in `docs/target-application-findings.md:40-49`.

### Excerpt E — calling your own server (`examples/12_resources.exs:114-124`)

```elixir
defp dispatch(runtime, id, method, params \\ %{}) do
  {:ok, response} =
    MCP.Test.dispatch(runtime,
      id: id,
      protocol: @protocol,
      method: method,
      params: params
    )

  response
end
```

…and then every assertion digs through raw wire maps: `get_in(direct, ["result", "resources", Access.at(0), "uri"])`, `get_in(missing, ["error", "code"]) == -32_602`.

This is the sharpest edge. `MCP.Test` is 59 LOC and its moduledoc is explicitly a warning label: "In-process request helpers for component and protocol tests… A real client must send these fields itself" (`lib/mcp/test.ex:2-9`). Without it you hand-build:

```json
{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"echo","arguments":{"text":"hello"},"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}}}
```

(`README.md:217`). **There is no client in this repo.** Not for tests, not for dev, not for talking to another MCP server. Every example, and the README's own "no process is needed" demo, reaches for a module documented as test-only, then parses JSON-RPC by hand. That is the thing that makes `mcp_ex` feel cryptic more than any DSL detail.

### The high-level layer

Four additions. Each compiles down to the existing low-level artifacts, exactly as `MCP.Tool.Simple` already does.

**`MCP.Client`** — the missing half of the library. Speaks the dialect so nobody hand-writes `_meta` again:

```elixir
{:ok, client} = MCP.Client.direct(EchoServer.runtime())

{:ok, tools} = MCP.Client.list_tools(client)
# => [%MCP.Tool.Definition{name: "greet", ...}]

{:ok, %{text: "Hello, Ada!"}} =
  MCP.Client.call_tool(client, "greet", %{"name" => "Ada"})

{:error, %MCP.Error{code: -32602}} =
  MCP.Client.read_resource(client, "hex://missing/info")

{:ok, client} = MCP.Client.connect({:stdio, "elixir", ["my_server.exs"]})
{:ok, client} = MCP.Client.connect({:http, "http://127.0.0.1:3001/mcp"})
```

`MCP.Client.direct/1` wraps `MCP.Server.dispatch/3` with a `:direct` transport context; `connect/1` wraps stdio framing or an HTTP POST. Returns decoded structs and `%MCP.Error{}`, not wire maps.

**`MCP.Server` inline components** — kill the one-module-per-tool floor for the small cases:

```elixir
defmodule EchoServer do
  use MCP.Server, name: "echo-server", version: "0.1.0"

  tool "greet", "Create a greeting" do
    argument "name", :string, required: true
    run fn %{"name" => name}, _ctx -> {:ok, "Hello, #{name}!"} end
  end

  resource "toolbox://groups", "Toolbox groups", mime_type: "application/json" do
    read fn _params, _ctx -> {:ok, %{"groups" => ["web", "data"]}} end
  end
end
```

The macro defines `EchoServer.Tool.Greet` under the hood and registers it — identical `tools/list` output, identical router registration. `protocols:` stays optional (the default already exists).

**Bare-term results** — `MCP.Result.normalize/1` is already called on tool returns (`lib/mcp/router.ex:594`). Extend the same courtesy to resources and prompts so a binary means text, a map means JSON, and `{:error, msg}` means `isError: true`. `MCP.Result.*` stays the explicit form for cache hints, structured content, and `input_required`.

**`MCP.Resource.Simple` / `MCP.Prompt.Simple`** — mirror the `MCP.Tool.Simple` precedent. `argument "name", required: true, description: "..."` instead of a list of `%{"name" => ..., "required" => true}` maps; `render` may return a plain string and get wrapped into `MCP.Prompt.message(:user, MCP.Prompt.text(...))`.

**New modules, named:** `MCP.Client`, `MCP.Client.Stdio`, `MCP.Client.HTTP`, `MCP.Resource.Simple`, `MCP.Prompt.Simple`, and (separate package) `MCP.Plug`.

**Non-goals — hard boundaries:**
- The layer **adds** modules; it does not edit `MCP.Router`, `MCP.Server.dispatch/3`, `MCP.Protocol`, or any dialect. No fork, no parallel dispatch path.
- The low level stays the public contract and the escape hatch. A user mixing inline `tool "x"` with `tool(MyModule)` in the same server must work, because both produce module atoms for the same `register_tool/2`.
- **The contract tests do not adopt the client.** `docs/spike-findings.md:19-21` is explicit that literal vectors run "without using the dialect's request-construction helper." A client that constructs envelopes would destroy that independence. `test/compliance/` keeps its literal maps forever.
- No implicit atom→string key conversion in handler arguments. `docs/target-application-findings.md:104-106` already committed to protocol-native string keys as a visible choice.
- No DSL options invented ahead of a workflow that needs them (`docs/application-readiness-plan.md:76`).

---

## 3. The protocol-version question

### What the code actually speaks

Exactly one version. `lib/mcp/protocol/v2026_07_28.ex:25`:

```elixir
@version "2026-07-28"
```

`lib/mcp/protocol.ex:49`:

```elixir
def builtin_profiles, do: [MCP.Protocol.V2026_07_28.profile()]
```

Asserted at `test/compliance/profile_and_inspector_test.exs:165-167`:

```elixir
assert Registry.versions(registry) == ["2026-07-28"]
assert Protocol.builtin_versions() == ["2026-07-28"]
```

The dialect declares `def era, do: :stateless` (`:257`), sets `session: nil` in every context (`:295`), and returns `allow_session_id?: false` from all four `transport_policy/1` clauses (`:648`, `:665`, `:679`, `:692`). A client sending a header that doesn't match the body version gets `-32020` with `%{"header" => "2025-11-25", "body" => "2026-07-28"}` (`test/compliance/v2026_07_28_vectors_test.exs:207-222`) — the only place a legacy version string appears in the codebase, and it appears as a rejection.

**`docs/compatibility.md` says nothing about protocol versions.** It is the BEAM/PostgreSQL/schema-migration matrix. The protocol-version position lives in three other places:

- `README.md:526-528`: "This is a design spike, not a production MCP SDK. It intentionally defers a bundled JSON Schema 2020-12 engine, deprecated roots/sampling MRTR inputs, **legacy sessions**, authentication, and per-peer fairness."
- `docs/spike-findings.md:276`: "Can legacy sessions avoid changing component APIs? | **Not yet tested.**"
- `docs/spike-findings.md:392-393`: "A general MRTR API and a **legacy `2025-11-25` dialect** remain later tests of execution and session boundaries."

### The good news: the seam already exists

The architecture anticipated this and the hooks are real, not aspirational:

| Seam | Where | Status |
|---|---|---|
| `era()` returns `:session \| :stateless` | `lib/mcp/protocol.ex:21`; validated `lib/mcp/protocol/profile.ex:339` | present, one value used |
| `Context.session` field | `lib/mcp/context.ex:43`, typed `term() \| nil` | present, always `nil` |
| `Registry.versions(registry, era: :session)` | `lib/mcp/protocol/registry.ex:50-56` | present, returns `[]` |
| `Policy.allow_session_id?` | `lib/mcp/transport/policy.ex` | present, always `false` |
| `Policy.stream_mode: :none \| :sse` | same | `:sse` used for `subscriptions/listen` |
| Out-of-tree dialects | `MCPEx.FutureDialect` in `test/support/fixtures.ex` | **proven** — `docs/spike-findings.md:271` |

A second dialect does not require touching `MCP.Router`, `MCP.Tool`, `MCP.Resource`, `MCP.Prompt`, or any user-facing component API. It requires implementing the 13 required `MCP.Protocol` callbacks (`lib/mcp/protocol/registry.ex:8-22`) and adding it to a runtime's `protocols:` list.

### What a stateful older client concretely requires

1. **Initialize/lifecycle.** Older revisions negotiate with an `initialize` request → `InitializeResult` → `notifications/initialized`, and the negotiated version lives in connection state. The current dialect has no `initialize` in its profile at all; version arrives per-request in `params._meta["io.modelcontextprotocol/protocolVersion"]`. A session dialect needs `resolve_operation` clauses for `initialize`/`notifications/initialized` and a way to reject pre-initialize traffic. **M.**
2. **Session storage and IDs.** `Mcp-Session-Id` minting, lookup, expiry, and a `-32600`-class error for an unknown/expired session. Today `Context.session` is a `nil` placeholder and no store exists. Needs a supervised registry with TTL, plus a decision on whether sessions are node-local (ETS) or distributed. This is the part the repo has genuinely never built. **M–L.**
3. **Older transports.** The 2024-era HTTP+SSE binding is two endpoints (`GET /sse` for the server→client stream, `POST /messages` for client→server), correlated by session. That is a different shape from `prepare/3` + one response per connection, and `MCP.Transport.StreamableHTTP.Server`'s "one request per connection, then close" model cannot host a long-lived GET stream for arbitrary responses. `stream_mode: :sse` exists but is wired only to `subscriptions/listen`. Stdio needs no transport change; only lifecycle. **L for HTTP+SSE, S for stdio.**
4. **Capability negotiation deltas.** Older revisions carry `capabilities` in the initialize handshake, not per-request `_meta`. `MCP.Protocol.Profile` already models `capability` per method and `request_metadata: %{request: :required, notification: :optional}`, so a session profile would set `request_metadata` to optional and source capabilities from session state. The extension registry's `negotiate/2` takes a `Context`, so it works either way. **S.**
5. **Notification/streaming delivery.** Server→client `notifications/progress`, `notifications/message`, and `*/list_changed` are all `status: :unsupported` in the current profile (`lib/mcp/protocol/v2026_07_28.ex:34-38`), and `roots/list` + `sampling/createMessage` are `:unsupported` + `:deprecated` (`:41-44`). Older clients expect several of these to work, and they require server-initiated request routing over a session — the "additional routing infrastructure" `lib/mcp/extension.ex:30-32` says does not exist yet. **L.**
6. **Result-shape divergence.** Every current result carries `resultType: "complete"` and mandatory `ttlMs`/`cacheScope` cache hints (`docs/spike-findings.md:237-245`). Older revisions have neither. `shape_result/3` is per-dialect so this is mechanical — but `MCP.Result` metadata carries cache fields that a legacy dialect must drop, and `MCP.Server.apply_cache_policy/3` currently *errors* when they're absent (`lib/mcp/server.ex:500`). **S, with one core touch.**

**Size estimate: 3,000–5,000 LOC and a comparable test tree, for one legacy dialect plus session storage plus the HTTP+SSE transport.** Reasoning: the current single dialect is 1,422 LOC for a *stateless* protocol with no lifecycle and no server→client requests; the session-era surface is strictly larger. Session storage is a new subsystem with its own concurrency and expiry semantics — `extensions/tasks` needed 981 LOC of runner and 579 of memory store for a comparable stateful problem. The HTTP+SSE dual endpoint is a new transport, and the existing single-purpose listener is 750 LOC. Add conformance fixtures per version, and every existing test that asserts one entry in `supportedVersions` needs review.

### Recommendation: **later, behind the adapter boundary — and only when a specific client forces it.**

Not now, and not speculatively. Three reasons grounded in this repo:

1. **The only client actually exercised here already speaks the new protocol.** `interop/official_client/package.json` pins `@modelcontextprotocol/client` **2.0.0**, and all three checks pin modern mode: `{ versionNegotiation: { mode: { pin: "2026-07-28" } } }` (`check.mjs:15`, `check_hexpm.mjs:38`, `check_mrtr.mjs:26`), with `check.mjs:33` asserting `client.getProtocolEra() === "modern"`. That the official SDK has a `getProtocolEra()` accessor and a pin option is repo-visible evidence that **the official client handles both eras itself** — which is precisely the argument for not building era compatibility into the server. *(General knowledge, flagged as such: the broader host ecosystem — desktop apps, IDE integrations, gateways — lags the spec, so a real deployment target may well demand an older revision. That's the trigger condition, not a reason to pre-build.)*
2. **The repo's own scoreboard says the current version isn't finished.** 22/37 exercised scenarios on the frozen `2026-07-28` requirements (`conformance/results/2026-07-28-alpha.11-summary.md`), with 15 `FAILURE` checks and three missing fixtures deliberately excluded rather than laundered into passes. Adding a second version before closing the first splits scarce conformance effort across two moving targets and doubles the regression surface for a library with one contributor.
3. **The cost of deferring is genuinely low, because the seam is already cut.** `era/0`, `Context.session`, `Registry.versions(era:)`, `Policy.allow_session_id?`, and a proven out-of-tree dialect fixture mean a legacy dialect can land later as `:mcp_ex_legacy` — a sibling package, like `:mcp_ex_tasks` — without a core rewrite. That is the payoff for the architecture discipline already spent.

**Concrete trigger:** build it when a named deployment target rejects `2026-07-28`, and build it as a sibling package with its own conformance lane. Until then, one paragraph in the README stating plainly "`mcp_ex` speaks MCP `2026-07-28` only; use a client that negotiates it" is worth more than 4,000 speculative lines.

---

## 4. Recommendation: where to next

### 1. `MCP.Client` — **S**

The library has a server and no client. Every example, the README quick start, and every acceptance test reaches for `MCP.Test.dispatch/2`, a 59-LOC module whose own docs say it is for tests and that "a real client must send these fields itself," then parses `get_in(response, ["result", "content", Access.at(0), "text"])` by hand. This is the single biggest contributor to "cryptic," it is the cheapest thing on this list, and it unblocks almost everything below: better examples, a way to smoke-test the Plug adapter, a way to exercise two eras against each other if a legacy dialect ever lands, and a story for `mcp_ex` as an MCP *consumer* (which matters if this ever wraps Redis tooling). Do this first.

### 2. Plug adapter as `:mcp_ex_plug` — **M**

Already milestone 3 in `docs/application-readiness-plan.md:50-51`; already named as the target app's gap at `docs/target-application-findings.md:31`. The hard part is done: `MCP.Transport.StreamableHTTP.prepare/3` and `execute/3` are pure and take a server-agnostic `Request`, returning `Response` or `StreamResponse` with the SSE headers pre-populated. The work is `%Plug.Conn{} → Request`, `Response → Plug.Conn`, SSE chunking off `StreamResponse.subscription`, disconnect → cancellation, and `origin`/header admission reusing the existing policy. Ships as a sibling package so the core keeps zero runtime deps — the same shape as the Tasks siblings. **Depends on #1** for a test client that isn't a 90-line hand-rolled `gen_tcp` helper (`examples/05_http_tools.exs:32-115`).

### 3. Extend the `.Simple` pattern: `MCP.Resource.Simple`, `MCP.Prompt.Simple`, inline `tool`/`resource` in `MCP.Server`, bare-term results — **M**

The ergonomics layer proper. `MCP.Tool.Simple` is the proof it works: it "builds the same raw JSON Schema returned by `MCP.Tool` and leaves `call/2` untouched," and the target app converted all 24 tools to it without changing a single published definition or needing a new option. Resources and prompts never got the same treatment — a static JSON resource still costs `{:ok, MCP.Result.resource_read(MCP.Resource.json(uri, value))}`, and prompt arguments are still raw `%{"name" => ..., "required" => true}` maps. **Depends on #1**, because the payoff is only visible in examples and docs once they read like `MCP.Client.call_tool(client, "greet", %{"name" => "Ada"})` instead of wire maps.

### 4. Optional complete JSON Schema 2020-12 backend — **M**

`docs/spike-findings.md:287-289`, `docs/application-readiness-plan.md:52-53`, and `docs/protocol-compliance.md` increment 3 all demand it. The default validator is pass-through; `MCP.Schema.Validator.Basic` (331 LOC) is a deliberately bounded subset. The `MCP.Schema.Validator` boundary (24 LOC) already exists, so this is another sibling package wrapping an existing engine — external `$ref` fetching disabled by default, per the spike's own stated requirement. It also directly serves "full wire-schema validation: **not yet measured**" in the compliance table. Independent of #1–#3; slot it wherever there's appetite.

### 5. Conformance + interop in CI — **S**

`.github/workflows/compatibility.yml` runs BEAM and PostgreSQL matrices and nothing else. The 22/37 conformance score and all three official-client checks are checked-in artifacts and local commands. `conformance/README.md` is honest that "There is no expected-failures baseline yet. Failures remain visible rather than being converted into a passing CI result" — which is the right instinct, but it means the score can silently rot. Add a non-blocking job that runs the fixture server and `interop/official_client/check.mjs` on every push, and a `workflow_dispatch` job for the frozen conformance runner that uploads its summary. Cheap; keeps the honesty machinery from decaying. **Do after #1–#2**, so the interop lane covers the Plug adapter too.

### 6. Legacy session-era dialect — **L, deferred**

Per §3. Not until a named client forces it, and then as `:mcp_ex_legacy`.

### What NOT to do

- **Don't build the legacy dialect now.** It's 3,000–5,000 LOC to solve a problem no client in this repo has, while 15 conformance failures sit open on the version you do support.
- **Don't fork or rewrite the low level to make it friendlier.** The router being process-free, the profile being a pinned catalog, the dialect being the only version-aware layer — that's the asset. Every ergonomics win here is additive.
- **Don't let `MCP.Client` into `test/compliance/`.** Literal vectors independent of any request-construction helper is a deliberate property (`docs/spike-findings.md:19-21`). Keep it.
- **Don't widen the Tasks packages.** They're already the largest thing in the tree (`store/dets.ex` alone is 1,551 LOC), the DETS store is a documented single-node reference, and both Ecto adapters need operational soak before any production claim. `docs/application-readiness-plan.md:76`: "Do not expand DSL options or storage adapters until a workflow needs them."
- **Don't chase the last 15 conformance failures before shipping ergonomics.** They're documented, categorized, and honestly scored. A library nobody can figure out how to use doesn't benefit from 30/37.
- **Don't add progress notifications or auth examples.** `docs/examples-roadmap.md:386-394` correctly defers both; an example implies a supported surface.

### First PR: `MCP.Client` with direct in-process dispatch

Scope it to `MCP.Client.direct/1` only — no stdio, no HTTP. One sitting.

**Files:**
- `lib/mcp/client.ex` (new) — `direct/1` builds a `%MCP.Client{runtime: runtime, protocol: "2026-07-28", transport: :direct}`; `list_tools/1`, `list_resources/1`, `list_resource_templates/1`, `list_prompts/1`, `call_tool/3`, `read_resource/2`, `get_prompt/3`, `discover/1`. Each builds the envelope (reusing `protocol.request_metadata/1` the way `MCP.Test.put_protocol_metadata/4` does), calls `MCP.Server.dispatch/3`, and decodes `{"result" => _}` → `{:ok, decoded}` / `{"error" => _}` → `{:error, %MCP.Error{}}`. Monotonic request IDs from a counter in the struct.
- `test/client_test.exs` (new) — build a runtime from `MCPEx.TestFixtures` and cover each verb plus the error path (`read_resource` on an unknown URI → `{:error, %MCP.Error{code: -32602}}`).
- `examples/01_direct_tools.exs` and `examples/12_resources.exs` — replace the `MCP.Test.dispatch` + `get_in` runners with client calls. Keep the exact `--check` output strings (`"01_direct_tools: ok"`, `"12_resources: ok"`) — `lib/mix/tasks/examples.ex` matches them literally.
- `README.md` "Quick start" — replace the `MCP.Test.dispatch` block with `MCP.Client.direct/1`.
- `lib/mcp/test.ex` — **unchanged.** It stays the low-level literal-envelope helper.

**How you'd know it worked:**
- `mix test --warnings-as-errors` green, count above 272.
- `mix mcp.contract` still reports **29 evidence groups** — if that number moves, a contract test got touched and the change is wrong.
- `mix examples` green: all 19 gated examples print their exact one-line success strings, with compiler warnings promoted to errors in fresh VMs.
- `mix format --check-formatted`, `mix credo --strict`, `mix dialyzer` clean (the repo currently carries zero Dialyzer errors and no ignore file — keep it that way).
- `node interop/official_client/check.mjs` still passes, proving the wire didn't shift.
- The real test: the README quick start no longer contains the string `MCP.Test`.

---

## Addendum: adversarial validation (codex / gpt-6-astra, read-only, same repo)

*The assessment above was produced by claude (opus root / sonnet surveyors) through agent_engine's
plan→run→review loop. The finished document was then independently validated by codex with
repository access. Its findings, verbatim:*

The inventory mostly survives; the proposed ordering and âcheap legacy seamâ argument do not. Static audit at `d815519`; tests were not rerun.

Confirmed **more than 10 checks**: six commits; 60 core `.ex` files; 12,714 core LOC; [router.ex](/Users/josh.rotenberg/Code/local/redis-experiments/mcp_ex/lib/mcp/router.ex) 676 LOC; [server.ex](/Users/josh.rotenberg/Code/local/redis-experiments/mcp_ex/lib/mcp/server.ex) 580; executor 502; dialect 1,422; profile 446; inspector 137; registry 139; `MCP.Test` 59; 271 core tests plus one doctest; extension test counts 85/23/19; [official-client pin](/Users/josh.rotenberg/Code/local/redis-experiments/mcp_ex/interop/official_client/package.json) 2.0.0; 19 gated examples.

Concrete corrections:

- **Test accounting:** 30 `*_test.exs` files; 31 includes `test_helper.exs`. The 14,960 LOC counts test suites only; whole test trees including support total 17,426. The â272 passingâ quotation is at [mrtr-elicitation.md:114](/Users/josh.rotenberg/Code/local/redis-experiments/mcp_ex/docs/mrtr-elicitation.md:114), not 118.
- **Invented tool-error quotation:** [router.ex:444](/Users/josh.rotenberg/Code/local/redis-experiments/mcp_ex/lib/mcp/router.ex:444) says **Resource**, and line 540 says **Prompt**, not Tool.
- **Result count:** 15 constructors, including omitted [wire/2](/Users/josh.rotenberg/Code/local/redis-experiments/mcp_ex/lib/mcp/result.ex:155).
- **Notification support:** all three `*/list_changed` notifications are [implemented](/Users/josh.rotenberg/Code/local/redis-experiments/mcp_ex/lib/mcp/protocol/v2026_07_28.ex:197), contrary to Â§3.
- **Cache/result claims:** [server.ex:489](/Users/josh.rotenberg/Code/local/redis-experiments/mcp_ex/lib/mcp/server.ex:489) defaults missing cache metadata; it does not reject absence. Results are not universally `complete`: [MRTR emits `input_required`](/Users/josh.rotenberg/Code/local/redis-experiments/mcp_ex/lib/mcp/protocol/v2026_07_28.ex:460).
- **SSE reasoning:** one request per connection does not prevent long-lived streaming; the listener already has a [streaming/keepalive loop](/Users/josh.rotenberg/Code/local/redis-experiments/mcp_ex/lib/mcp/transport/streamable_http/server.ex:505).
- **Conformance currency:** 22/37 is an August 25 observation. September MRTR work explicitly [did not rerun external conformance](/Users/josh.rotenberg/Code/local/redis-experiments/mcp_ex/docs/mrtr-elicitation.md:131). â15 failures sit openâ overstates current evidence.

**Client-first:** useful convenience, unsupported prerequisite. âEvery example uses MCP.Testâ is false; transport examples exercise actual I/O. A direct-only client cannot validate Plug transport behavior, while an [independent HTTP client already exists](/Users/josh.rotenberg/Code/local/redis-experiments/mcp_ex/interop/official_client/check_hexpm.mjs:153). Neither Plug nor CI needs to wait. The [readiness plan](/Users/josh.rotenberg/Code/local/redis-experiments/mcp_ex/docs/application-readiness-plan.md:48) prioritizes Plug, schema validation, and progress/streamingâthe last underweighted here. The proposed immutable struct counter also cannot advance through APIs returning only results; pagination, MRTR, and tool-error decoding remain underspecified.

**Legacy deferral:** defensible until a deployment requires it; cheap future integration is unproven. [FutureDialect is stateless](/Users/josh.rotenberg/Code/local/redis-experiments/mcp_ex/test/support/fixtures.ex:257), merely remapping an existing tool operation. `allow_session_id?` has no consumers; lifecycle operations lack an execution hook; HTTP admission is [POST-only](/Users/josh.rotenberg/Code/local/redis-experiments/mcp_ex/lib/mcp/transport/streamable_http.ex:135). Modern-pinned acceptance proves neither dual-era compatibility nor session extensibility. The 3,000â5,000 LOC estimate lacks a demonstrated target scope.

**REJECTED as a prioritized roadmap:** inventory largely accurate; client-first dependencies and cheap legacy extensibility are unsupported.

*Editorial note (engine operator): both models agree with the owner's instincts — build the
ergonomics layer (additive, on the `MCP.Tool.Simple` precedent), and defer the legacy dialect
until a named client forces it. The dispute is sequencing: claude argues client-first, codex
argues the Plug adapter and CI don't need it and the repo's own readiness plan puts Plug +
schema validation first. The corrections above (notably: `*/list_changed` IS implemented;
cache metadata defaults rather than errors; the SSE listener already streams) weaken §3 items
5–6 and soften the legacy size estimate in both directions. The `MCP.Client.direct/1` first-PR
scope remains a sound one-sitting unit either way — it just isn't a prerequisite for Plug.*
