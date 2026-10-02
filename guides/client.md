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

The client speaks the protocol versions the server serves: `2026-07-28`,
and the initialize-era `2025-11-25` and `2025-06-18`. `connect/2` settles the
version before it returns; see [Protocol versions](#protocol-versions).

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

## Protocol versions

`:protocol` names one version, or lists the versions to allow. Without it the
client allows every version it speaks, newest first:

```elixir
{:ok, client} = Snodo.Client.connect({:http, url})                              # negotiate
{:ok, client} = Snodo.Client.connect({:http, url}, protocol: "2025-11-25")      # pin
{:ok, client} = Snodo.Client.connect({:http, url}, protocol: ["2026-07-28", "2025-06-18"])
```

When the allowed versions span both eras, `connect/2` probes with
`server/discover` under `:probe_timeout` (10 seconds by default). A result
with `supportedVersions` is a 2026-07-28 server's answer, and the highest
allowed version the server lists wins. Any other answer, whatever the error
code or shape, and a timeout, mean the server does not speak a stateless
version: the client closes and reopens the transport, then sends `initialize`
with the highest allowed initialize-era version. On stdio, reopening starts
the server again, because the probe may already have been processed under the
older lifecycle rules, which some servers apply to the first request they
see. A pin, or a list from one era, skips the probe: a stateless pin sends
nothing at connect time and an initialize-era pin sends `initialize` at once.

`initialize` carries `:client_capabilities` and `:client_info`, and the
server's `protocolVersion` must be one the client allows; otherwise the client
closes the connection and returns -32602 with `negotiated` and `requested` in
`data`. `notifications/initialized` follows, and the client's `session` is
then a `Snodo.Client.Session` with the negotiated version, the `Mcp-Session-Id`
the server issued (if any), and the `serverInfo`, `capabilities`, and
`instructions` from the result. A server that supports none of the allowed
versions is a -32602 error with `requested` and `supported` in `data`, and a
version the client does not speak at all is refused before connecting.

`direct/2` needs no probe: the runtime's enabled versions are known, so the
highest allowed one among them is used, and an initialize-era version is
negotiated through the runtime the same way. A runtime that enables only the
legacy dialects gets a working direct client.

On an initialize-era connection:

- Requests carry no `_meta` metadata and no client info; those belong to
  2026-07-28. Over HTTP every later request carries `MCP-Protocol-Version`
  and, when issued, `Mcp-Session-Id`, and `close/1` sends a `DELETE` for the
  session before closing.
- `ping/1` works; `discover/1` is refused, because those versions do not
  define `server/discover`. The capabilities are in `session`.
- `request/4` refuses a method the negotiated dialect's catalog does not
  define as a client request, with -32601 before anything is sent. The
  catalogs are the protocol dialect modules' profiles, the same ones the
  server admits requests against, so the client and the server stay in
  step. On 2026-07-28 a method the catalog lists only as a server request or
  a notification is refused the same way, and an unlisted method is sent as
  it is, because negotiated extensions add methods the core catalog does not
  carry.
- The requests the server sends to the client (`elicitation/create`,
  `sampling/createMessage`, and `roots/list`) are answered by the same
  `:input_handlers` that answer 2026-07-28 input requests, keyed by method
  and mode: a form elicitation goes to `:form`, a URL elicitation to `:url`,
  a sampling request to `:sampling`, and a roots request to `:roots`. A
  server `ping` is answered without a handler. A request of a kind with no
  handler is answered -32601, one whose `params` lack the kind's keys -32602,
  and a handler that fails -32603. Over HTTP such a request arrives on the
  event stream of the request in flight, the handler runs in the calling
  process, and the answer goes back as its own `POST`. The time the handler
  takes counts against that request's timeout, which is not extended. Over
  stdio the connection process runs each handler in a linked process of its
  own and writes the answer, with at most `:max_server_requests` (16)
  handlers running at once; a request over the limit is answered -32603
  without running a handler, and handlers still running when the connection
  closes are killed. A handler that raises is answered -32603 on stdio, and
  on HTTP the exception propagates to the caller as it does for an embedded
  request.
- The catalog check applies to the requests the client sends. The server
  requests above are answered on any connection, whatever the negotiated
  version. The initialize-era catalogs do not list them, and 2026-07-28
  replaces them with input requests, but a 2026-07-28 connection over stdio,
  or over HTTP with input handlers installed, answers a server `ping` with
  `{}` and passes an elicitation, sampling, or roots request to the handlers.
  Such a request is outside the multi round-trip flow, so
  `:max_input_rounds` does not count it.
- Versions before 2025-06-18 are not spoken. The client does not open the
  standalone `GET` event stream, so a request a server sends only there (the
  TypeScript SDK does this for requests made without a related request ID)
  is not received; and a session the server expires is reported as the
  server's error rather than re-initialized.

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
keyed by request kind. A handler is a function of one argument: it receives
the request's `params` and returns `{:ok, response}`, where `response` is the
result the kind expects, or `{:error, reason}`.

| Kind | Embedded request | Handler receives | Handler returns | Declares |
|---|---|---|---|---|
| `:form` | `elicitation/create`, mode `form` | `"mode"`, `"message"`, `"requestedSchema"` | an elicitation result: `"action"` of `"accept"`, `"decline"`, or `"cancel"`, with `"content"` when accepted | `"elicitation" => %{"form" => %{}}` |
| `:url` | `elicitation/create`, mode `url` | `"mode"`, `"message"`, `"url"` | an elicitation result | `"elicitation" => %{"url" => %{}}` |
| `:sampling` | `sampling/createMessage` | `"messages"`, `"maxTokens"`, and whichever other `CreateMessageRequestParams` fields the server sent | a `CreateMessageResult`: `"role"`, `"content"`, `"model"`, optional `"stopReason"` | `"sampling" => %{}` |
| `:roots` | `roots/list` | `%{}`, or `"_meta"` when the server sent it | a `ListRootsResult`: `"roots"` with `file://` `"uri"` entries and optional names | `"roots" => %{"listChanged" => false}` |

SEP-2577 deprecates the server-initiated sampling and roots requests in
2026-07-28; the protocol still defines them, and servers built on this library
can send them (see [Interactive operations](interactive-operations.md)). A
`:sampling` handler that accepts `"tools"` and `"toolChoice"`, or an
`"includeContext"` other than `"none"`, declares `"sampling" => %{"tools" =>
%{}}` or `%{"context" => %{}}` in `:client_capabilities`; the client does not
infer those settings from the handler, so a server that needs them is refused
by the dialect with `-32021` until they are declared. What a sampling handler
returns is model output the server will treat as input; what a roots handler
returns is a claim about this client's file system, and the handler chooses
which roots to reveal.

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
      end,
      sampling: fn %{"messages" => messages, "maxTokens" => max_tokens} ->
        {:ok, text, model} = MyModel.complete(messages, max_tokens: max_tokens)
        {:ok, %{"role" => "assistant", "content" => %{"type" => "text", "text" => text}, "model" => model}}
      end,
      roots: fn _params ->
        {:ok, %{"roots" => [%{"uri" => "file:///home/me/project", "name" => "project"}]}}
      end
    }
  )

{:ok, result} = Snodo.Client.call_tool(client, "deploy", %{})
```

The declared client capabilities follow the handlers, merged with any
`:client_capabilities` given: `:form` adds `"elicitation" => %{"form" =>
%{}}`, `:url` adds `"url"` next to it, `:sampling` adds `"sampling" => %{}`,
and `:roots` adds `"roots" => %{"listChanged" => false}`. A declared value
wins where the two meet: `"sampling" => %{"tools" => %{}}` keeps its setting
and a declared `"listChanged"` replaces the handler's `false`. An explicit
`"elicitation" => %{}` next to a `:url` handler is kept as form. A declared
entry the handlers need to merge into must be a map; `"elicitation" => true`
with a form handler installed, or `"roots" => true` with a roots handler,
raises `ArgumentError`. Without a handler, nothing declares `sampling` or
`roots`. A server therefore does not ask for a kind the client cannot
answer.

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
| a handler returned `{:error, reason}`, something other than `{:ok, response}`, or a response that is not valid for its kind (`reason` is `{:invalid_response, response}`): an elicitation result without a valid `"action"`, a sampling result that is not a `CreateMessageResult`, or a roots result that is not a `ListRootsResult` | -32603, `kind: :execution`, `cause: {:input_handler, id, reason, result}` |
| the server still required input after `:max_input_rounds` rounds | -32000, `kind: :transport`, `data: %{"maxInputRounds" => n}`, `cause: {:max_input_rounds, result}` |
| a result with nothing to answer and no `requestState`, or an input request whose `params` is not a map or lacks `"message"` and `"requestedSchema"` (form), `"message"` and `"url"` (URL), or `"messages"` and `"maxTokens"` (sampling); a roots request may leave `params` out. No handler has run | -32000, `kind: :transport`, `cause: result` |

A handler that raises stops the call with that exception. Each error carries
the last `input_required` result at the end of its `cause`, so the caller can
finish the flow by hand with `input_responses:` and `request_state:`.
Elicitation responses are not checked against `requestedSchema` on the
client; the server validates them and answers -32602 for an invalid one, as
it does for a hand-written response. A sampling or roots response is checked
for its result shape with `Snodo.Sampling.valid_response?/1` or
`Snodo.Roots.valid_response?/1` before it is sent, so a handler bug is a
-32603 error on the client rather than a -32602 from the server.

| Option | Applies to | Default | Meaning |
|---|---|---|---|
| `:input_handlers` | `direct/2`, `connect/2` | `%{}` | a map from `:form`, `:url`, `:sampling`, or `:roots` to a function of one argument |
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

## Subscriptions

`listen/3` opens a `subscriptions/listen` stream. It sends the filter as given
(the core keys, and any key a negotiated extension defines, such as the Tasks
extension's `taskIds`) and returns once the server's
`notifications/subscriptions/acknowledged` arrives. The handle carries the
filter the server accepted, which may be a subset of the request:

```elixir
{:ok, subscription} =
  Snodo.Client.listen(client, %{
    "toolsListChanged" => true,
    "resourceSubscriptions" => ["file:///notes.md"]
  })

subscription.accepted
#=> %{"toolsListChanged" => true, "resourceSubscriptions" => ["file:///notes.md"]}
```

The calling process owns the subscription. Events reach it as
`{:snodo_subscription, ref, payload}` messages, where `ref` is
`subscription.ref` and the payload is one of:

| Payload | Meaning |
|---|---|
| `{:notification, method, params}` | one event, as sent: `method` is `"notifications/resources/updated"`, one of the three list-changed methods, or an extension's such as `"notifications/tasks"`; `params` keeps `"_meta"` |
| `{:dropped, n}` | `n` events were discarded because the buffer was full; sent just before the next delivered event, in addition to it, and takes no demand of its own |
| `{:closed, :complete}` | the server ended the stream with its terminal result |
| `{:closed, {:error, %Snodo.Error{}}}` | the server ended the stream with an error, or the connection failed; nothing follows |

Events are sent only while the owner has asked for them.
`Snodo.Client.Subscription.demand/2` asks for `n` more; `next/2` asks for one
and waits for it; `stream/1` wraps `next/2` as an `Enumerable` that ends with
the `{:closed, reason}` element. Each unit of demand pays for exactly one
event; `{:dropped, n}` and `{:closed, reason}` take none. A `next/2` call that
returns `{:dropped, n}` leaves the event its demand paid for in the mailbox,
and the following call returns it:

```elixir
subscription
|> Snodo.Client.Subscription.stream()
|> Enum.each(fn
  {:notification, "notifications/resources/updated", %{"uri" => uri}} -> reload(uri)
  {:notification, "notifications/tools/list_changed", _params} -> refresh_tools()
  {:dropped, n} -> Logger.warning("missed #{n} events")
  {:closed, reason} -> Logger.info("stream ended: #{inspect(reason)}")
end)
```

A GenServer asks for a batch and asks again as it consumes:

```elixir
def handle_info({:snodo_subscription, ref, {:notification, method, params}}, %{sub: %{ref: ref}} = state) do
  :ok = Snodo.Client.Subscription.demand(state.sub, 1)
  {:noreply, apply_change(state, method, params)}
end

# A drop report takes no demand, so there is nothing to renew.
def handle_info({:snodo_subscription, ref, {:dropped, _n}}, %{sub: %{ref: ref}} = state) do
  {:noreply, resync(state)}
end
```

Events that arrive without demand wait in the transport process, at most
`:max_buffer` of them (100 by default). When the buffer is full, `:overflow`
decides: `:drop_oldest` (the default) discards the oldest queued event,
`:drop_newest` discards the arriving one. The count reaches the owner as
`{:dropped, n}`. The terminal `{:closed, reason}` is delivered after the
queued events, so the owner sees every event it asks for before the end.

`Snodo.Client.Subscription.close/1` ends the stream, and so does the owner's
exit: stdio sends `notifications/cancelled`, HTTP closes the connection, and
the direct client closes the source. No message follows `close/1`; events
already delivered stay in the mailbox. `next/2` on a stream that has ended,
after its `{:closed, reason}` or after `close/1`, returns
`{:closed, {:error, %Snodo.Error{}}}` at once over every transport.

`listen/3` returns `{:error, %Snodo.Error{}}` for a JSON-RPC error response
(-32601 from a server without a subscription source, -32602 for an invalid
filter), for a stream the server ends before acknowledging it, and for a
transport failure; -32001 when the acknowledgement does not arrive within
`timeout:`. `request/4` raises for `subscriptions/listen`.

| Option | Default | Meaning |
|---|---|---|
| `:max_buffer` | 100 | the most events held for the owner before the overflow policy applies |
| `:overflow` | `:drop_oldest` | `:drop_oldest` or `:drop_newest` |
| `:timeout` | the client's | how long to wait for the acknowledgement |

## Options

| Option | Applies to | Meaning |
|---|---|---|
| `:client_capabilities` | all | capabilities sent with every request, plus those the input handlers imply |
| `:input_handlers`, `:max_input_rounds` | all | functions that answer input requests, and the round limit (see above) |
| `:client_info` | all | the `Implementation` sent as `io.modelcontextprotocol/clientInfo`; defaults to `%{"name" => "snodo", "version" => ...}` with this library's version |
| `:timeout` | all | default request timeout in milliseconds |
| `:auth` | `direct/2` | the value handlers and policies read as `context.auth` |
| `:protocol` | all | a version to pin, or a list to allow; defaults to every version the client speaks (see above) |
| `:probe_timeout` | `connect/2` | milliseconds to wait for the answer to the `server/discover` probe (10,000) |
| `:max_pages` | all | the most pages a list function requests (1,000) |
| `:env`, `:cd` | stdio | environment and working directory for the command |
| `:max_line_bytes` | stdio | the largest response line to accept (16 MiB); the rest of a longer line is discarded and its request times out |
| `:max_server_requests` | stdio | the most server-to-client requests whose handlers run at once (16); a request over the limit is answered -32603 |
| `:headers`, `:ssl`, `:connect_timeout` | HTTP | extra headers, `:ssl` options (peers are verified against the OS trust store by default), connect timeout |
| `:token_provider` | HTTP | a `Snodo.Client.TokenProvider` as `{module, state}` that supplies the bearer token (see [Authorization](#authorization)) |
| `:max_response_bytes` | HTTP | the largest response to accept (16 MiB), checked as it arrives; a larger response closes the connection and returns -32000 |
| `:max_buffer`, `:overflow` | `listen/3` | the subscription's buffer bound (100) and overflow policy (`:drop_oldest`) |

`request/4` and `listen/3` also accept `:meta` for extra `_meta` entries.
Pass `trace_context: %{"traceparent" => value, "tracestate" => value}` on a
call to send W3C trace fields through `_meta`. `tracestate` is optional; the
client checks the values and rejects malformed ones with `ArgumentError`.
The named option wins over duplicate keys in `:meta`.

## Transport behavior

- **Stdio.** One process owns the port and correlates responses by ID, and
  progress notifications by token. A timeout, or a progress function that
  raises, sends `notifications/cancelled` for that request. When the server exits,
  pending and later requests fail with -32000. The connection closes when the
  process that opened it exits. `close/1` closes the server's stdin. A request
  the server sends to the client is answered through the input handlers in a
  process linked to the connection, at most `:max_server_requests` at once,
  and those processes are killed when the connection closes.

  Subscriptions share the connection. The connection process correlates the
  acknowledgement, the events, and the terminal response by the subscription
  ID in each notification's `_meta`, and monitors each subscription's owner.
  When the server exits, or `close/1` stops the connection, open subscriptions
  end with `{:closed, {:error, ...}}` (-32000).
- **HTTP.** One HTTP/1.1 POST per request, on a `:gen_tcp` or `:ssl`
  connection that closes when the request returns. The headers the
  protocol requires (`MCP-Protocol-Version`, `Mcp-Method`, `Mcp-Name`, and
  `Mcp-Param-*` for `x-mcp-header` arguments) come from
  the dialect's transport policy, the same declaration the server checks. JSON
  and event-stream responses are both accepted. An event stream is read as it
  arrives: progress notifications for the request are delivered as they come,
  and the request returns at the event that carries its response.

  A subscription keeps its event-stream response open in a process of its own
  (`subscription.pid`), which exits when the stream ends. Closing the
  subscription closes that connection, which the server treats as
  cancellation. `close/1` on the client does not affect open subscriptions.

  `:max_response_bytes` is checked while the response arrives, for every
  status: a `Content-Length` over the limit is refused before the body is
  read, and a chunked or close-delimited body is refused at the read that
  passes the limit. An event stream that answers a request counts as one
  body, notifications included; a subscription stream is checked one event at
  a time. The error has `cause: {:max_response_bytes, limit}`.
- **Direct.** A subscription is dispatched in a process of its own, which
  serves the server-side subscription as a server transport would and closes
  the source when the stream ends. `close/1` on the client does not affect
  open subscriptions.

  On an initialize-era session the requests carry `MCP-Protocol-Version` and
  `Mcp-Session-Id` instead of the 2026-07-28 headers, `notifications/initialized`
  is a `POST` answered with 202, a request the server sends on the event
  stream is answered on its own `POST`, and `close/1` sends `DELETE`.

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

## Authorization

A server over HTTP may require an OAuth 2.1 bearer token. A token the
application already holds goes in `headers:`. A token that has to be obtained,
refreshed, or extended comes from a `Snodo.Client.TokenProvider`, given as
`token_provider: {module, state}`:

- Before each request, including the one that opens a `listen/3` stream, the
  transport asks the provider for a token and sends
  `Authorization: Bearer <token>` when it gets one. `{:ok, nil}` sends the
  request without one, which is how a client learns the server's challenge.
  On an initialize-era connection the same applies to `initialize`, to
  `notifications/initialized` and each answer to a server request, and to
  the `DELETE` that ends the session.
- After a `401`, or a `403` whose `WWW-Authenticate` challenge is
  `insufficient_scope`, the transport parses the challenge into a
  `Snodo.Client.Challenge` (`resource_metadata`, `scope`, `error`), asks the
  provider to refresh with it, and sends the request once more with the new
  token.
- A second `401` or `403` returns -32000 with
  `cause: {:unauthorized, status, challenge}`. A provider error is returned as
  it is. No token appears in an error.
- The request's `timeout:` covers each HTTP attempt, not the provider call
  before or between them. A provider that runs an authorization flow can
  hold a request for as long as the user takes to authorize, up to the
  provider's own limit (`Snodo.OAuth.Client` waits 300 seconds by default).

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
that ignores the `:on_progress` option delivers no progress. `listen/3` is
optional; `Snodo.Client.listen/3` raises `ArgumentError` for a transport
without it. The optional `notify/3` sends `notifications/initialized`, so a
transport without it can open 2026-07-28 connections only; the optional
`delete_session/2` ends a session the server identified. The `:headers`,
`:on_response_headers`, and `:on_server_request` options carry the
initialize-era session, as the behaviour documents.

## Examples

`examples/24_client_transports.exs` runs the same calls in process, over stdio,
and over HTTP.
