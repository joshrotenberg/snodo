defmodule Snodo.OAuth.Client.TokenStore do
  @moduledoc """
  Behaviour for where `Snodo.OAuth.Client` keeps the tokens it obtained.

  Entries are keyed by the canonical resource URL. A value is a map:

      %{access_token: "...", token_type: "bearer", expires_at: 1_700_000_000 | nil,
        refresh_token: "..." | nil, scopes: ["mcp:read"], issuer: "https://auth.example.com",
        resource: "https://mcp.example.com/mcp"}

  `expires_at` is Unix seconds. The client calls the store from its own
  process only. The default, `Snodo.OAuth.Client.TokenStore.Memory`, keeps the
  entries in the client's state and forgets them when it stops; a store
  that persists tokens must protect them as the credentials they are.
  """

  @type state :: term()
  @type key :: String.t()
  @type value :: map()

  @doc "Prepares the store from the `{module, arg}` given to the client."
  @callback init(arg :: term()) :: {:ok, state()}

  @callback fetch(state(), key()) :: {:ok, value()} | :error
  @callback put(state(), key(), value()) :: {:ok, state()}
  @callback delete(state(), key()) :: {:ok, state()}
end
