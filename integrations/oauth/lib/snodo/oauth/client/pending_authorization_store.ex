defmodule Snodo.OAuth.Client.PendingAuthorizationStore do
  @moduledoc """
  Behaviour for where `Snodo.OAuth.Client` keeps an authorization it has
  started and not yet completed.

  Between handing out the authorization URL and receiving the redirect, the
  client must remember the PKCE verifier and what the authorization was
  for. Entries are keyed by the `state` parameter. A value is a map:

      %{code_verifier: "...", redirect_uri: "...", resource: "...",
        issuer: "...", scopes: ["mcp:read"], client_id: "...", created_at: 1_700_000_000}

  The client ignores an entry older than ten minutes and deletes an entry
  once the redirect for it has been handled. With a loopback redirect the
  default memory store is enough. An application that receives the redirect
  in its own web endpoint, possibly on another node, uses a shared store
  and hands the redirect to `Snodo.OAuth.Client.callback/2`.
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
