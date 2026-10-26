# snodo_otp

GenServer calls and casts over MCP, on top of `Snodo.Tool.GenServer`.

One contract module declares a GenServer's remote operations. The server side
serves them as MCP tools; the client side runs a local process that stands in
for the remote GenServer, so application code keeps `GenServer.call/3` and
`GenServer.cast/2`.

## Installation

<!-- x-release-please-start-version -->
```elixir
def deps do
  [
    {:snodo, "~> 0.4.2"},
    {:snodo_otp, "~> 0.4.2"}
  ]
end
```
<!-- x-release-please-end -->

## Contract

`Snodo.OTP.Contract` is a behaviour. `ops/0` lists the operations, each with a
`name`, a `kind` (`:call` or `:cast`), an `input_schema`, and optionally an
`output_schema`, a `description`, and a `timeout`. The server side implements
`build_message/2` (JSON arguments to the GenServer message) and
`encode_reply/2` (the reply to a JSON object). The client side implements
`encode_call/1` and `encode_cast/1` (a message to a tool name and JSON
arguments, or `:nomatch`) and `decode_reply/2`.

```elixir
defmodule CounterContract do
  @behaviour Snodo.OTP.Contract

  @by %{
    "type" => "object",
    "properties" => %{"by" => %{"type" => "integer"}},
    "required" => ["by"],
    "additionalProperties" => false
  }
  @value %{
    "type" => "object",
    "properties" => %{"value" => %{"type" => "integer"}},
    "required" => ["value"]
  }

  @impl true
  def ops do
    [
      %{name: "counter_add", kind: :call, input_schema: @by, output_schema: @value},
      %{name: "counter_cast_add", kind: :cast, input_schema: @by}
    ]
  end

  @impl true
  def build_message(_name, %{"by" => by}), do: {:add, by}

  @impl true
  def encode_reply(_name, count), do: %{"value" => count}

  @impl true
  def encode_call({:add, by}), do: {"counter_add", %{"by" => by}}
  def encode_call(_message), do: :nomatch

  @impl true
  def encode_cast({:add, by}), do: {"counter_cast_add", %{"by" => by}}
  def encode_cast(_message), do: :nomatch

  @impl true
  def decode_reply(_name, %{"value" => count}), do: count
end
```

Nothing is inferred: an operation exists because the contract names it, so a
client never chooses a process, atom, or term.

## Server

`Snodo.OTP.Server.expose/2` emits one `genserver_call` or `genserver_cast`
declaration per operation inside a `Snodo.Server`:

```elixir
defmodule CounterServer do
  use Snodo.Server, name: "counter", version: "1.0.0"
  import Snodo.OTP.Server

  expose(CounterContract, target: Counter)
end
```

## Client

`Snodo.OTP.Proxy` is a GenServer that stands in for the remote one:

```elixir
{:ok, counter} = Snodo.OTP.Proxy.start_link(url: url, contract: CounterContract)
GenServer.call(counter, {:add, 2})
GenServer.cast(counter, {:add, 3})
```

Requests go out one at a time, in the order the proxy receives them, so casts
arrive in order and a call sees every cast sent before it, as in OTP. The
remote GenServer handles one message at a time anyway; requests do not overlap
on the wire.

Failures follow OTP where the wire allows it:

- The caller's `GenServer.call/3` timeout governs; a result that arrives after
  the caller gave up is dropped.
- A call the remote side timed out (the adapter's `:timeout`, or the proxy's
  `:request_timeout`, default 60,000 ms) is answered `{:error, :timeout}`.
- A call to a remote target that is not running stops the proxy with
  `:noproc`, so a monitor receives `DOWN` and a supervisor can restart it. A
  cast to it is dropped, as in OTP.
- A request whose process crashes, for example on arguments JSON cannot
  encode, is answered `{:error, {:request_failed, reason}}`; a reply
  `decode_reply/2` does not match is answered
  `{:error, {:decode_failed, name, json}}`. Later requests still run.
- A connection failure stops the proxy with `{:nodedown, url}`. An HTTP error
  status, such as 401 or 404, is answered `{:error, error}` and the proxy keeps
  running.
- A message the contract does not know stops the proxy with
  `{:function_clause, message}`.

`:connect` passes options through to `Snodo.Client.connect/2`, merged over
`protocol: "2026-07-28"` and `timeout: 15_000`, for example
`connect: [token_provider: provider]`.

The proxy has no pid for the remote process and no link to it, and it sees a
remote failure only when a call reaches it.
