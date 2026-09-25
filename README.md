# snodo

An Elixir library for building [Model Context Protocol](https://modelcontextprotocol.io)
servers and clients. It speaks MCP `2026-07-28`, with opt-in support for
initialize-era HTTP clients (`2025-11-25` and `2025-06-18`).

`snodo` is pre-release and not yet published to Hex. The API may change.

- **Servers** from inline blocks or ordinary modules, served over stdio, a
  built-in Streamable HTTP listener, or Plug and Bandit.
- **A client** that calls any MCP server in process, over stdio, or over HTTP.
- **The 2026-07-28 surface:** discovery, tools, resources and templates,
  prompts, completion, pagination, `subscriptions/listen`, progress,
  cancellation, and multi round-trip requests with elicitation.
- **No runtime dependencies** in the core: it uses Elixir's built-in `JSON`
  and OTP. Optional sibling packages add Tasks, Plug, and full JSON Schema
  validation.

## Packages

| Package | Path | Adds |
|---|---|---|
| `snodo` | `.` | Protocol core, router, server DSL, client, stdio and HTTP transports |
| `snodo_plug` | `integrations/plug` | `Snodo.Transport.Plug` for Plug and Bandit applications |
| `snodo_jsv` | `integrations/schema_jsv` | Full JSON Schema 2020-12 validation through JSV |
| `snodo_tasks` | `extensions/tasks` | The `io.modelcontextprotocol/tasks` extension with an application-owned store and runner |
| `snodo_tasks_postgres` | `extensions/tasks_postgres` | PostgreSQL store for Tasks |
| `snodo_tasks_sqlite` | `extensions/tasks_sqlite` | SQLite store for Tasks |

Until the packages are published, depend on the repository. `snodo_plug`
brings `snodo` with it:

```elixir
{:snodo, github: "joshrotenberg/snodo"}
{:snodo_plug, github: "joshrotenberg/snodo", subdir: "integrations/plug"}
```

Elixir 1.18 or later is required.

## Quick start

A server with one tool, one resource template, and one prompt:

```elixir
defmodule Greeter do
  use Snodo.Server, name: "greeter", version: "0.1.0"

  tool "greet", description: "Create a greeting" do
    argument "name", :string, required: true

    @impl true
    def call(%{"name" => name}, _context), do: {:ok, "Hello, #{name}!"}
  end

  resource "profile", uri_template: "people://{name}/profile", mime_type: "application/json" do
    @impl true
    def read(%{"name" => name}, _context), do: {:ok, %{"name" => name}}
  end

  prompt "introduce", description: "Introduce someone" do
    argument "name", required: true

    @impl true
    def render(%{"name" => name}, _context), do: {:ok, "Introduce #{name} in one sentence."}
  end
end
```

Call it in process with `Snodo.Client`:

```elixir
{:ok, client} = Snodo.Client.direct(Greeter.runtime())

{:ok, [%{"name" => "greet"}]} = Snodo.Client.list_tools(client)
{:ok, result} = Snodo.Client.call_tool(client, "greet", %{"name" => "Ada"})
result["content"]
#=> [%{"type" => "text", "text" => "Hello, Ada!"}]
```

Serve it over stdio from a script or release:

```elixir
:ok = Snodo.Transport.Stdio.serve(Greeter.runtime())
```

or over HTTP, supervised:

```elixir
children = [{Snodo.Transport.StreamableHTTP.Server, runtime: Greeter.runtime(), port: 4000}]
```

The same client connects to either:

```elixir
{:ok, client} = Snodo.Client.connect({:stdio, "elixir", ["greeter.exs"]})
{:ok, client} = Snodo.Client.connect({:http, "http://127.0.0.1:4000/mcp"})
```

## Guides

- [Getting started](guides/getting-started.md)
- [Tools, resources, and prompts](guides/components.md)
- [The client](guides/client.md)
- [Transports](guides/transports.md)
- [Choosing packages for an application](guides/application-stack.md)
- [Interactive operations (MRTR and elicitation)](guides/interactive-operations.md)
- [Subscriptions](guides/subscriptions.md)
- [Authorization](guides/authorization.md)
- [Extensions and Tasks](guides/extensions.md)
- [Instrumentation](guides/instrumentation.md)
- [Initialize-era clients](guides/initialize-era-clients.md)
- [Supported Elixir, OTP, and databases](guides/compatibility.md)
- [Protocol compliance](guides/protocol-compliance.md)

The [examples](https://github.com/joshrotenberg/snodo/blob/main/examples/README.md) are runnable scripts, each checked in CI.

## Protocol support

`2026-07-28` is the default and only required dialect. For clients that still
send `initialize`, enable the older dialects on the server:

```elixir
use Snodo.Server,
  name: "greeter",
  version: "0.1.0",
  protocols: [Snodo.Protocol.V2026_07_28, Snodo.Protocol.V2025_11_25, Snodo.Protocol.V2025_06_18]
```

They cover tools, resources, prompts, completion, and pagination over stateless
HTTP. They add no session storage.

Against the frozen official conformance suite, 32 of 37 `2026-07-28` server
scenarios pass. The [compliance guide](guides/protocol-compliance.md) lists
what is measured and what is not. Design records from the project's history are
in [docs/history](https://github.com/joshrotenberg/snodo/blob/main/docs/history/README.md).

## Development

```sh
mix quality          # format, compile, Credo, tests, examples, and every sibling package
mix quality.types    # Dialyzer across all six packages
mix snodo.contract   # the protocol contract inventory
```

Conformance and interop checks against the official TypeScript client live in
`conformance/` and `interop/`, and run in CI.

## License

MIT. See [LICENSE](https://github.com/joshrotenberg/snodo/blob/main/LICENSE).
