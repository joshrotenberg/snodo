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
  once its authorization ends, whether it completed, failed, or timed out.
  The redirect is always validated by the flow that started the
  authorization, inside the client process that holds it, so the redirect
  must reach that process (through the loopback listener, the `:authorize`
  function, or `Snodo.OAuth.Client.callback/2`). The default memory store is
  enough for every redirect kind; a custom store controls where the PKCE
  verifier is kept while the authorization is under way, and does not let
  another client process complete it.
  """

  @type state :: term()
  @type key :: String.t()
  @type value :: map()

  @doc "Prepares the store from the `{module, arg}` given to the client."
  @callback init(arg :: term()) :: {:ok, state()}

  @doc "Returns the pending authorization stored under `key`, or `:error` when there is none."
  @callback fetch(state(), key()) :: {:ok, value()} | :error

  @doc "Stores `value` under `key`, replacing any earlier value."
  @callback put(state(), key(), value()) :: {:ok, state()}

  @doc "Removes `key`. Removing a key that is not there succeeds."
  @callback delete(state(), key()) :: {:ok, state()}
end
