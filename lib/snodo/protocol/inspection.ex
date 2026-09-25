defmodule Snodo.Protocol.Inspection do
  @moduledoc "The successful result of exact-profile MCP admission inspection."

  alias Snodo.Envelope
  alias Snodo.Protocol.Profile
  alias Snodo.Protocol.Profile.Method

  @type classification :: :implemented | :unsupported | :extension

  @type t :: %__MODULE__{
          profile: Profile.t(),
          envelope: Envelope.t(),
          method: Method.t() | nil,
          direction: :client_to_server | :server_to_client,
          classification: classification()
        }

  @enforce_keys [:profile, :envelope, :direction, :classification]
  defstruct [:profile, :envelope, :method, :direction, :classification]
end
