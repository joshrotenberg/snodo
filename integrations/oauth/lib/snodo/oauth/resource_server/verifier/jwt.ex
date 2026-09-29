defmodule Snodo.OAuth.ResourceServer.Verifier.JWT do
  @moduledoc """
  Verifies signed JWT access tokens (RFC 9068) against cached keys.

  Configure it on the bearer plug with the name of a running
  `Snodo.OAuth.ResourceServer.JWKS` and the trusted issuer:

      plug Snodo.OAuth.ResourceServer.Bearer,
        resource: "https://mcp.example.com/mcp",
        verifier:
          {Snodo.OAuth.ResourceServer.Verifier.JWT,
           keys: MyApp.JWKS, issuer: "https://auth.example.com"}

  Verification reads the protected header, requires `alg` to be one of
  `:algs`, looks the key up by `kid` and key type, checks the signature with
  `jose`, requires `iss` to equal one of the configured issuers, and requires
  an `exp` claim. The lifetime, audience, and scope checks run in the plug.

  ## Options

  | Option | Default | Meaning |
  |---|---|---|
  | `:keys` | required | A `Snodo.OAuth.ResourceServer.JWKS` name or pid |
  | `:issuer` | required | The trusted issuer, or a list of them; compared exactly |
  | `:algs` | RSA, ECDSA, and EdDSA algorithms | Accepted `alg` values. `none` is always refused |

  The default `:algs` are `RS256`, `RS384`, `RS512`, `PS256`, `PS384`,
  `PS512`, `ES256`, `ES384`, `ES512`, and `EdDSA`. An HMAC algorithm can be
  listed explicitly, which is only meaningful with a static `oct` key; a
  fetched document never supplies one.

  ## Errors

  `:malformed`, `:unsupported_alg`, `:unknown_key`, `:bad_signature`,
  `:wrong_issuer`, `:missing_exp`, and `{:keys_unavailable, reason}` when
  the key document has never been fetched and the last attempt failed.
  """

  @behaviour Snodo.OAuth.ResourceServer.Verifier

  alias Snodo.OAuth.ResourceServer.JWKS

  @default_algs ~w(RS256 RS384 RS512 PS256 PS384 PS512 ES256 ES384 ES512 EdDSA)

  @doc """
  The algorithms accepted when `:algs` is not given.
  """
  @spec default_algs() :: [String.t()]
  def default_algs, do: @default_algs

  @impl true
  def verify(token, options) when is_binary(token) do
    keys = option!(options, :keys)
    issuers = List.wrap(option!(options, :issuer))
    algs = algs!(options)

    with {:ok, header} <- decode_header(token),
         {:ok, alg} <- algorithm(header, algs),
         {:ok, kid} <- key_id(header),
         {:ok, candidates} <- candidates(keys, kid, alg),
         {:ok, claims} <- verify_signature(candidates, alg, token),
         :ok <- check_issuer(claims, issuers) do
      check_exp(claims)
    end
  end

  defp decode_header(token) do
    with [encoded, _payload, _signature] <- String.split(token, "."),
         {:ok, json} <- Base.url_decode64(encoded, padding: false),
         {:ok, header} when is_map(header) <- JSON.decode(json) do
      {:ok, header}
    else
      _other -> {:error, :malformed}
    end
  end

  defp algorithm(%{"alg" => alg}, algs) when is_binary(alg) and alg != "none" do
    if alg in algs, do: {:ok, alg}, else: {:error, :unsupported_alg}
  end

  defp algorithm(_header, _algs), do: {:error, :unsupported_alg}

  defp key_id(%{"kid" => kid}) when is_binary(kid), do: {:ok, kid}
  defp key_id(%{"kid" => _other}), do: {:error, :malformed}
  defp key_id(_header), do: {:ok, nil}

  defp candidates(keys, kid, alg) do
    case JWKS.lookup(keys, kid, alg) do
      {:ok, []} -> {:error, :unknown_key}
      {:ok, candidates} -> {:ok, candidates}
      {:error, reason} -> {:error, {:keys_unavailable, reason}}
    end
  end

  defp verify_signature(candidates, alg, token) do
    Enum.find_value(candidates, {:error, :bad_signature}, fn jwk ->
      case JOSE.JWT.verify_strict(jwk, [alg], token) do
        {true, %JOSE.JWT{fields: claims}, _jws} when is_map(claims) -> {:ok, claims}
        _other -> nil
      end
    end)
  rescue
    _exception -> {:error, :bad_signature}
  end

  defp check_issuer(%{"iss" => iss}, issuers) when is_binary(iss) do
    if iss in issuers, do: :ok, else: {:error, :wrong_issuer}
  end

  defp check_issuer(_claims, _issuers), do: {:error, :wrong_issuer}

  defp check_exp(%{"exp" => exp} = claims) when is_number(exp), do: {:ok, claims}
  defp check_exp(_claims), do: {:error, :missing_exp}

  defp algs!(options) do
    case option(options, :algs, @default_algs) do
      [_ | _] = algs ->
        if Enum.all?(algs, &(is_binary(&1) and &1 != "none")),
          do: algs,
          else: raise(ArgumentError, ":algs must be algorithm names other than \"none\"")

      other ->
        raise ArgumentError, ":algs must be a non-empty list, got: #{inspect(other)}"
    end
  end

  defp option!(options, key) do
    case option(options, key, nil) do
      nil -> raise ArgumentError, "#{inspect(__MODULE__)} needs the #{inspect(key)} option"
      value -> value
    end
  end

  defp option(options, key, default) when is_list(options), do: Keyword.get(options, key, default)
  defp option(options, key, default) when is_map(options), do: Map.get(options, key, default)

  defp option(options, _key, _default) do
    raise ArgumentError,
          "verifier options must be a keyword list or map, got: #{inspect(options)}"
  end
end
