defmodule Snodo.OAuth.Client.ClientAuth do
  @moduledoc false
  # Client authentication at the token endpoint: `none`,
  # `client_secret_basic`, and `client_secret_post` (RFC 6749 section 2.3.1),
  # and `private_key_jwt` (RFC 7523 section 2.2).

  @assertion_type "urn:ietf:params:oauth:client-assertion-type:jwt-bearer"
  @methods ~w(none client_secret_basic client_secret_post private_key_jwt)
  @assertion_lifetime 300

  @spec methods() :: [String.t()]
  def methods, do: @methods

  @doc """
  The method to use: the configured one, then the one the registration
  named, then what the credentials allow among the server's methods.
  """
  @spec method(map(), map(), map()) :: String.t()
  def method(identity, as_metadata, config) do
    cond do
      is_binary(config.token_endpoint_auth_method) -> config.token_endpoint_auth_method
      identity[:token_endpoint_auth_method] in @methods -> identity.token_endpoint_auth_method
      config.private_key != nil -> "private_key_jwt"
      is_binary(identity[:client_secret]) -> secret_method(supported(as_metadata))
      true -> "none"
    end
  end

  @doc """
  The method to ask for in a registration request: the configured one, or
  the one the credentials call for among the server's methods.
  """
  @spec registration_method(map(), map()) :: String.t()
  def registration_method(as_metadata, config) do
    supported = supported(as_metadata)

    cond do
      is_binary(config.token_endpoint_auth_method) -> config.token_endpoint_auth_method
      config.private_key != nil -> "private_key_jwt"
      "none" in supported -> "none"
      true -> secret_method(supported)
    end
  end

  @doc "Adds the client authentication to a token request's fields and headers."
  @spec apply(String.t(), map(), map(), map(), [{String.t(), String.t()}]) ::
          {:ok, [{String.t(), String.t()}], [{String.t(), String.t()}]} | {:error, term()}
  def apply("none", identity, _config, _as_metadata, fields),
    do: {:ok, [{"client_id", identity.client_id} | fields], []}

  def apply("client_secret_basic", identity, _config, _as_metadata, fields) do
    with {:ok, secret} <- secret(identity) do
      credentials =
        Base.encode64(
          URI.encode_www_form(identity.client_id) <> ":" <> URI.encode_www_form(secret)
        )

      {:ok, [{"client_id", identity.client_id} | fields],
       [{"authorization", "Basic " <> credentials}]}
    end
  end

  def apply("client_secret_post", identity, _config, _as_metadata, fields) do
    with {:ok, secret} <- secret(identity) do
      {:ok, [{"client_id", identity.client_id}, {"client_secret", secret} | fields], []}
    end
  end

  def apply("private_key_jwt", identity, config, as_metadata, fields) do
    with {:ok, assertion} <- assertion(identity.client_id, config, as_metadata) do
      {:ok,
       [
         {"client_id", identity.client_id},
         {"client_assertion_type", @assertion_type},
         {"client_assertion", assertion}
         | fields
       ], []}
    end
  end

  def apply(method, _identity, _config, _as_metadata, _fields),
    do: {:error, {:unsupported_token_endpoint_auth_method, method}}

  @doc """
  Parses the `:private_key` option into a `JOSE.JWK`: a PEM string (PKCS#8
  or a traditional private key), a JWK map, or a `JOSE.JWK` struct.
  """
  @spec jwk!(term()) :: JOSE.JWK.t()
  def jwk!(%JOSE.JWK{} = jwk), do: jwk

  def jwk!(pem) when is_binary(pem) do
    case parse(fn -> JOSE.JWK.from_pem(pem) end) do
      %JOSE.JWK{} = jwk -> jwk
      _other -> raise ArgumentError, ":private_key is not a PEM-encoded private key"
    end
  end

  def jwk!(%{} = map) do
    case parse(fn -> JOSE.JWK.from_map(map) end) do
      %JOSE.JWK{} = jwk -> jwk
      _other -> raise ArgumentError, ":private_key is not a JWK map"
    end
  end

  def jwk!(other) do
    raise ArgumentError,
          ":private_key must be a PEM string, a JWK map, or a JOSE.JWK, got: #{inspect(other)}"
  end

  @doc "The signing algorithm for `jwk` when none is configured."
  @spec algorithm(JOSE.JWK.t()) :: {:ok, String.t()} | {:error, term()}
  def algorithm(%JOSE.JWK{} = jwk) do
    {_kty, map} = JOSE.JWK.to_map(jwk)

    case map do
      %{"kty" => "EC", "crv" => "P-256"} -> {:ok, "ES256"}
      %{"kty" => "EC", "crv" => "P-384"} -> {:ok, "ES384"}
      %{"kty" => "EC", "crv" => "P-521"} -> {:ok, "ES512"}
      %{"kty" => "RSA"} -> {:ok, "RS256"}
      %{"kty" => "OKP"} -> {:ok, "EdDSA"}
      %{"kty" => kty} -> {:error, {:unsupported_key_type, kty}}
    end
  end

  # jose raises or returns an empty list for input it cannot read.
  defp parse(fun) do
    fun.()
  rescue
    _exception -> nil
  end

  # RFC 8414: a server that lists no methods supports client_secret_basic.
  defp supported(%{"token_endpoint_auth_methods_supported" => methods}) when is_list(methods),
    do: Enum.filter(methods, &is_binary/1)

  defp supported(_as_metadata), do: ["client_secret_basic"]

  # A secret is used the way the server accepts; a server that takes only
  # public clients gets none, as the official SDKs do.
  defp secret_method(supported) do
    cond do
      "client_secret_basic" in supported -> "client_secret_basic"
      "client_secret_post" in supported -> "client_secret_post"
      "none" in supported -> "none"
      true -> "client_secret_basic"
    end
  end

  defp secret(%{client_secret: secret}) when is_binary(secret), do: {:ok, secret}
  defp secret(_identity), do: {:error, :missing_client_secret}

  # The assertion's audience is the issuer identifier, which RFC 7523 allows
  # and the MCP client-credentials extension expects.
  defp assertion(client_id, %{private_key: %JOSE.JWK{} = jwk} = config, as_metadata) do
    with {:ok, alg} <- algorithm(config.signing_algorithm, jwk) do
      now = System.os_time(:second)
      {_kty, map} = JOSE.JWK.to_map(jwk)

      header =
        if is_binary(map["kid"]), do: %{"alg" => alg, "kid" => map["kid"]}, else: %{"alg" => alg}

      claims = %{
        "iss" => client_id,
        "sub" => client_id,
        "aud" => config.client_assertion_audience || as_metadata["issuer"],
        "jti" => 16 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false),
        "iat" => now,
        "exp" => now + @assertion_lifetime
      }

      {_alg, token} = jwk |> JOSE.JWT.sign(header, claims) |> JOSE.JWS.compact()
      {:ok, token}
    end
  end

  defp assertion(_client_id, _config, _as_metadata), do: {:error, :missing_private_key}

  defp algorithm(alg, _jwk) when is_binary(alg), do: {:ok, alg}
  defp algorithm(nil, jwk), do: algorithm(jwk)
end
