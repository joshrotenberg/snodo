# Getting started

This guide builds a small MCP server, calls it in process, and serves it over
stdio and HTTP.

## Install

`snodo` is not on Hex yet. Depend on the repository:

```elixir
def deps do
  [
    {:snodo, github: "joshrotenberg/snodo"}
  ]
end
```

For a Plug or Bandit application, depend on `snodo_plug` instead, which brings
`snodo` with it:

```elixir
{:snodo_plug, github: "joshrotenberg/snodo", subdir: "integrations/plug"}
```

Elixir 1.18 or later is required. The core has no runtime dependencies.

## Define a server

A server module declares its components. Small ones can be written inline:

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

Each block becomes a module (`Greeter.Tools.Greet`, `Greeter.Resources.Profile`,
`Greeter.Prompts.Introduce`). Larger components are ordinary modules registered
with `tool MyApp.Search`. See [Tools, resources, and prompts](components.md).

Arguments arrive as the protocol sends them, with string keys. A tool that
returns `{:ok, binary}` produces text content; any other value becomes
structured content.

## Call it in process

`Snodo.Client.direct/2` dispatches to the server in the calling process, which
is the quickest way to try a server and to test one:

```elixir
{:ok, client} = Snodo.Client.direct(Greeter.runtime())

{:ok, tools} = Snodo.Client.list_tools(client)
{:ok, result} = Snodo.Client.call_tool(client, "greet", %{"name" => "Ada"})
result["content"]
#=> [%{"type" => "text", "text" => "Hello, Ada!"}]

{:ok, %{"contents" => [content]}} = Snodo.Client.read_resource(client, "people://ada/profile")
{:ok, %{"messages" => [message]}} = Snodo.Client.get_prompt(client, "introduce", %{"name" => "Ada"})
```

See [The client](client.md) for errors, multi round-trip requests, and paging.

## Serve it

Over stdio, for clients that launch the server as a subprocess:

```elixir
# greeter.exs, or a release command
:ok = Snodo.Transport.Stdio.serve(Greeter.runtime())
```

Over HTTP, supervised in an application:

```elixir
children = [
  {Snodo.Transport.StreamableHTTP.Server, runtime: Greeter.runtime(), port: 4000}
]
```

The endpoint is `http://127.0.0.1:4000/mcp`. For an existing Plug or Phoenix
application, use `snodo_plug` instead. See [Transports](transports.md).

The same client connects to either:

```elixir
{:ok, client} = Snodo.Client.connect({:stdio, "elixir", ["greeter.exs"]})
{:ok, client} = Snodo.Client.connect({:http, "http://127.0.0.1:4000/mcp"})
```

## Next

- [Tools, resources, and prompts](components.md)
- [The client](client.md)
- [Transports](transports.md)
- The [examples](https://github.com/joshrotenberg/snodo/blob/main/examples/README.md), each a runnable script
