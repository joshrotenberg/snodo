defmodule Snodo.OAuth.ResourceServer.Verifier do
  @moduledoc """
  Verifies an access token and returns its claims.

  `Snodo.OAuth.ResourceServer.Bearer` calls `c:verify/2` with the token from
  the `Authorization` header and the options it was configured with, as
  `verifier: {Module, options}`. The verifier establishes that the token is
  genuine and was issued by a trusted authorization server; the lifetime
  (`exp`, `nbf`), audience (`aud`), and scope checks run in the plug so they
  apply to every implementation the same way.

  The returned claims use the protocol's string keys, as a decoded JWT
  payload or an RFC 7662 introspection response does. An error reason is
  reported to the client only by its name (an atom, or the first element of a
  tuple), so it can be specific without leaking detail.

  `Snodo.OAuth.ResourceServer.Verifier.JWT` verifies signed JWT access
  tokens. Token introspection is not implemented in this package.
  """

  @type claims :: %{optional(String.t()) => term()}

  @doc """
  Verifies `token` and returns its claims, or the reason it was refused.
  """
  @callback verify(token :: String.t(), options :: term()) :: {:ok, claims()} | {:error, term()}
end
