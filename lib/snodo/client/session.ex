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
    * `validity` - internal, opaque state shared by copies of an HTTP session.
    * `server_info`, `server_capabilities`, `instructions` - from the
      `initialize` result, as the server sent them.
  """

  alias Snodo.Client.Transport
  alias Snodo.Error

  @type t :: %__MODULE__{
          version: String.t(),
          id: String.t() | nil,
          server_info: map(),
          server_capabilities: map(),
          instructions: String.t() | nil,
          validity: :atomics.atomics_ref() | nil
        }

  @enforce_keys [:version]
  defstruct [:version, :id, :instructions, :validity, server_info: %{}, server_capabilities: %{}]

  @doc "Returns whether the client has observed that the session was lost."
  @spec lost?(t() | nil) :: boolean()
  def lost?(%__MODULE__{validity: nil}), do: false
  def lost?(%__MODULE__{validity: validity}), do: :atomics.get(validity, 1) == 1
  def lost?(nil), do: false

  @doc false
  @spec invalidate(t() | nil) :: :ok
  def invalidate(%__MODULE__{validity: nil}), do: :ok
  def invalidate(%__MODULE__{validity: validity}), do: :atomics.put(validity, 1, 1)
  def invalidate(nil), do: :ok

  @doc false
  @spec check(t() | nil) :: :ok | {:error, Error.t()}
  def check(session) do
    if lost?(session), do: lost_error(), else: :ok
  end

  @doc false
  @spec lost_error() :: {:error, Error.t()}
  def lost_error do
    {:error, Transport.connection_error("The HTTP session was lost", :session_not_found)}
  end
end
