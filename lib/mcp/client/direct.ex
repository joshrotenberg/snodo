defmodule MCP.Client.Direct do
  @moduledoc """
  In-process transport for `MCP.Client.direct/2`.

  Each request runs `MCP.Server.dispatch/3` in the calling process with a
  `:direct` transport context, so `:timeout` does not apply.
  """

  @behaviour MCP.Client.Transport

  alias MCP.Server
  alias MCP.Server.Runtime
  alias MCP.Transport.Context, as: TransportContext

  @type state :: %{runtime: Runtime.t(), auth: term()}

  @impl true
  def connect(%Runtime{} = runtime, opts) do
    {:ok, %{runtime: runtime, auth: Keyword.get(opts, :auth)}}
  end

  @impl true
  def request(%{runtime: runtime} = state, message, opts) do
    dialect = Keyword.fetch!(opts, :dialect)

    transport = %TransportContext{
      transport: :direct,
      request_headers: %{"mcp-protocol-version" => dialect.version()},
      metadata: if(is_nil(state.auth), do: %{}, else: %{auth: state.auth})
    }

    # MCP.Client sends only requests and refuses subscriptions/listen, so
    # dispatch always returns a response map here.
    {:ok, response} = Server.dispatch(runtime, message, transport)
    {:ok, response}
  end

  @impl true
  def close(_state), do: :ok
end
