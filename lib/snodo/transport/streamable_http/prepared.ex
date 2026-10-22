defmodule Snodo.Transport.StreamableHTTP.Prepared do
  @moduledoc """
  An HTTP request that passed admission in `Snodo.Transport.StreamableHTTP.prepare/3`,
  ready for `Snodo.Transport.StreamableHTTP.execute/3`.
  """

  alias Snodo.Transport.Context, as: TransportContext
  alias Snodo.Transport.Policy

  @enforce_keys [:raw, :transport, :protocol, :kind, :policy]
  defstruct [:raw, :transport, :protocol, :kind, :policy, :deferred_error]

  # `deferred_error` holds a tool parameter header failure for a runtime that
  # conceals refused components. It is answered in `execute/3`, once the
  # caller's identity is known, so the answer cannot reveal a concealed tool.
  @type t :: %__MODULE__{
          raw: map(),
          transport: TransportContext.t(),
          protocol: module(),
          kind: :request | :notification,
          policy: Policy.t(),
          deferred_error: {:http_error, pos_integer(), Snodo.Error.t(), term()} | nil
        }
end
