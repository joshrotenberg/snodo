defmodule MCP.Client.Transport do
  @moduledoc """
  Behaviour for the connection underneath `MCP.Client`.

  A transport moves one complete JSON-RPC request to a server and returns the
  complete JSON-RPC response. `MCP.Client` builds the request and decodes the
  response, so a transport never interprets `result` or `error`.

  `request/3` receives these options:

    * `:timeout` - milliseconds to wait for the response.
    * `:dialect` - the protocol dialect module that built the request. HTTP
      uses its `transport_policy/1` to derive headers.

  Failures of the connection itself are `%MCP.Error{kind: :transport}`. Use
  `connection_error/2` (-32000) and `timeout_error/1` (-32001), the codes the
  official TypeScript SDK uses for the same client-side conditions.
  """

  alias MCP.Error

  @type state :: term()

  @callback connect(init_arg :: term(), opts :: keyword()) :: {:ok, state()} | {:error, Error.t()}
  @callback request(state(), message :: map(), opts :: keyword()) ::
              {:ok, map()} | {:error, Error.t()}
  @callback close(state()) :: :ok

  @connection_closed -32_000
  @request_timeout -32_001

  @doc "The connection is closed, unreachable, or produced an unusable response."
  @spec connection_error(String.t(), term()) :: Error.t()
  def connection_error(message, cause) when is_binary(message) do
    %Error{code: @connection_closed, message: message, kind: :transport, cause: cause}
  end

  @doc "No response arrived within `timeout` milliseconds."
  @spec timeout_error(timeout()) :: Error.t()
  def timeout_error(timeout) do
    %Error{
      code: @request_timeout,
      message: "Request timed out",
      kind: :transport,
      data: %{"timeoutMs" => timeout},
      cause: :timeout
    }
  end
end
