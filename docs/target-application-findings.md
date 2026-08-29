# Target application findings

The `hexpm-mcp` rewrite recommended in [spike-findings.md](spike-findings.md)
is done. This records what the public API cost a real application, using only
`use MCP.Server`, `use MCP.Tool.Simple`, `use MCP.Resource`, `use MCP.Prompt`,
`MCP.Result`, `MCP.Error`, `MCP.Test`, `MCP.Transport.Stdio`, and
`MCP.Transport.StreamableHTTP`. No framework internals were reached into and
no framework code was changed to make the port fit.

## What was ported

`hexpm-mcp` is a deployed MCP server for hex.pm and hexdocs.pm, previously
built on `anubis_mcp ~> 1.0` with Bandit. It splits cleanly:

| Layer | Lines | Fate |
| --- | --- | --- |
| Domain: `HexpmMcp`, `Client`, `HexDocs`, `OSV`, `Toolbox`, `Cache`, `Types`, `Formatter` | 3,178 | untouched |
| MCP layer: 24 tools, 5 resources, 5 prompts, server, Plug router, stdio lifecycle | 1,233 | rewritten |

The published surface is byte-identical in the parts a client can see: the
same 24 tool names, 5 prompt names, and 5 resource URIs, with the same
descriptions, argument names, and required-argument sets. The 117 domain tests
passed unmodified throughout, which is what makes the rest of this an
assessment of the framework rather than of the rewrite.

The result compiles warning-free, passes strict Credo and Dialyzer with no
ignore file, answers live `tools/call` and `resources/read` requests against
hex.pm over both stdio and Bandit, and grew the suite from 123 tests to 160.

## Friction

Ordered by how much work each one cost.

### 1. JSON values must have string keys, and the rule is undocumented

`MCP.JSONValue.valid?/1` requires string keys and rejects atom values
outright. `MCP.Resource.json/3` and `MCP.Result.structured/2` raise
`ArgumentError` on anything else.

Elixir domain layers overwhelmingly return atom-keyed maps and structs. This
one does: `%{name: item["title"], type: item["type"], doc: ...}`. Jason
encoded those directly, so the previous resources handed domain values
straight to the framework. Every resource payload now goes through a
recursive conversion helper the application had to write.

`MCP.JSONValue` is `@moduledoc false`, so the constraint appears in no public
documentation. It surfaces at runtime, from inside a call that looks like it
should just encode. The `MCP.Resource` moduledoc says `read/2` "returns
`MCP.Result.resource_read/2` containing text or blob content maps" without
mentioning the key requirement.

Worth considering: accept atom keys and convert at the boundary, or keep the
strictness and export a documented conversion helper. Either way the rule
belongs in the `MCP.Resource` and `MCP.Result` docs, since that is where an
application meets it.

### 2. Pass-through validation silently downgrades a client error to a server fault

With the default `MCP.Schema.Validator.Passthrough`, a `tools/call` that omits
a required argument is not rejected. It reaches `call/2`, fails to match the
handler's pattern, and comes back as:

```json
{"error": {"code": -32603, "message": "Tool raised an exception"}}
```

The tool advertised `"required": ["name"]` in its `inputSchema`. The client
violated a published contract and was told the server broke. Installing
`MCP.Schema.Validator.Basic` restores `-32602`:

```json
{"error": {"code": -32602, "message": "Tool arguments failed schema validation"}}
```

Nothing warns about this. The schema is advertised either way, so the server
looks correct from the outside until a client actually sends bad input. Any
port from a validating framework inherits the regression silently, and a
greenfield server written against the README's Quick start has it from the
first commit.

The dependency-free default is a deliberate and defensible choice. The gap is
that it is invisible. Worth considering: emit a compile-time note when a
registered tool declares `required` and the runtime validator is
`Passthrough`, or default to `Basic` when every registered schema falls inside
its supported subset.

### 3. Declining RFC 6570 leaves the application with more work than it needs

Not implementing template expansion is reasonable, and the reasoning in the
`MCP.Resource` moduledoc is sound: inverse matching and access policy are
application concerns. But the framework currently offers nothing at all, and
the work it leaves behind is done twice.

Each of the four template resources implements `matches?/1`, and then `read/2`
receives `%{"uri" => uri}` and parses the same URI a second time to recover
the variables the matcher already identified. The application ends up with:

```elixir
def matches?(uri), do: match?({:ok, _name}, Wire.hex_package(uri, "info"))

def read(%{"uri" => uri}, _context) do
  with {:ok, name} <- Wire.hex_package(uri, "info"), ...
end
```

Two suggestions, independent of each other:

- Let `matches?/1` optionally return `{:ok, variables}` and pass those to
  `read/2`. The router already calls the matcher and discards its result.
- Offer an opt-in matcher for the common `scheme://{var}/literal` shape.
  Every template in this application, and both in `examples/12_resources.exs`,
  is that shape. It is a small, exactly-specified subset, not a partial
  RFC 6570.

Note also that overlapping URI spaces are entirely the application's problem:
`toolbox://groups` is an exact resource and `toolbox://{group}/{category}` is
a template, and only the application's own matchers keep the first from being
routed to the second. The router raises `-32603` on multiple matches, so
getting this wrong is at least loud.

### 4. Tool error semantics are easy to get wrong and are not spelled out

From `call/2`, both of these are valid and they mean different things:

```elixir
{:ok, MCP.Result.error("Search failed")}   # tools/call result, isError: true
{:error, MCP.Error.execution("Search failed")}  # JSON-RPC error response
```

The callback typespec is `{:ok, Result.t() | term()} | {:error, term()}`,
which does not hint that the second escalates a domain failure into a
protocol error. Across 24 tools this was the most repeated judgment call, and
getting it wrong is not caught by anything: both compile, both return
something plausible, and only a client notices that a failed upstream lookup
was reported as a malformed request.

The distinction is correct and worth keeping. It needs a paragraph in the
`MCP.Tool` moduledoc.

### 5. `MCP.Test` hides a mandatory client obligation

`MCP.Test.dispatch/2` inserts the required `_meta` protocol metadata. An HTTP
request that omits it is rejected with `-32602 Required request _meta is
missing`.

That is protocol-correct, but it means a full test suite written against
`MCP.Test` can pass while every real request fails, and the direct path is a
poor rehearsal for the transport path. This cost debugging time here: the
direct-dispatch tests were green before the first Plug test was written, and
the first Plug test returned 400.

The helper is doing the right thing. Its moduledoc should say that it is
supplying something a real client must send itself, and the README's request
example is the closest thing to that today.

### 6. Descriptions are explicit with no `@moduledoc` fallback

`MCP.Tool` requires `description:`. The previous framework used `@moduledoc`.
Each of the 24 tools now carries the same sentence twice.

This is defensible: the wire description is a published API and should not
change because someone improved an internal doc. It is listed only because it
is a visible difference a port will hit 24 times, and one line in the docs
saying it is deliberate would settle it.

### 7. The Elixir floor moves to 1.18

`mcp_ex` uses the built-in `JSON` module. `hexpm-mcp` declared `~> 1.17` and
had to move to `~> 1.18`. This is the correct trade for a dependency-free
runtime and is already documented, but it is a real constraint for
applications supporting older releases and belongs in the README's Scope
boundaries rather than only in the opening paragraph.

## What worked

These are not padding. Each one removed code or a whole category of problem.

### `MCP.Tool.Simple` is a near drop-in

Anubis's `schema do field(:query, :string, required: true) end` becomes
`argument("query", :string, required: true)`. All 24 tools converted
mechanically. The only handler change is that argument maps carry the
protocol's string keys instead of atoms, which is a better default: there is
no atom-creation question at the boundary.

### The Plug seam is the right shape

`StreamableHTTP.handle/3` with the `Request` and `Response` structs made the
Bandit integration about 40 lines, with no framework detail leaking into the
Plug and no framework knowledge of Plug. This is the seam the moduledoc
promises, and it delivers. `allowed_origin_hosts` being a per-call option
rather than a constant is what makes a deployed hostname workable.

### `Stdio.serve/2` blocking to EOF deleted a workaround

The previous implementation carried `StdioLifecycle`, 66 lines plus 5 tests,
whose entire job was surviving a framework that stopped a *permanent
supervised child* on EOF: the supervisor restarted it, the new transport read
EOF immediately, and the restart storm eventually took the node down with a
non-zero status and an `erl_crash.dump` on every ordinary client disconnect.

Because `serve/2` is a blocking call that returns `:ok` at EOF, "the client
went away" is an ordinary return value. The replacement is a `Task` that
serves and then halts, and the entire failure mode is gone.

### The process-free runtime removed all MCP supervision

There is no server process to start, name, register, or look up. The stdio
path runs one task; the HTTP path calls `Server.runtime()` per request. The
supervision tree lost a child and gained nothing.

### Testing improved by a wide margin

`MCP.Test.dispatch/2` needs no processes, so the entire catalog, every
schema, and all routing behavior is assertable synchronously in microseconds.
The 15-test direct-dispatch file runs in 0.06 seconds.

For contrast, the best the previous stack could manage for its HTTP route was
asserting that the request reached the transport by catching the exception it
threw:

```elixir
# The test env starts no MCP server, so the transport raises looking up its
# session config. Raising from inside Anubis is the assertion.
assert_raise ArgumentError, fn -> Router.call(conn(:get, "/mcp"), []) end
```

That test is now a real request returning a real catalog.

## Assessment

The framework carried a real application without modification. Nothing in the
port required a framework change, a workaround against framework behavior, or
access to a private module. The two structural bets, an immutable
process-free router and transport-agnostic response descriptors, both paid
off directly: one deleted a supervision workaround, the other made the Plug
integration trivial.

The friction is concentrated at the boundary where an Elixir application's
ordinary values meet the framework's JSON discipline, and in defaults that are
correct for a dependency-free library but surprising for an application. Items
1, 2, and 4 are the ones that can produce a wrong-looking server without the
author noticing, and are worth addressing before release packaging. Items 3
and 5 cost time but fail loudly. Items 6 and 7 are documentation.
