defmodule MCP.Test do
  @moduledoc "In-process request helpers for component and protocol tests."

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
      metadata: Keyword.get(opts, :transport_metadata, %{})
    }

    Server.dispatch(runtime, raw, transport)
  end

  defp put_protocol_metadata(runtime, params, version, capabilities) do
    {:ok, protocol} = Registry.fetch(runtime.protocol_registry, version)

    metadata =
      protocol.request_metadata(capabilities)
      |> Map.merge(Map.get(params, "_meta", %{}))

    Map.put(params, "_meta", metadata)
  end
end
