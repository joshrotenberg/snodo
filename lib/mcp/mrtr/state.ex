defmodule MCP.MRTR.State do
  @moduledoc """
  Optional, integrity-protected state for multi-round-trip requests.

  `seal/3` produces a JSON-backed token that `open/3` binds to the original
  request method, salient request parameters, and an explicitly supplied
  authenticated principal. Supply `principal: nil` only for deliberately
  anonymous requests. Authentication and principal selection belong to the
  application; the helper does not infer identity from client-controlled data.

  Parameters named `"_meta"`, `"requestState"`, and `"inputResponses"` at the
  top level are excluded from the binding, as are the JSON-RPC request ID and
  transport. Map ordering is immaterial; list ordering and numeric types are
  retained, so `1` and `1.0` bind differently as a conservative check.

  Required options are `:secret` (at least 32 bytes of application-managed,
  cryptographically random secret material) and `:principal` (a JSON value).
  Optional `:ttl` defaults to 300 seconds and cannot exceed 900 seconds. When
  opening a token, `:ttl` also limits its originally issued lifetime; changing
  it never extends the signed expiration. `:clock` may be a trusted zero-arity
  function returning Unix time in seconds, primarily for deterministic tests.

  Tokens are signed, **not encrypted**: their state is readable by the client.
  Never place credentials or other secrets in state. Tokens can be reused
  until expiry and are not a replay-prevention or single-use mechanism. The
  application owns idempotency, durable replay tracking, authorization on each
  request, and secret distribution/rotation. Rotating the secret invalidates
  previously issued tokens. This helper imposes a 16 KiB token size limit.
  """

  alias MCP.Context
  alias MCP.Error
  alias MCP.JSONValue

  @prefix "mrtr1."
  @version 1
  @default_ttl 300
  @max_ttl 900
  @max_token_bytes 16_384
  @ignored_params ["_meta", "requestState", "inputResponses"]
  @allowed_options [:secret, :principal, :ttl, :clock]

  @doc "Seals JSON state, raising for invalid application configuration or state."
  @spec seal(term(), Context.t(), keyword()) :: String.t()
  def seal(data, %Context{} = context, opts) do
    policy = policy!(opts)
    scope = scope!(context, policy)
    now = now!(policy)
    validate_json!(data)

    encoded =
      [@version, now, now + policy.ttl, scope, data]
      |> encode_json!()
      |> Base.url_encode64(padding: false)

    token = @prefix <> encoded <> "." <> signature(encoded, policy.secret)

    if byte_size(token) > @max_token_bytes do
      raise ArgumentError, "request state exceeds the 16 KiB token size limit"
    end

    token
  end

  @doc """
  Opens valid, unexpired state for this principal and request.

  Untrusted token failures all return the same protocol error with no data or
  cause. Invalid application configuration still raises an `ArgumentError`.
  """
  @spec open(term(), Context.t(), keyword()) :: {:ok, term()} | {:error, Error.t()}
  def open(token, %Context{} = context, opts) do
    policy = policy!(opts)
    scope = scope!(context, policy)
    now = now!(policy)

    with {:ok, payload} <- authenticated_payload(token, policy.secret),
         [@version, issued, expires, token_scope, data] <- payload,
         true <- valid_lifetime?(issued, expires, now, policy.ttl),
         true <- secure_equal?(token_scope, scope) do
      {:ok, data}
    else
      _invalid -> {:error, Error.invalid_params("Invalid or expired request state")}
    end
  end

  defp policy!(opts) do
    unless Keyword.keyword?(opts) and Keyword.keys(opts) -- @allowed_options == [] do
      raise ArgumentError, "request state requires supported keyword options"
    end

    secret = Keyword.get(opts, :secret)
    ttl = Keyword.get(opts, :ttl, @default_ttl)
    clock = Keyword.get(opts, :clock, fn -> System.system_time(:second) end)
    validate_policy!(secret, ttl, clock)

    principal =
      case Keyword.fetch(opts, :principal) do
        {:ok, principal} -> principal
        :error -> raise ArgumentError, "request state requires an explicit principal option"
      end

    validate_json!(principal)
    %{secret: secret, principal: principal, ttl: ttl, clock: clock}
  end

  defp validate_policy!(secret, ttl, clock) do
    unless is_binary(secret) and byte_size(secret) >= 32 do
      raise ArgumentError, "request state requires a secret of at least 32 bytes"
    end

    unless is_integer(ttl) and ttl > 0 and ttl <= @max_ttl do
      raise ArgumentError, "request state ttl must be between 1 and 900 seconds"
    end

    unless is_function(clock, 0) do
      raise ArgumentError, "request state clock must be a zero-arity function"
    end
  end

  defp now!(%{clock: clock}) do
    case clock.() do
      now when is_integer(now) and now >= 0 -> now
      _invalid -> raise ArgumentError, "request state clock must return nonnegative Unix seconds"
    end
  end

  defp scope!(%Context{request_method: method, request_params: params}, policy)
       when is_binary(method) and method != "" and is_map(params) do
    values = [method, Map.drop(params, @ignored_params), policy.principal]
    validate_json!(values)

    :crypto.mac(:hmac, :sha256, policy.secret, ["mcp-ex-mrtr-scope-v1:", canonical(values)])
    |> Base.url_encode64(padding: false)
  end

  defp scope!(_context, _policy) do
    raise ArgumentError, "request state requires a request method and parameter map in context"
  end

  defp canonical(value) when is_map(value) do
    entries =
      value
      |> Enum.sort_by(fn {key, _value} -> key end)
      |> Enum.map(fn {key, nested} -> [encode_json!(key), ":", canonical(nested)] end)

    ["{", Enum.intersperse(entries, ","), "}"]
  end

  defp canonical(value) when is_list(value) do
    ["[", value |> Enum.map(&canonical/1) |> Enum.intersperse(","), "]"]
  end

  defp canonical(value), do: encode_json!(value)

  defp validate_json!(value) do
    unless JSONValue.valid?(value) do
      raise ArgumentError, "request state and binding values must be JSON values"
    end
  end

  defp encode_json!(value) do
    JSON.encode!(value)
  rescue
    _error ->
      reraise ArgumentError.exception("request state and binding values must be valid JSON"),
              __STACKTRACE__
  end

  defp signature(encoded, secret) do
    :crypto.mac(:hmac, :sha256, secret, ["mcp-ex-mrtr-token-v1:", encoded])
    |> Base.url_encode64(padding: false)
  end

  defp authenticated_payload(token, secret)
       when is_binary(token) and byte_size(token) <= @max_token_bytes do
    with @prefix <> rest <- token,
         [encoded, mac] <- :binary.split(rest, ".", [:global]),
         true <- secure_equal?(mac, signature(encoded, secret)),
         {:ok, json} <- Base.url_decode64(encoded, padding: false),
         {:ok, payload} <- JSON.decode(json) do
      {:ok, payload}
    else
      _invalid -> :error
    end
  end

  defp authenticated_payload(_token, _secret), do: :error

  defp valid_lifetime?(issued, expires, now, ttl)
       when is_integer(issued) and is_integer(expires) do
    issued >= 0 and issued <= now and expires > now and expires > issued and
      expires - issued <= ttl
  end

  defp valid_lifetime?(_issued, _expires, _now, _ttl), do: false

  defp secure_equal?(left, right)
       when is_binary(left) and is_binary(right) and byte_size(left) == byte_size(right),
       do: :crypto.hash_equals(left, right)

  defp secure_equal?(_left, _right), do: false
end
