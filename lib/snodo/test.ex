defmodule Snodo.Test do
  @moduledoc """
  In-process request helpers for component and protocol tests.

  When `protocol:` is supplied, `dispatch/2` adds that dialect's required
  request metadata, including protocol version and client capabilities. A real
  client must send these fields itself. Use `Snodo.Server.dispatch/3` with literal
  request maps, transport tests, and an independent client to test wire admission;
  passing component tests alone does not establish transport interoperability.
  """

  alias Snodo.Protocol.Registry
  alias Snodo.Server
  alias Snodo.Server.Runtime
  alias Snodo.Transport.Context, as: TransportContext

  @doc """
  Builds one JSON-RPC request and dispatches it with `Snodo.Server.dispatch/3`
  over the `:direct` transport.

  Options:

    * `:method` - the JSON-RPC method. Required.
    * `:params` - the request params. Defaults to `%{}`.
    * `:id` - the request ID. Defaults to `1`.
    * `:protocol` - a protocol version enabled in `runtime`. When set, the
      dialect's request metadata is added to `params["_meta"]` (keys already
      in `params["_meta"]` win) and the `mcp-protocol-version` header is set.
      A version the runtime does not enable raises `MatchError`. Defaults to
      `nil`, which adds neither.
    * `:client_capabilities` - the client capabilities put in the metadata
      when `:protocol` is set. Defaults to `%{}`.
    * `:transport_metadata` - the transport context metadata, for example
      `%{auth: principal}`, which handlers read as `context.auth`. Defaults
      to `%{}`.

  Returns what `Snodo.Server.dispatch/3` returns: `{:ok, response}` with the
  JSON-RPC response map, or `{:stream, subscription}` for
  `subscriptions/listen`.

      {:ok, %{"result" => result}} =
        Snodo.Test.dispatch(MyServer.runtime(),
          method: "tools/call",
          params: %{"name" => "echo", "arguments" => %{"text" => "hi"}},
          protocol: "2026-07-28"
        )
  """
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
