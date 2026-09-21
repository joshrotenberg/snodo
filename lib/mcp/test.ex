defmodule MCP.Test do
  @moduledoc """
  In-process request helpers for component and protocol tests.

  When `protocol:` is supplied, `dispatch/2` adds that dialect's required
  request metadata, including protocol version and client capabilities. A real
  client must send these fields itself. Use `MCP.Server.dispatch/3` with literal
  request maps, transport tests, and an independent client to test wire admission;
  passing component tests alone does not establish transport interoperability.
  """

  alias MCP.Protocol.Registry
  alias MCP.Server
  alias MCP.Server.Runtime
  alias MCP.Transport.Context, as: TransportContext

  @spec dispatch(Runtime.t(), keyword()) :: Server.dispatch_result()
  def dispatch(%Runtime{} = runtime, opts) when is_list(opts) do
    params = Keyword.get(opts, :params, %{})

    params =
      case Keyword.get(opts, :protocol) do
        nil ->
          params

        version ->
          put_protocol_metadata(
            runtime,
            params,
            version,
            Keyword.get(opts, :client_capabilities, %{})
          )
      end

    raw = %{
      "jsonrpc" => "2.0",
      "id" => Keyword.get(opts, :id, 1),
      "method" => Keyword.fetch!(opts, :method),
      "params" => params
    }

    transport = %TransportContext{
      transport: :direct,
      request_headers: protocol_headers(opts),
      metadata: Keyword.get(opts, :transport_metadata, %{})
    }

    Server.dispatch(runtime, raw, transport)
  end

  defp protocol_headers(opts) do
    case Keyword.get(opts, :protocol) do
      nil -> %{}
      version -> %{"mcp-protocol-version" => version}
    end
  end

  defp put_protocol_metadata(runtime, params, version, capabilities) do
    {:ok, protocol} = Registry.fetch(runtime.protocol_registry, version)

    metadata =
      protocol.request_metadata(capabilities)
      |> Map.merge(Map.get(params, "_meta", %{}))

    Map.put(params, "_meta", metadata)
  end
end
