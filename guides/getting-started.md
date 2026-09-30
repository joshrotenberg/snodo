# Getting started

This guide builds a small MCP server, calls it in process, and serves it over
stdio and HTTP.

## Install

Add `snodo` to your dependencies:

<!-- x-release-please-start-version -->
```elixir
def deps do
  [
    {:snodo, "~> 0.3.1"}
  ]
end
```
<!-- x-release-please-end -->

For a Plug or Bandit application, also add `snodo_plug`:

<!-- x-release-please-start-version -->
```elixir
{:snodo_plug, "~> 0.3.1"}
```
<!-- x-release-please-end -->

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

## Test it

`Snodo.Test.Assertions` wraps the direct client in ExUnit assertions. Each
assertion returns the value it matched, and a failure shows the protocol
error or the tool's `isError` content:

```elixir
defmodule GreeterTest do
  use ExUnit.Case, async: true

  import Snodo.Test.Assertions

  alias Snodo.Client

  test "greets by name" do
    client = client!(Greeter.runtime())

    assert_listed(Client.list_tools(client), "greet")

    result = assert_tool_ok(Client.call_tool(client, "greet", %{"name" => "Ada"}))
    assert [%{"text" => "Hello, Ada!"}] = result["content"]

    assert_tool_error(Client.call_tool(client, "greet", %{}), "Missing required arguments")
    assert_refused(Client.call_tool(client, "wave"), -32_602)
  end
end
```

`assert_tool_error/2` matches a result with `"isError" => true`, optionally
by its text, and `assert_refused/2` matches a JSON-RPC error, optionally by
its code. Had `greet` been called without a name under `assert_tool_ok/1`,
the failure would read:

```text
Expected a successful tool result, got isError: true
content:
    Missing required arguments: name
```

The other helpers:

- `assert_input_required/2` matches an `input_required` result, optionally of
  one kind (`:form`, `:url`, `:sampling`, or `:roots`). `answer_input/2` turns
  answers keyed by kind or request ID into the `input_responses:` and
  `request_state:` options of the retry. `client!/2` with `answers:` answers
  every input request inside the call instead.
- `client_as/3` builds a client whose requests carry a principal as
  `context.auth`, for testing an authorization policy, with
  `assert_refused/2` and `refute_listed/2`.

The assertions also accept what `Snodo.Test.dispatch/2` returns.

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
For a Phoenix endpoint, follow the [router and Bandit setup](transports.md#phoenix-endpoint).

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
