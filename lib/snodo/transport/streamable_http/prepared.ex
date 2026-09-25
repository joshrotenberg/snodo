defmodule Snodo.Transport.StreamableHTTP.Prepared do
  @moduledoc """
  An HTTP request that passed admission in `Snodo.Transport.StreamableHTTP.prepare/3`,
  ready for `Snodo.Transport.StreamableHTTP.execute/3`.
  """

  alias Snodo.Transport.Context, as: TransportContext
  alias Snodo.Transport.Policy

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
