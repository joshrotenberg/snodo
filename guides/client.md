# The client

`Snodo.Client` calls MCP servers. The same functions work over three
connections:

```elixir
# A runtime in this VM: no process or transport in between
{:ok, client} = Snodo.Client.direct(MyServer.runtime())

# A subprocess speaking newline-delimited JSON-RPC on stdin and stdout
{:ok, client} = Snodo.Client.connect({:stdio, "elixir", ["my_server.exs"]}, env: [{"LOG_LEVEL", "warn"}])

# A Streamable HTTP endpoint
{:ok, client} = Snodo.Client.connect({:http, "https://example.test/mcp"}, headers: [{"authorization", "Bearer " <> token}])
```

The client speaks MCP `2026-07-28`. Initialize-era servers are not supported.

## Calls

```elixir
{:ok, discovery} = Snodo.Client.discover(client)
{:ok, tools} = Snodo.Client.list_tools(client)
{:ok, result} = Snodo.Client.call_tool(client, "search", %{"query" => "json"})
{:ok, result} = Snodo.Client.read_resource(client, "hex://jason/info")
{:ok, result} = Snodo.Client.get_prompt(client, "review", %{"name" => "jason"})
{:ok, result} = Snodo.Client.request(client, "completion/complete", params)
:ok = Snodo.Client.close(client)
```

Every call returns one of:

| Return | Meaning |
|---|---|
| `{:ok, result}` | the JSON-RPC `result` object as sent, with string keys. A tool result with `"isError" => true` is a successful response and arrives here |
| `{:input_required, result}` | the server needs more input; retry the same call with answers (below) |
| `{:error, %Snodo.Error{}}` | a JSON-RPC error, or a failure of the connection |

Decoded JSON-RPC errors keep the server's `code`, `message`, and `data`.
Connection failures have `kind: :transport`: -32000 for a closed, unreachable,
or unusable connection and -32001 for a timeout, the codes the official
TypeScript SDK uses. Each request can set `timeout:` (the default is 30 seconds,
or the client's `:timeout` option).

Request IDs are fresh integers, so one client can be shared by many processes.

## Lists and paging

`list_tools/1`, `list_resources/1`, `list_resource_templates/1`, and
`list_prompts/1` follow `nextCursor` to the end and return every item. They stop
with an error if a server repeats a cursor. `list_page/3` returns one
`Snodo.Client.Page` for manual paging:

```elixir
{:ok, %Snodo.Client.Page{items: tools, next_cursor: cursor}} = Snodo.Client.list_page(client, :tools)
{:ok, next} = Snodo.Client.list_page(client, :tools, cursor)
```

## Multi round-trip requests

A server that needs input returns `input_required` with `inputRequests` and,
sometimes, a `requestState`. The client does not answer automatically; call
again with the answers:

```elixir
{:ok, client} = Snodo.Client.direct(runtime, client_capabilities: %{"elicitation" => %{"form" => %{}}})

{:input_required, %{"inputRequests" => requests} = pending} =
  Snodo.Client.call_tool(client, "deploy", %{})

answers = %{"confirm" => %{"action" => "accept", "content" => %{"approved" => true}}}

Snodo.Client.call_tool(client, "deploy", %{},
  input_responses: answers,
  request_state: pending["requestState"]
)
```

See [Interactive operations](interactive-operations.md) for the server side.

## Options

| Option | Applies to | Meaning |
|---|---|---|
| `:client_capabilities` | all | capabilities sent with every request |
| `:timeout` | all | default request timeout in milliseconds |
| `:auth` | `direct/2` | the value handlers and policies read as `context.auth` |
| `:protocol` | all | the protocol version; defaults to `2026-07-28` |
| `:env`, `:cd` | stdio | environment and working directory for the command |
| `:headers`, `:ssl`, `:connect_timeout` | HTTP | extra headers, `:ssl` options (peers are verified against the OS trust store by default), connect timeout |

`request/4` also accepts `:meta` for extra `_meta` entries such as a
`progressToken`.

## Transport behavior

- **Stdio.** One process owns the port and correlates responses by ID. A timeout
  sends `notifications/cancelled` for that request. When the server exits,
  pending and later requests fail with -32000. The connection closes when the
  process that opened it exits. `close/1` closes the server's stdin.
- **HTTP.** One POST per request through OTP's `:httpc`. The headers the
  protocol requires (`MCP-Protocol-Version`, `Mcp-Method`, `Mcp-Name`) come from
  the dialect's transport policy, the same declaration the server checks. JSON
  and event-stream responses are both accepted; progress notifications in a
  stream are skipped.

Progress notifications and `subscriptions/listen` streams are not delivered to
the caller yet, and `request/4` raises for `subscriptions/listen`.

## Custom transports

Any module implementing `Snodo.Client.Transport` (`connect/2`, `request/3`,
`close/1`) can be passed as `{module, init_arg}` to `connect/2`.

## Examples

`examples/24_client_transports.exs` runs the same calls in process, over stdio,
and over HTTP.
