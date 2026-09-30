defmodule Snodo.Client.Session do
  @moduledoc """
  The initialize-era session a `Snodo.Client` negotiated.

  `Snodo.Client.connect/2` and `Snodo.Client.direct/2` fill it in after a
  successful `initialize` and `notifications/initialized` on a 2025-11-25 or
  2025-06-18 connection. On a 2026-07-28 connection the client's `session` is
  `nil`: that protocol has no handshake, and `Snodo.Client.discover/1` returns
  the server's capabilities and instructions instead.

    * `version` - the negotiated protocol version, the same as the client's
      `protocol`.
    * `id` - the `Mcp-Session-Id` the server issued with the `initialize`
      response, or `nil`. Over HTTP the client sends it with every later
      request and in the `DELETE` that `Snodo.Client.close/1` issues.
    * `server_info`, `server_capabilities`, `instructions` - from the
      `initialize` result, as the server sent them.
  """

  @type t :: %__MODULE__{
          version: String.t(),
          id: String.t() | nil,
          server_info: map(),
          server_capabilities: map(),
          instructions: String.t() | nil
        }

  @enforce_keys [:version]
  defstruct [:version, :id, :instructions, server_info: %{}, server_capabilities: %{}]
end
