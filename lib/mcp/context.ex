defmodule MCP.Context do
  @moduledoc """
  Immutable request-scoped protocol, transport, auth, and tracing context.

  MRTR retries are new requests, not suspended handlers. `input_responses`
  contains the client's bare input results and `request_state` is untrusted
  opaque client input. Use `MCP.Elicitation.response/3` to consume a named
  answer and `MCP.MRTR.State` to protect state that affects business logic.
  `request_method` and `request_params` preserve the incoming operation for
  request-bound state verification; tool and prompt arguments remain unchanged.
  """

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
          request_method: String.t() | nil,
          request_params: map(),
          request_state: String.t() | nil,
          input_responses: map(),
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
    :request_method,
    :request_state,
    :cancellation,
    :progress,
    client_capabilities: %{},
    request_params: %{},
    input_responses: %{},
    server_capabilities: %{},
    extensions: %{},
    extension_options: %{},
    metadata: %{}
  ]
end
