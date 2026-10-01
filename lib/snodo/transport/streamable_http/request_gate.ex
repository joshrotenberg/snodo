defmodule Snodo.Transport.StreamableHTTP.RequestGate do
  @moduledoc """
  Request admission for the native Streamable HTTP listener.

  A gate sees the parsed request method, path, and headers before the body is
  read. It can serve a separate route, refuse a request with an HTTP response,
  or return trusted request identity for `Snodo.Authorization`. The listener
  does not interpret credentials. A gate that raises or returns an invalid
  result fails closed with HTTP 500.

  Configure `{module, options}` as the listener's `:request_gate` option. The
  module is initialized once at listener startup with the listener's endpoint
  path in `%{path: path}`. `check/2` runs in each
  connection's admission task and is bounded by `:request_gate_timeout`.
  External calls should also have their own bounds and cleanup on timeout.
  """

  alias Snodo.Transport.StreamableHTTP.Request
  alias Snodo.Transport.StreamableHTTP.Response

  @callback init(keyword(), %{path: String.t()}) :: term()
  @callback check(Request.t(), term()) :: {:ok, term()} | {:response, Response.t()}
end
