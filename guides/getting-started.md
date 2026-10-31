# Getting started

This guide builds a small MCP server, calls it in process, and serves it over
stdio and HTTP.

## Install

Add `snodo` to your dependencies:

<!-- x-release-please-start-version -->
```elixir
def deps do
  [
    {:snodo, "~> 0.4.5"}
  ]
end
```
<!-- x-release-please-end -->

For a Plug or Bandit application, also add `snodo_plug`:

<!-- x-release-please-start-version -->
```elixir
{:snodo_plug, "~> 0.4.5"}
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

### Over stdio

An MCP host such as Claude Code, Claude Desktop, or Codex launches a stdio
server as a subprocess and talks to it on stdin and stdout. The smallest
runnable server is a script that installs `snodo` itself:

<!-- x-release-please-start-version -->
```elixir
# greeter.exs
Mix.install([{:snodo, "~> 0.4.5"}])

defmodule Greeter do
  use Snodo.Server,
    name: "greeter",
    version: "0.4.5",
    protocols: [
      Snodo.Protocol.V2026_07_28,
      Snodo.Protocol.V2025_11_25,
      Snodo.Protocol.V2025_06_18
    ]

  tool "greet", description: "Create a greeting" do
    argument "name", :string, required: true

    @impl true
    def call(%{"name" => name}, _context), do: {:ok, "Hello, #{name}!"}
  end
end

:ok = Snodo.Transport.Stdio.serve(Greeter.runtime())
```
<!-- x-release-please-end -->

Run it with `-noinput`, which lets the transport bound each input line (see
[Transports](transports.md#stdio)):

```sh
elixir --erl -noinput greeter.exs
```

The first run downloads and compiles `snodo`; later runs reuse the
`Mix.install` cache.

`protocols:` enables the initialize-era versions next to 2026-07-28, because
hosts differ: some probe with 2026-07-28, others still send `initialize` with
2025-11-25 or 2025-06-18. See
[Initialize-era clients](initialize-era-clients.md).

In a Mix project, compile first so compiler output never reaches the host's
stdout, then serve the module from the project directory:

```sh
mix compile
elixir --erl -noinput -S mix run --no-compile -e "Snodo.Transport.Stdio.serve(MyApp.MCPServer.runtime())"
```

A release can do the same from a command that starts the application and then
calls `Snodo.Transport.Stdio.serve/2`; put `-noinput` in `vm.args`.

### Registering with a host

Hosts start the command themselves, from their own working directory, so use
absolute paths. With Claude Code:

```sh
claude mcp add greeter -- elixir --erl -noinput /path/to/greeter.exs
```

Hosts that read a JSON configuration, such as Claude Desktop's
`claude_desktop_config.json`, take the same command and arguments:

```json
{
  "mcpServers": {
    "greeter": {
      "command": "elixir",
      "args": ["--erl", "-noinput", "/path/to/greeter.exs"]
    }
  }
}
```

### Over HTTP

In an application, supervise the server. `use Snodo.Server` defines a
`child_spec/1` that starts the server's transports under one supervisor and
gives each the server's runtime:

```elixir
children = [
  {Greeter, transports: [{Snodo.Transport.StreamableHTTP.Server, port: 4000}]}
]
```

The endpoint is `http://127.0.0.1:4000/mcp`. Other options to the child are
runtime overrides, as for `Greeter.runtime/1`, and `:supervisor_name` names
the supervisor.

Which HTTP transport to use:

- The native listener above has no dependencies. Use it for a standalone
  server or a local tool. It serves plaintext HTTP/1.1 and binds to loopback
  by default; put it behind a TLS reverse proxy if other hosts reach it.
- Inside an existing Plug or Phoenix application, or when you want Bandit's
  TLS and connection controls, use `snodo_plug`. See
  [Transports](transports.md), and for Phoenix the
  [router and Bandit setup](transports.md#phoenix-endpoint).

The same client connects to either:

```elixir
{:ok, client} = Snodo.Client.connect({:stdio, "elixir", ["--erl", "-noinput", "greeter.exs"]})
{:ok, client} = Snodo.Client.connect({:http, "http://127.0.0.1:4000/mcp"})
```

## Next

- [Tools, resources, and prompts](components.md)
- [The client](client.md)
- [Transports](transports.md)
- The [examples](https://github.com/joshrotenberg/snodo/blob/main/examples/README.md), each a runnable script
