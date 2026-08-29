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

## Status

The four findings that could produce a wrong-looking server without the author
noticing are fixed. Each entry below records what changed. Items 5 to 7 are
documentation and remain as written.

Fixing them removed 177 lines from the ported application, including the whole
`HexpmMcp.MCP.Wire` module that existed only to work around items 1 and 3.

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

**Fixed.** The strictness stays, because accepting atom keys would mean
silently resolving a collision between `:name` and `"name"`. `MCP.JSONValue`
is now a documented public module stating the rule, and `encodable!/1`
converts an Elixir term into a JSON value under fixed, documented rules: atom
keys and values become strings, date and time types and `URI` and `Version`
become their canonical strings, any other struct becomes a map of its fields,
and terms with no correct JSON form raise rather than guess. A map that would
collide two keys onto one string raises instead of dropping either. The rule
and the helper are referenced from the `MCP.Resource` and `MCP.Result`
moduledocs.

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

**Fixed**, and neither of those ways. `MCP.Router` now enforces the `required`
list of an object input schema before dispatch, unconditionally and
independently of the validator, which is what it already did for prompt
arguments. A missing argument is `-32602 Missing required tool arguments` with
a `data.missing` list naming them. The guarantee needs no configuration and is
easy to state: the schema a server publishes is enforced for the one thing a
schema always says. Every other keyword still depends on the installed
validator, which is unchanged.

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

**Fixed**, both suggestions. `matches?/1` may now answer `{:ok, variables}`,
and the router merges those into the params handed to `read/2`, so a matcher
is never paired with a second parse. Variables may not shadow `"uri"` or
`"_meta"`, which is checked at registration.

`MCP.Resource.Template` compiles a template at build time and `MCP.Resource`
generates `matches?/1` from the result, so a template in the subset needs no
matcher at all. The subset is exact and small: a literal scheme, an authority
and path segments that are each one literal or one whole `{variable}`, and no
operator, modifier, query, fragment, port, or userinfo. Anything else compiles
to `:unsupported` and keeps the previous behavior of matching nothing until
the module implements `matches?/1`, so a partly-recognised template never
gets a matcher that is almost right.

The overlap problem is unchanged and still the application's, which is
correct: only the application knows that `toolbox://groups` is not a group
named `groups`. The generated matchers get this particular case right because
a variable binds exactly one whole segment, so a one-segment URI cannot reach
a two-segment template.

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

**Fixed.** The `MCP.Tool` moduledoc now shows both forms side by side, says
which to reach for, and notes that `{:error, reason}` for a non-`MCP.Error`
becomes `-32603` and tells the client the server broke. The callback typespec
names `MCP.Error.t()` in the error position. The same moduledoc records that
required arguments are enforced by the router before `call/2` runs, so a
handler may pattern match on them.

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

## Evidence that the fixes work

The ported application was rewritten against the fixed framework, and the
changes are subtractive:

- `HexpmMcp.MCP.Wire`, 79 lines, deleted. It existed only for items 1 and 3.
- Its 99-line test file, deleted.
- All four template resources lost their `matches?/1` and their second URI
  parse. `read/2` now destructures the bound variables directly.
- All five resources build payloads as ordinary atom-keyed maps again, passed
  through `MCP.JSONValue.encodable!/1`.

Net 177 lines removed, with behavior unchanged: the same 148 tests pass, and
live `tools/call` and `resources/read` against hex.pm return the same content
over both stdio and Bandit.

In mcp_ex, the core suite went from 167 tests to 216. All 18 examples, the 25
internal contract evidence groups, the three extension packages, and Dialyzer
with no ignore file still pass. `examples/02_structured_schema.exs` gained a
second rejection case so it demonstrates both the router's required-argument
check and the application validator that catches what a required list cannot
express.

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
