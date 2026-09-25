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

## Tools

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
| `{:ok, Snodo.Result.error("hex.pm returned 503")}` | a result with `isError: true`: the tool ran and reports a failure the model can read |
| `{:error, %Snodo.Error{}}` | a JSON-RPC error: the request itself was wrong |
| `{:error, reason}` | a result with `isError: true`, for compatibility |

Use `isError` results for anything the tool understands, such as an upstream
failure or a lookup that found nothing. Reserve `Snodo.Error` for requests that
should never have been dispatched.

JSON values need string keys. `Snodo.JSONValue.encodable!/1` converts an
atom-keyed domain value.

### Validation

The router always rejects a call missing an argument listed in the schema's
`required`. Everything else in the schema is advertised but only enforced when
the server installs a validator:

| Validator | Coverage |
|---|---|
| `Snodo.Schema.Validator.Passthrough` (default) | none |
| `Snodo.Schema.Validator.Basic` | objects, arrays, primitives, `enum`, `const`, size and numeric bounds |
| `Snodo.Schema.Validator.JSV` from `snodo_jsv` | full JSON Schema 2020-12 |

## Resources

A resource has an exact `:uri` or a `:uri_template`. Templates in the simple
`scheme://{var}/literal` shape get a generated matcher, and the matched
variables arrive in `read/2`'s params. `Snodo.Resource.Simple` accepts plain
return values:

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

`use Snodo.Resource` requires `read/2` to return a `Snodo.Result`. For a
template outside the simple shape, implement `matches?/1` and return `true`,
`false`, or `{:ok, variables}`.

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
