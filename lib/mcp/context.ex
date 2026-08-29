defmodule MCP.Context do
  @moduledoc "Immutable request-scoped protocol, transport, auth, and tracing context."

  alias MCP.Transport.Context, as: TransportContext

  @type t :: %__MODULE__{
          protocol_version: String.t(),
          protocol: module(),
          client_info: map() | nil,
          client_capabilities: map(),
          server_info: map(),
          server_capabilities: map(),
          session: term() | nil,
          auth: map() | nil,
          transport: TransportContext.t(),
          request_id: MCP.Envelope.id(),
          cancellation: term() | nil,
          progress: term() | nil,
          extensions: map(),
          extension_options: %{optional(String.t()) => keyword() | map()},
          metadata: map()
        }

  @enforce_keys [:protocol_version, :protocol, :transport]
  defstruct [
    :protocol_version,
    :protocol,
    :client_info,
    :server_info,
    :session,
    :auth,
    :transport,
    :request_id,
    :cancellation,
    :progress,
    client_capabilities: %{},
    server_capabilities: %{},
    extensions: %{},
    extension_options: %{},
    metadata: %{}
  ]
end
