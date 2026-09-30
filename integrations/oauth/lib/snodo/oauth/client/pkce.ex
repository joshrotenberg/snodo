defmodule Snodo.OAuth.Client.PKCE do
  @moduledoc """
  Proof Key for Code Exchange (RFC 7636) with the `S256` method, the only
  method the MCP authorization specification allows.

      verifier = Snodo.OAuth.Client.PKCE.verifier()
      challenge = Snodo.OAuth.Client.PKCE.challenge(verifier)
  """

  @doc "A fresh code verifier: 32 random bytes as 43 URL-safe characters."
  @spec verifier() :: String.t()
  def verifier, do: 32 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

  @doc "The `S256` code challenge for `verifier`: its SHA-256 digest, base64url without padding."
  @spec challenge(String.t()) :: String.t()
  def challenge(verifier) when is_binary(verifier),
    do: :sha256 |> :crypto.hash(verifier) |> Base.url_encode64(padding: false)
end
