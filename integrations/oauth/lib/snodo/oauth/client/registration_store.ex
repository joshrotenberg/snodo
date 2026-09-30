defmodule Snodo.OAuth.Client.RegistrationStore do
  @moduledoc """
  Behaviour for where `Snodo.OAuth.Client` keeps the client identities it
  obtained through dynamic client registration (RFC 7591).

  Entries are keyed by the authorization server's issuer identifier, so a
  registration is never presented to another authorization server. A value
  is a map:

      %{client_id: "...", client_secret: "..." | nil,
        token_endpoint_auth_method: "none" | "client_secret_basic" | "client_secret_post",
        issuer: "https://auth.example.com", redirect_uri: "http://127.0.0.1:49152/callback",
        response: %{...}}

  `response` is the registration response as the server sent it. The
  default, `Snodo.OAuth.Client.RegistrationStore.Memory`, keeps entries in the client's
  state. A persistent store lets a client reuse its registration across
  restarts; the client registers again when the stored redirect URI no
  longer matches its own. The loopback listener takes an OS-assigned port by
  default, so reuse across restarts needs a fixed `:port` in the
  `:redirect` option.
  """

  @type state :: term()
  @type key :: String.t()
  @type value :: map()

  @doc "Prepares the store from the `{module, arg}` given to the client."
  @callback init(arg :: term()) :: {:ok, state()}

  @doc "Returns the registration stored under `key`, or `:error` when there is none."
  @callback fetch(state(), key()) :: {:ok, value()} | :error

  @doc "Stores `value` under `key`, replacing any earlier value."
  @callback put(state(), key(), value()) :: {:ok, state()}

  @doc "Removes `key`. Removing a key that is not there succeeds."
  @callback delete(state(), key()) :: {:ok, state()}
end
