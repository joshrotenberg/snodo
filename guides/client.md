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
with a -32000 error if a server repeats a cursor, or if the last of `:max_pages`
pages (1,000 by default) still has a `nextCursor`. `list_page/3` returns one
`Snodo.Client.Page` for manual paging:

```elixir
{:ok, %Snodo.Client.Page{items: tools, next_cursor: cursor}} = Snodo.Client.list_page(client, :tools)
{:ok, next} = Snodo.Client.list_page(client, :tools, cursor)
```

## Multi round-trip requests

A server that needs input returns `input_required` with `inputRequests` and,
sometimes, a `requestState`. A client without input handlers does not answer;
call again with the answers:

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

### Input handlers

Install `input_handlers:` to answer input requests inside the call. The map is
keyed by request kind, `:form` and `:url` for the two elicitation modes. A
handler is a function of one argument: it receives the request's `params`
(`"mode"`, `"message"`, and `"requestedSchema"` or `"url"`) and returns
`{:ok, response}`, where `response` is the elicitation result, or
`{:error, reason}`.

```elixir
{:ok, client} =
  Snodo.Client.connect({:http, url},
    input_handlers: %{
      form: fn %{"message" => message, "requestedSchema" => schema} ->
        {:ok, %{"action" => "accept", "content" => MyUI.ask(message, schema)}}
      end,
      url: fn %{"url" => url} ->
        MyUI.open(url)
        {:ok, %{"action" => "accept"}}
      end
    }
  )

{:ok, result} = Snodo.Client.call_tool(client, "deploy", %{})
```

The declared client capabilities follow the handlers: `:form` adds
`"elicitation" => %{"form" => %{}}` and `:url` adds `"url"` next to it, merged
with any `:client_capabilities` given. An explicit `"elicitation" => %{}` next
to a `:url` handler is kept as form. A declared entry the handlers need to
merge into must be a map; `"elicitation" => true` with a handler installed
raises `ArgumentError`. A server therefore does not ask for a kind the client
cannot answer.

When a result asks for input, the client first matches every request to a
handler and checks that its `params` carry the keys of its kind; only then
does it call the handlers, one at a time in the calling process, in the sort
order of the request IDs. It sends the request again, on a fresh request ID,
with the responses as `inputResponses` and the result's `requestState`
unchanged.
That repeats until the server returns a complete result or `:max_input_rounds`
results (10 by default) have been answered. A result that carries only a
`requestState` is sent again with it after 250 ms, as the official TypeScript
client does, and counts as a round. Each round has its own `timeout:`, and
`progress:` is delivered for every round.

| Condition | Return |
|---|---|
| no handlers installed, or `answer_input: false` on the call | `{:input_required, result}` |
| a request of a kind with no handler, or with a method the client does not know (no handler has run) | -32602, `kind: :protocol`, `cause: {:no_input_handler, kind, result}` |
| a handler returned `{:error, reason}`, or something other than `{:ok, response}` with a valid `"action"` | -32603, `kind: :execution`, `cause: {:input_handler, id, reason, result}` |
| the server still required input after `:max_input_rounds` rounds | -32000, `kind: :transport`, `data: %{"maxInputRounds" => n}`, `cause: {:max_input_rounds, result}` |
| a result with nothing to answer and no `requestState`, or an input request whose `params` is not a map or lacks `"message"` and `"requestedSchema"` (form) or `"message"` and `"url"` (URL); no handler has run | -32000, `kind: :transport`, `cause: result` |

A handler that raises stops the call with that exception. Each error carries
the last `input_required` result at the end of its `cause`, so the caller can
finish the flow by hand with `input_responses:` and `request_state:`.
Responses are not checked against `requestedSchema` on the client; the server
validates them and answers -32602 for an invalid one, as it does for a
hand-written response.

| Option | Applies to | Default | Meaning |
|---|---|---|---|
| `:input_handlers` | `direct/2`, `connect/2` | `%{}` | a map from `:form` or `:url` to a function of one argument |
| `:max_input_rounds` | `direct/2`, `connect/2`, each call | 10 | the most `input_required` results answered for one call |
| `:answer_input` | each call | `true` | `false` returns `{:input_required, result}` for this call |

## Progress

Pass `progress:` to a request to receive the server's
`notifications/progress` for it while it runs. The client sends the request ID
as `_meta.progressToken`. A function is called in the requesting process with
each notification's `params` before the request returns; a pid is sent
`{:snodo_progress, params}`.

```elixir
Snodo.Client.call_tool(client, "reindex", %{},
  progress: fn %{"progress" => done} = params ->
    IO.puts("#{done} of #{params["total"] || "?"}")
  end
)
```

`params` holds `"progressToken"`, `"progress"`, and, when the server sent them,
`"total"` and `"message"`. Passing a `"progressToken"` in `:meta` as well as
`progress:` raises `ArgumentError`.

A long request that keeps reporting progress can outlast its `timeout:`. With
`reset_timeout_on_progress: true`, each notification restarts the timeout,
and `max_total_timeout:` (600,000 ms by default) bounds the whole request from
when it was sent. A request stopped by that bound returns -32001 with the
message "Maximum total timeout exceeded" and `data` holding
`"maxTotalTimeoutMs"`.

| Option | Default | Meaning |
|---|---|---|
| `:progress` | none | a function of one argument, or a pid, for this request's progress |
| `:reset_timeout_on_progress` | `false` | restart `timeout:` at each progress notification |
| `:max_total_timeout` | 600,000 | the longest a request may run when its timeout is reset |

A direct client has no timeout; its handler runs in a linked task while the
calling process receives the progress reports.

## Options

| Option | Applies to | Meaning |
|---|---|---|
| `:client_capabilities` | all | capabilities sent with every request, plus those the input handlers imply |
| `:input_handlers`, `:max_input_rounds` | all | functions that answer input requests, and the round limit (see above) |
| `:client_info` | all | the `Implementation` sent as `io.modelcontextprotocol/clientInfo`; defaults to `%{"name" => "snodo", "version" => ...}` with this library's version |
| `:timeout` | all | default request timeout in milliseconds |
| `:auth` | `direct/2` | the value handlers and policies read as `context.auth` |
| `:protocol` | all | the protocol version; defaults to `2026-07-28` |
| `:max_pages` | all | the most pages a list function requests (1,000) |
| `:env`, `:cd` | stdio | environment and working directory for the command |
| `:max_line_bytes` | stdio | the largest response line to accept (16 MiB); the rest of a longer line is discarded and its request times out |
| `:headers`, `:ssl`, `:connect_timeout` | HTTP | extra headers, `:ssl` options (peers are verified against the OS trust store by default), connect timeout |
| `:token_provider` | HTTP | a `Snodo.Client.TokenProvider` as `{module, state}` that supplies the bearer token (see [Authorization](#authorization)) |
| `:max_response_bytes` | HTTP | the largest response to accept (16 MiB), checked as it arrives; a larger response closes the connection and returns -32000 |

`request/4` also accepts `:meta` for extra `_meta` entries.

## Transport behavior

- **Stdio.** One process owns the port and correlates responses by ID, and
  progress notifications by token. A timeout, or a progress function that
  raises, sends `notifications/cancelled` for that request. When the server exits,
  pending and later requests fail with -32000. The connection closes when the
  process that opened it exits. `close/1` closes the server's stdin.
- **HTTP.** One HTTP/1.1 POST per request, on a `:gen_tcp` or `:ssl`
  connection that closes when the request returns. The headers the
  protocol requires (`MCP-Protocol-Version`, `Mcp-Method`, `Mcp-Name`, and
  `Mcp-Param-*` for `x-mcp-header` arguments) come from
  the dialect's transport policy, the same declaration the server checks. JSON
  and event-stream responses are both accepted. An event stream is read as it
  arrives: progress notifications for the request are delivered as they come,
  and the request returns at the event that carries its response.

  `:max_response_bytes` is checked while the response arrives, for every
  status: a `Content-Length` over the limit is refused before the body is
  read, and a chunked or close-delimited body is refused at the read that
  passes the limit. An event stream counts as one body, notifications
  included. The error has `cause: {:max_response_bytes, limit}`.

  `Mcp-Param-*` headers need the tool's input schema, so pass the definition
  from `list_tools/1` to `call_tool/4` in place of the name. Called by name, a
  tool that needs them is refused with -32020; the client then lists the tools
  and retries once with the definition. `list_tools/1` over HTTP leaves out
  tools with an invalid `x-mcp-header` annotation and logs a warning for each.

  ```elixir
  {:ok, tools} = Snodo.Client.list_tools(client)
  search = Enum.find(tools, &(&1["name"] == "search"))
  {:ok, result} = Snodo.Client.call_tool(client, search, %{"region" => "eu", "query" => "json"})
  ```

`subscriptions/listen` streams are not delivered to the caller yet, and
`request/4` raises for `subscriptions/listen`.

## Authorization

A server over HTTP may require an OAuth 2.1 bearer token. A token the
application already holds goes in `headers:`. A token that has to be obtained,
refreshed, or extended comes from a `Snodo.Client.TokenProvider`, given as
`token_provider: {module, state}`:

- Before each request the transport asks the provider for a token and sends
  `Authorization: Bearer <token>` when it gets one. `{:ok, nil}` sends the
  request without one, which is how a client learns the server's challenge.
- After a `401`, or a `403` whose `WWW-Authenticate` challenge is
  `insufficient_scope`, the transport parses the challenge into a
  `Snodo.Client.Challenge` (`resource_metadata`, `scope`, `error`), asks the
  provider to refresh with it, and sends the request once more with the new
  token.
- A second `401` or `403` returns -32000 with
  `cause: {:unauthorized, status, challenge}`. A provider error is returned as
  it is. No token appears in an error.

`snodo_oauth` supplies `Snodo.OAuth.Client`, which implements the MCP
authorization flows on this behaviour: protected resource and authorization
server metadata discovery with issuer validation, client ID metadata
documents, dynamic client registration and pre-registered clients, PKCE,
resource indicators, scope selection and step-up, refresh tokens, and the
client credentials grant with `client_secret_basic`, `client_secret_post`, or
`private_key_jwt`.

```elixir
{:ok, oauth} =
  Snodo.OAuth.Client.start_link(
    resource: "https://mcp.example.com/mcp",
    authorize: fn url -> MyApp.open_browser(url) end
  )

{:ok, client} =
  Snodo.Client.connect({:http, "https://mcp.example.com/mcp"},
    token_provider: {Snodo.OAuth.Client, oauth}
  )
```

## Custom transports

Any module implementing `Snodo.Client.Transport` (`connect/2`, `request/3`,
`close/1`) can be passed as `{module, init_arg}` to `connect/2`. A transport
that ignores the `:on_progress` option delivers no progress.

## Examples

`examples/24_client_transports.exs` runs the same calls in process, over stdio,
and over HTTP.
