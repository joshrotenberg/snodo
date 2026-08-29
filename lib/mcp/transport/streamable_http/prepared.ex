defmodule MCP.Transport.StreamableHTTP.Prepared do
  @moduledoc false

  alias MCP.Transport.Context, as: TransportContext
  alias MCP.Transport.Policy

  @enforce_keys [:raw, :transport, :protocol, :kind, :policy]
  defstruct [:raw, :transport, :protocol, :kind, :policy]

  @type t :: %__MODULE__{
          raw: map(),
          transport: TransportContext.t(),
          protocol: module(),
          kind: :request | :notification,
          policy: Policy.t()
        }
end
