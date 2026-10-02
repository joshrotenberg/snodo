# Tools, resources, and prompts

A server is a module that uses `Snodo.Server` and declares components. Each
component is a module, written by hand or generated from an inline block. The
router registers modules either way, so the forms can be mixed in one server.

| Form | Tool | Resource | Prompt |
|---|---|---|---|
| Full control | `use Snodo.Tool` | `use Snodo.Resource` | `use Snodo.Prompt` |
| Concise | `use Snodo.Tool.Simple` | `use Snodo.Resource.Simple` | `use Snodo.Prompt.Simple` |
| Inline in the server | `tool "name", opts do ... end` | `resource "name", opts do ... end` | `prompt "name", opts do ... end` |

## Server options

```elixir
defmodule MyServer do
  use Snodo.Server,
    name: "my-server",
    version: "1.0.0",
    instructions: "Tools for looking up packages",
    schema_validator: Snodo.Schema.Validator.Basic,
    pagination: [page_size: 50],
    tools_cache: [ttl_ms: 60_000, scope: "public"]

  tool MyServer.Search
end
```

`use Snodo.Server` defines `runtime/1`, which builds the immutable
`Snodo.Server.Runtime` that every transport and the client take. `runtime/1`
accepts the same options as overrides. Other options: `protocols:` (see
[Initialize-era clients](initialize-era-clients.md)), `discovery_cache:`,
`prompts_cache:`, `resources_cache:`, `capabilities:`, `extensions:`,
`subscription_source:`, `instrumentation:`, and `authorization:`.

## Generate a catalog document

`mix snodo.catalog` writes Markdown for the catalog visible to a client. Use a
compiled server module with `runtime/0`, or connect to a running Streamable
HTTP MCP endpoint:

```sh
mix snodo.catalog --server MyServer --output catalog.md
mix snodo.catalog --url http://127.0.0.1:4000/mcp --output catalog.md
```

Omit `--output` to write to stdout. The document includes tools and their input
and output schemas, resources and URI templates, prompts and arguments, and
component annotations. Its coverage section counts components and arguments
without descriptions and names each gap. Both modes use `Snodo.Client`, so
pagination and the server's selected protocol version determine what appears.

## Tools

A project that uses the DSL can add `import_deps: [:snodo]` to its
`.formatter.exs` so that `mix format` leaves DSL calls such as `tool`,
`argument`, and `input_schema` without parentheses.

`Snodo.Tool.Simple` builds the input schema from `argument/3` declarations:

```elixir
defmodule MyServer.Search do
  use Snodo.Tool.Simple,
    name: "search",
    description: "Search packages",
    additional_properties: false

  argument "query", :string, required: true, min_length: 1
  argument "page", :integer, minimum: 1
  argument "tags", {:array, :string}, unique_items: true

  @impl true
  def call(%{"query" => query} = arguments, _context) do
    {:ok, "searching for #{query} on page #{arguments["page"] || 1}"}
  end
end
```

A type is a JSON type atom, `{:array, type}`, or a raw property-schema map.
Options include `:required`, `:description`, `:enum`, `:default`, `:pattern`,
the length, item, and numeric bounds, and `:schema` to merge any other JSON
Schema keywords.

An `:object` or `{:array, :object}` argument can take a `do` block of further
`argument` declarations. They become the properties of the object, or of each
array item, and blocks can nest. `output_schema` with a `do` block builds the
output schema from the same declarations:

```elixir
defmodule MyServer.Order do
  use Snodo.Tool.Simple, name: "order", description: "Place an order"

  argument "customer", :object, required: true do
    argument "id", :string, required: true
    argument "email", :string
  end

  argument "lines", {:array, :object},
    required: true,
    min_items: 1,
    additional_properties: false do
    argument "sku", :string, required: true
    argument "quantity", :integer, required: true, minimum: 1
  end

  output_schema do
    argument "order_id", :string, required: true
    argument "total", :number, required: true
  end

  @impl true
  def call(_arguments, _context) do
    {:ok, Snodo.Result.structured(%{"order_id" => "o-1", "total" => 12.5})}
  end
end
```

`required: true` inside a block adds the name to that object's `"required"`
list, so here `"customer"` requires `"id"` and each line requires `"sku"` and
`"quantity"`. The router enforces only the top-level `"required"` list on its
own; nested lists are enforced by an installed validator.

A block argument also takes `additional_properties:`, which is set on the
nested object. For an array that is the object in `"items"`, while the other
options, such as `min_items:`, stay on the array. A block argument's `schema:`
cannot set the keys the block generates (`"properties"` and `"required"`, or
`"items"`).

`output_schema` still accepts a map, as in `use Snodo.Tool`. The block form
takes `additional_properties:` and `schema:` for the output root in the same
keyword list as the block, as in
`output_schema(additional_properties: false, do: (...))`.

The result is the plain JSON Schema that `input_schema/1` and
`output_schema/1` accept, checked when the module compiles. A block on another
type, a repeated name inside a block, and a second output schema when either
one is a block are compile errors, and the messages name the nested path, such
as `argument "lines.sku"`. With an output schema, `call/2` must return
structured content, which the runtime's schema validator checks (see
[Validation](#validation)).

Tools can set `title:`, `icons:`, and `metadata:` on `use Snodo.Tool`,
`use Snodo.Tool.Simple`, or an inline `tool` block. Raw tools can also set
them with `title/1`, `icons/1`, and `metadata/1` in the module body. For example:

```elixir
use Snodo.Tool.Simple,
  name: "search",
  title: "Search packages",
  icons: [%{"src" => "https://example.com/search.png", "mimeType" => "image/png"}],
  metadata: %{"com.example/search" => %{"category" => "catalog"}}
```

Each icon needs an absolute URI `"src"`; `"mimeType"`, `"sizes"`, and
`"theme"` are optional. Metadata keys follow the MCP `_meta` key format, and
values must be JSON values. The 2025-06-18 dialect emits `title` and `_meta`;
2025-11-25 and 2026-07-28 also emit `icons`. Absent values are omitted.

`use Snodo.Tool` takes a hand-written schema instead, and can declare an output
schema and annotations:

```elixir
defmodule MyServer.Version do
  use Snodo.Tool, name: "version", description: "Latest version of a package"

  input_schema(%{
    "type" => "object",
    "properties" => %{"name" => %{"type" => "string"}},
    "required" => ["name"]
  })

  output_schema(%{"type" => "object", "properties" => %{"version" => %{"type" => "string"}}})

  @impl true
  def call(%{"name" => _name}, _context), do: {:ok, %{"version" => "1.2.3"}}
end
```

### Results and failures

| `call/2` returns | Client sees |
|---|---|
| `{:ok, binary}` | a text content result |
| `{:ok, value}` (any other JSON value) | structured content |
| `{:ok, %Snodo.Result{}}` | exactly that result, for example `Snodo.Result.text/2` with metadata |
| `{:ok, Snodo.Result.content(blocks)}` | the given content blocks, such as `"image"`, `"audio"`, or an embedded `"resource"` |
| `{:ok, Snodo.Result.error("hex.pm returned 503")}` | a result with `isError: true`: the tool ran and reports a failure the model can read |
| `{:error, %Snodo.Error{}}` | a JSON-RPC error: the request itself was wrong |
| `{:error, reason}` | a result with `isError: true`, for compatibility |

Use `isError` results for anything the tool understands, such as an upstream
failure or a lookup that found nothing. Reserve `Snodo.Error` for requests that
should never have been dispatched.

JSON values need string keys. `Snodo.JSONValue.encodable!/1` converts an
atom-keyed domain value.

### Validation

The router always checks the arguments listed in the schema's `required`.
Everything else in the schema is advertised but only enforced when the server
installs a validator:

| Validator | Coverage |
|---|---|
| `Snodo.Schema.Validator.Passthrough` (default) | none |
| `Snodo.Schema.Validator.Basic` | objects, arrays, primitives, `enum`, `const`, size and numeric bounds |
| `Snodo.Schema.Validator.JSV` from `snodo_jsv` | full JSON Schema 2020-12 |

Server runtimes compile their registered tool schemas once and retain them for
the runtime's lifetime. For direct validator calls, Basic compiles each
regular-expression pattern on first use and JSV compiles each schema on first
use. These direct calls share a 256-entry fallback cache while the `snodo`
application is running. The oldest fallback entry is evicted when it fills;
its next use compiles again. Validation behavior does not change.

A call that fails either check never reaches `call/2`. It gets a result with
`isError: true` and a message the model can act on, such as
`Missing required arguments: query` or
`Invalid arguments at /page: value is not one of the declared JSON types`,
following the 2026-07-28 tools specification. Messages name the location and
the rule, never the argument's value. Unknown tools and non-object `arguments`
remain JSON-RPC errors (-32602).

### Arguments in HTTP headers

A property marked with `x-mcp-header` is also sent as an `Mcp-Param-<Name>`
header over Streamable HTTP, so gateways and load balancers can route on it
without reading the body:

```elixir
input_schema(%{
  "type" => "object",
  "properties" => %{
    "region" => %{"type" => "string", "x-mcp-header" => "Region"},
    "query" => %{"type" => "string"}
  },
  "required" => ["region", "query"]
})
```

The name must be a non-empty HTTP token (letters, digits, and
``!#$%&'*+-.^_`|~``), unique ignoring case. The property's `type` must be
`"string"`, `"integer"`, or `"boolean"`, and the property must be reached from
the root through `properties` only, not inside `items`, `oneOf`, or `$defs`. A
tool that breaks these rules does not compile, or is refused by
`Snodo.Router.register_tool/2` if it implements the behaviour by hand.

Both HTTP listeners check the headers against the body before the tool runs. A
missing, mismatched, repeated, or malformed header gets HTTP 400 with
JSON-RPC error -32020. A null or absent argument needs no header. Values that
are not printable ASCII, or that have leading or trailing whitespace, arrive
base64-encoded as `=?base64?...?=`. Integers compare numerically. Stdio and
direct dispatch have no headers and ignore the annotation.

## Resources

A resource has an exact `:uri` or a `:uri_template`. A template in the
supported RFC 6570 shapes gets a generated matcher, and the matched variables
arrive in `read/2`'s params. `Snodo.Resource.Simple` accepts plain return
values:

```elixir
defmodule MyServer.PackageInfo do
  use Snodo.Resource.Simple,
    uri_template: "hex://{name}/info",
    name: "package_info",
    mime_type: "application/json"

  @impl true
  def read(%{"name" => name}, _context), do: {:ok, %{"name" => name}}
end
```

| `read/2` returns | Content |
|---|---|
| `{:ok, binary}` | text at the requested URI with the declared `mime_type` |
| `{:ok, value}` | JSON, `application/json` unless another `mime_type` is declared |
| `{:ok, %Snodo.Result{}}` | unchanged; use `Snodo.Result.resource_read/2` with `Snodo.Resource.text/3`, `json/3`, or `blob/3` for blobs, several contents, or metadata |
| `{:error, reason}` | a JSON-RPC error; use `Snodo.Error.invalid_params/2` for a missing resource |

`use Snodo.Resource` requires `read/2` to return a `Snodo.Result`.

### Template shapes

The generated matcher handles the RFC 6570 operators that can be matched
without ambiguity. `Snodo.Resource.Template` has the full rules.

| Template | Matches | Binds |
|---|---|---|
| `hex://{name}/info` | `hex://jason/info` | `name`: one whole, non-empty segment |
| `files://{root}/{+path}` | `files://docs/a/b.txt` | `path`: one or more segments, `"a/b.txt"` |
| `hex://{name}{/version}` | `hex://jason`, `hex://jason/1.4.0` | `version`: zero or one segment |
| `hex://{name}/docs{/page*}` | `hex://jason/docs`, `hex://jason/docs/a/b` | `page`: zero or more segments, `"a/b"` |
| `search://{index}{?q,lang}` | `search://hex`, `search://hex?lang=en&q=json` | `q`, `lang`: named query parameters, any order |
| `search://hex/pkgs{?q}{&sort}` | `search://hex/pkgs?q=js&sort=name` | `q`, `sort` |

- The scheme is a literal and matches case-insensitively. The authority is one
  literal, one `{var}`, or empty when a `/` follows it: `file:///{+path}`
  matches `file:///etc/hosts` and binds `path` to `"etc/hosts"`, but not
  `file://localhost/etc/hosts`.
- A template has at most one variable-length path expression (`{+var}`,
  `{/var}`, or `{/var*}`). The literal and `{var}` segments around it are
  matched from each end, so a URI splits only one way.
- An absent `{/var}`, `{/var*}`, or query parameter is left out of the params.
  `q=` binds `""`.
- A query parameter the template does not name, a repeated parameter, an empty
  query, a fragment, a port, or userinfo means the URI does not match. A
  template without query expressions matches no URI with a query.
- Values are percent-decoded once and must be valid UTF-8. `+` stays `+`. A
  variable that appears twice must bind the same value both times.

A template outside these shapes is a compile error that names the shape, for
example `fragment expansion ({#var})`, `a prefix modifier ({var:n})`, or `a
path segment that holds literal text and an expression, or two expressions`
for `v{version}`. Multi-variable path and simple expressions (`{/a,b}`,
`{a,b}`) are refused because a missing value cannot be assigned to one
variable. To serve such a template, implement `matches?/1` and return `true`,
`false`, or `{:ok, variables}`; the module then compiles.

A template is at most 1,024 bytes with at most 32 variables. Matching is
linear in the URI length, with no backtracking, so its cost is bounded by the
transport's message size limit.

### Overlapping templates

Two templates can both match one URI. `x://h/{+p}` and `x://h/docs{/page*}`
both match `x://h/docs/intro`. Registration does not detect this, because it
would mean comparing every pair of templates; it only checks direct URIs
against templates. A `resources/read` for such a URI fails with JSON-RPC error
-32603, "Multiple resource routes matched the requested URI". Give templates
distinct literal prefixes, or serve the overlapping shapes from one module.

### Values that name files

A matched value is decoded, so it can contain `/` (from `%2F`, or from the
segments `{+path}` and `{/page*}` join), can be or contain `..`, and can
contain a NUL byte (from `%00`). Dot segments are not removed. Before using a
value as a file path, refuse NUL bytes, then resolve it against the directory
being served and refuse anything that escapes it:

```elixir
def read(%{"path" => path}, _context) do
  root = "/srv/docs"

  with false <- String.contains?(path, <<0>>),
       {:ok, relative} <- Path.safe_relative(path, root) do
    File.read(Path.join(root, relative))
  else
    _unsafe -> {:error, Snodo.Error.invalid_params("Resource not found")}
  end
end
```

`Path.safe_relative/2` accepts a NUL byte, so the first check is needed.

For a single-segment `{var}` that should be a plain name, reject values that
contain `/`, `\`, or are `.` or `..`.

## Prompts

`Snodo.Prompt.Simple` declares arguments one per line, and `render/2` may
return a string for a single user message:

```elixir
defmodule MyServer.Review do
  use Snodo.Prompt.Simple, name: "review", description: "Review a package"

  argument "name", required: true, description: "Package name"
  argument "focus", description: "quality, security, or upgrade"

  @impl true
  def render(%{"name" => name} = arguments, _context) do
    {:ok, "Review #{name}, focusing on #{arguments["focus"] || "quality"}."}
  end
end
```

Prompt arguments are the flat string map MCP defines. The router checks
required arguments before `render/2` runs. For several messages, return them
built with `Snodo.Prompt.message/2` and the content builders (`text/2`,
`image/3`, `audio/3`, `embedded_resource/2`, `resource_link/3`). Return
`Snodo.Result.prompt_get/2` to add a description or metadata.

## Inline components

Inside a server, `tool`, `resource`, and `prompt` with a name and a `do` block
generate the module:

```elixir
defmodule Inline do
  use Snodo.Server, name: "inline", version: "0.1.0"

  tool "greet", description: "Create a greeting" do
    argument "name", :string, required: true

    @impl true
    def call(%{"name" => name}, _context), do: {:ok, "Hello, #{name}!"}
  end

  resource "groups", uri: "toolbox://groups", mime_type: "application/json" do
    @impl true
    def read(_params, _context), do: {:ok, %{"groups" => ["web", "data"]}}
  end

  tool MyServer.Search
end
```

The block is the body of `Inline.Tools.Greet` or `Inline.Resources.Groups`,
which uses the matching `Simple` module, so it can hold several clauses and
private helpers. The options are those of the `Simple` module without `:name`.
Two names that map to the same module are a compile error.

## Completion

Prompts and resource templates opt into argument completion with
`completion_arguments:` and a `complete/2` callback:

```elixir
defmodule MyServer.Lookup do
  use Snodo.Prompt.Simple,
    name: "lookup",
    completion_arguments: ["name"]

  argument "name", required: true

  @impl true
  def complete(%Snodo.Completion{argument: "name", value: prefix}, _context) do
    matches = Enum.filter(["jason", "plug", "phoenix"], &String.starts_with?(&1, prefix))
    {:ok, Snodo.Result.completion(matches, total: length(matches), has_more: false)}
  end

  @impl true
  def render(%{"name" => name}, _context), do: {:ok, "Look up #{name}."}
end
```

## Paging and cache hints

List operations page with opaque cursors (default page size 100, set with
`pagination: [page_size: n]`). Cursors are scoped to the exact catalog, so a
changed catalog expires outstanding cursors with -32602. Every list and read
result carries `ttlMs` and `cacheScope` from the `*_cache:` options.

## Examples

`examples/01_direct_tools.exs` (raw tools), `02_structured_schema.exs`,
`12_resources.exs`, `13_prompts.exs`, `14_completions.exs`,
`15_pagination.exs`, and `25_inline_components.exs`.
