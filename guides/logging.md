# Logging

A request handler can send log messages to the client as
`notifications/message`, with `Snodo.Logging.log/4`. The client chooses the
lowest level it wants; the server drops anything below it.

## Server

Advertise the `"logging"` capability, then log from a handler:

```elixir
defmodule MyServer do
  use Snodo.Server,
    name: "my-server",
    version: "1.0.0",
    capabilities: %{"tools" => %{}, "logging" => %{}}

  tool "import", description: "Imports rows" do
    @impl true
    def call(_arguments, context) do
      :ok = Snodo.Logging.log(context, :info, "Import started", logger: "importer")
      rows = 120
      :ok = Snodo.Logging.log(context, :debug, %{"rows" => rows})
      {:ok, "Imported #{rows} rows"}
    end
  end
end
```

`level` is one of `Snodo.Logging.levels/0`, from `:debug` to `:emergency`
(the RFC 5424 severities). `data` is any JSON value. `logger:` names the
source of the message.

`log/4` returns `:ok` when the message was written and also when it was
dropped on purpose: the runtime does not advertise `"logging"`, the message is
below the request's level, the request has no level, or the transport has no
channel for notifications. It returns `{:error, reason}` for invalid input
(`:invalid_level`, `:invalid_data`, `:invalid_logger`, `:too_large`) and when
the request can no longer take messages (`:closed`, `:cancelled`,
`:limit_reached`, `:timeout`, `:wrong_process`).

Log messages share the request's notification channel with
`Snodo.Progress.report/3`. They are written before the request's result, one at
a time, and each `log/4` call returns after the transport has written the
message. Over HTTP the response switches to an event stream at the first
message, as it does for progress. A request may send at most 1,000 messages,
each with at most 16 KiB of encoded `data`. Only the process that runs the
request may log; `Snodo.Component.Wrap.Timeout` hands that right to its task.

## Which messages reach the client

| Revision | The client sets the level with | Without a level |
|---|---|---|
| 2026-07-28 | `_meta["io.modelcontextprotocol/logLevel"]` on each request | no messages |
| 2025-11-25, 2025-06-18 over stdio | `logging/setLevel`, for the rest of the connection | the runtime's `:log_level` |
| 2025-11-25, 2025-06-18 over HTTP | `logging/setLevel` is answered with `{}` but keeps no state, since these dialects keep no session | the runtime's `:log_level` |

The runtime's `:log_level` option defaults to `:info`. The initialize-era
specifications let a server choose what to send until the client sets a level;
2026-07-28 does not, so `:log_level` has no effect there.

```elixir
Snodo.Server.Runtime.new(router: router, capabilities: capabilities, log_level: :warning)
```

## Client

`Snodo.Client` takes `:on_log`, a function of one argument or a pid, and
delivers each `notifications/message` `params` map to it. A pid is sent
`{:snodo_log, params}`. `:log_level` asks for messages at or above a level.

```elixir
{:ok, client} =
  Snodo.Client.connect({:http, url},
    log_level: :info,
    on_log: fn %{"level" => level, "data" => data} -> IO.inspect({level, data}) end
  )

{:ok, _result} = Snodo.Client.call_tool(client, "import", %{}, log_level: :debug)
```

On 2026-07-28 the client sends `:log_level` with every request, and a request
can override it with `log_level:` (`nil` asks for none). On an
initialize-era connection the level is set with `Snodo.Client.set_log_level/2`,
which sends `logging/setLevel`; on 2026-07-28 it returns -32601 without
sending anything.

A log message carries no request ID. Over HTTP and on a direct client each
request delivers its own messages to `:on_log`, in the requesting process,
before the request returns. Over stdio a message goes to one of the requests
in flight on the connection, which need not be the one whose handler logged
when several are in flight.

`:on_log` can also be set per request, as an option to `Snodo.Client.request/4`
and the functions built on it. It replaces the client's function for that
request, and `on_log: nil` drops the request's messages.

```elixir
{:ok, _result} =
  Snodo.Client.call_tool(client, "import", %{},
    log_level: :debug,
    on_log: fn params -> send(self(), {:import_log, params}) end
  )
```

## Proxy

`Snodo.Proxy` advertises `"logging"` and forwards a backend's
`notifications/message` to the caller of the original request, before its
result. The caller's level is passed to a 2026-07-28 backend, and each message
is logged again on the caller's request with `log/4`, so messages below the
caller's level are dropped and a request without a level gets none. An
initialize-era backend sets its level per connection with `logging/setLevel`,
which the proxy does not send.
