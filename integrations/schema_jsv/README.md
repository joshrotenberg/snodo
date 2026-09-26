# Optional JSV schema validation

This package provides `Snodo.Schema.Validator.JSV`, an opt-in implementation of
the core validator boundary using JSV. It adds no runtime dependencies to the
`snodo` core and is not an MCP protocol extension. `Basic` remains a useful,
explicitly partial dependency-free option; installing this package does not
silently change any server's validation policy.

## Use from an application

Add `snodo_jsv` next to `snodo`:

```elixir
{:snodo_jsv, "~> 0.1.0"}
```

Then select the backend on the server:

```elixir
defmodule MyApp.MCPServer do
  use Snodo.Server,
    name: "my-application",
    version: "0.1.0",
    protocols: [Snodo.Protocol.V2026_07_28],
    schema_validator: Snodo.Schema.Validator.JSV

  tool(MyApp.Search)
end
```

`Snodo.Router.dispatch/5` also accepts `schema_validator: Snodo.Schema.Validator.JSV`.
Input schemas and output schemas remain the original JSON-decoded maps. The
backend validates data but never inserts defaults, converts keys to atoms,
returns cast values, or rewrites the tool definitions advertised by the server.

## Policy and scope

- The default dialect is JSON Schema Draft 2020-12. Explicit
  `http://json-schema.org/draft-07/schema` (with an optional trailing `#`) is
  supported too. Custom and mixed dialects fail admission. This is schema
  dialect support, **not** support for an older MCP protocol version.
- Give `$id` an absolute form with an authority, such as
  `https://example.test/schemas/thing`. JSV resolves each `$ref` against the
  nearest `$id` using `URI.merge/2`, which before Elixir 1.19 rejected a base
  without an authority. A `urn:` identifier therefore builds on 1.19 and later
  and fails on 1.18 with "you must merge onto an absolute URI". This package
  supports 1.18, so the restriction is real rather than theoretical.
- The adapter validates schemas against JSV's bundled meta-schemas before
  building a root. Schema failures and unsupported policy features become
  `Snodo.Schema.Validator.JSV.BuildError`; `validate/2` raises that error so the
  router treats it as a server configuration failure. Invalid instances return
  `{:error, reason}` and become ordinary invalid-params/output-validation errors
  at the existing router boundary. No library error details are intentionally
  added to public invalid-params messages.
- Local `$ref`, `$defs`, `$anchor`, `$dynamicRef`, `$dynamicAnchor`, and bundled
  resources identified by `$id` work without fetching. Only the library's
  built-in meta-schemas may be externally resolved. Unresolved HTTP(S), file,
  relative, and `jsv:module:` references fail closed: no network or file fetch,
  no invocation of an application module's `json_schema/0`. There is no
  configurable resolver in this slice. Application `$id` values may not use the
  `json-schema.org` authority, which is reserved for trusted bundled dialects;
  otherwise a local resource could shadow a meta-schema and disable validation.
- References may target only schema-valued positions defined by the selected
  supported dialect, or trusted bundled meta-schemas. Pointers into annotations,
  defaults, enum/example data, or maps that contain named schemas are rejected
  before building, even if that data could independently resemble a schema.
  Anchors and resource identifiers must also occur at admitted schema positions;
  duplicate identifiers cannot ambiguously select a target. This intentionally
  stricter policy prevents a reference from activating data that bypassed the
  root meta-schema check or from invoking a hidden casting build hook. Put
  reusable schemas in `$defs` (2020-12) or `definitions` (Draft 7), not annotation
  data. JSON Pointer escapes and resource-relative references still work.
- JSON Schema booleans work as nested schemas and in standalone `compile/1`.
  MCP tool registration still requires schema maps. JSV's separate remote
  resolver boolean restriction therefore does not arise in this adapter.
- Standard vocabularies come from the selected bundled dialect. Unknown
  required vocabularies fail admission; unknown optional vocabularies and
  ordinary vendor annotation keywords do not introduce custom validation.
  A `$vocabulary` key in an ordinary schema does not install a custom dialect.
- JSV casting keywords (`jsv-cast`, `x-jsv-cast`) are rejected before building,
  including their build-time hooks. Runtime casting and atom-producing casts
  are also disabled. The safety scan is deliberately conservative: it rejects
  casting, mixed/custom `$schema`, and unsupported required `$vocabulary`
  declarations even when nested in annotation, enum, or example data. Property
  names inside schema containers are not mistaken for those keywords. This
  restriction avoids hidden schema-control instructions reached by references;
  it is not a claim to accept every possible JSON Schema document.
- The normal 2020-12 dialect treats `format` as annotation. A precompiled root
  may explicitly request `formats: :assertion` using JSV's built-in validators,
  or `formats: :annotation` to explicitly disable assertions. Unknown format
  names fail compilation in assertion mode. Content vocabulary fields remain
  annotations; validation does not fetch URLs or decode arbitrary content.
- Schemas and instances must already be JSON values with string keys, not
  structs or general atoms. Convert domain values deliberately before reaching
  the boundary. This package does not broaden JavaScript/JSON numeric precision
  or promise identical regular-expression behavior across runtimes.

The backend brings the broader 2020-12 validation vocabulary (composition,
conditionals, references, evaluated-property/item tracking, and more) through a
bounded application policy. It is not an unqualified whole-protocol conformance
claim. Elicitation's protocol-specific restricted form schema remains a
separate boundary.

## Compiling a fixed catalog once

The default `validate/2` compiles each supplied schema on each call. This is a
correctness-first path with no global state or unbounded cache. For a fixed
catalog, an application can retain compiled roots in an ordinary module:

```elixir
defmodule MyApp.SchemaValidator do
  @behaviour Snodo.Schema.Validator
  alias Snodo.Schema.Validator.JSV, as: Backend

  @schema MyApp.Search.input_schema()
  @compiled case Backend.compile(@schema, formats: :assertion) do
              {:ok, compiled} -> compiled
              {:error, error} -> raise error
            end

  @impl true
  def validate(instance, schema) when schema === @schema,
    do: Backend.validate_compiled(instance, @compiled)
  def validate(instance, schema), do: Backend.validate(instance, schema)
end
```

Use `schema_validator: MyApp.SchemaValidator` on the server. Compile all input
and output schemas that need the same policy; the fallback above deliberately
uses the default policy. `compile/1` and `compile/2` return
`{:ok, compiled} | {:error, BuildError.t()}`. Compiled values are opaque immutable
roots; do not fabricate or modify them. Recompile them when schemas or backend
versions change. A catalog cache, if later needed, must have application-owned
bounds and a lifecycle.

Validation of attacker-controlled data is still work: put input-size, execution,
and concurrency limits at the transport/application boundary. This package has
no independent validation timeout and is not an untrusted-schema sandbox.

## Version choice and alternatives

The package allows `jsv ~> 0.22.0`, with **0.22.0 locked for this evidence lane**.
JSV supplies runtime compilation and documents 2020-12/Draft 7 support,
vocabularies, and per-call casting controls. Its own tests pin the JSON Schema
test suite; this package's tests verify the adapter policy and router behavior,
not a new independent rerun of that entire upstream suite.

JSONSchex was a credible alternative, but its documented unresolved custom
meta-schema fallback calls for additional fail-closed admission. Exonerate's
compile-time code generation and documented dialect limitations are less suited
to this dynamic boundary. ExJsonSchema's documented Draft 4/6/7 support does not
meet the 2020-12 requirement. These are reasons for this integration choice, not
claims that the alternatives cannot suit other applications.

Primary references checked on 2026-09-14:

- [JSV package](https://hex.pm/packages/jsv/0.22.0)
- [JSV API and casting options](https://jsv.hexdocs.pm/JSV.html)
- [JSV resolver contract](https://jsv.hexdocs.pm/JSV.Resolver.html)
- [Pinned JSV dependency/test-suite declarations](https://github.com/lud/jsv/blob/v0.22.0/mix.exs)
- [JSONSchex dialect policy](https://jsonschex.hexdocs.pm/dialect_and_vocabulary.html)
- [Exonerate documented limitations](https://hexdocs.pm/exonerate/Exonerate.html)
- [ExJsonSchema supported drafts](https://github.com/jonasschmidt/ex_json_schema)

## Verification

From this package directory:

```sh
ERL_FLAGS='+S 4:4' mix deps.get
ERL_FLAGS='+S 4:4' mix quality
ERL_FLAGS='+S 4:4' mix quality.types
```

`mix quality` checks formatting, compilation warnings, strict Credo, and tests.
The tests cover extended keywords, offline references, recursive/dynamic refs,
boolean schemas, explicit Draft 7, malformed schema admission, format policy,
casting/module-hook rejection, exact handler arguments and advertised schemas,
and correct input/output/configuration error routing. Core tests and official
client/schema evidence run in their separate lanes.
