defmodule Snodo.MRTR.State do
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

  ## Options

    * `:keys` - a keyring of `{key_id, secret}` pairs, current key first.
      `seal/3` signs with the current key and embeds its identifier in the
      token; `open/3` verifies with the key the token names, which may be the
      current key or a retired one. At most 8 keys. Identifiers are 1 to 32
      characters from `A-Z`, `a-z`, `0-9`, `_`, and `-`, and must be unique.
      Identifiers are not secret and are readable in the token.
    * `:secret` - a single key without an identifier. Tokens it seals carry no
      key identifier. Supply exactly one of `:keys` and `:secret`.
    * `:principal` - required, a JSON value.
    * `:ttl` - defaults to 300 seconds and cannot exceed 900 seconds. When
      opening a token, `:ttl` also limits its originally issued lifetime;
      changing it never extends the signed expiration.
    * `:clock` - a trusted zero-arity function returning Unix time in seconds,
      primarily for deterministic tests.

  Every secret is application-managed, cryptographically random, and at least
  32 bytes. Invalid options raise an `ArgumentError`.

  ## Rotation

  A token names the key that signed it, so a key can be rotated without
  invalidating tokens in flight, and nodes behind a load balancer do not have
  to switch at the same moment. To replace key `a` with key `b` in a cluster:

    1. Deploy `keys: [{"a", a}, {"b", b}]` to every node. Nodes still seal
       with `a` and now also accept `b`.
    2. Once every node accepts `b`, deploy `keys: [{"b", b}, {"a", a}]`. Nodes
       seal with `b` and still accept tokens sealed with `a`.
    3. Once every node seals with `b`, wait for the largest TTL in use (at most
       900 seconds), then deploy `keys: [{"b", b}]`.

  A keyring also opens tokens sealed with `:secret` when that secret is in the
  keyring, and `:secret` opens tokens sealed by a keyring whose key matches
  it, so a cluster can move from `:secret` to `keys: [{"a", secret}]` one node
  at a time. Removing a key rejects every token it signed.

  Tokens are signed, **not encrypted**: their state is readable by the client.
  Never place credentials or other secrets in state. Tokens can be reused
  until expiry and are not a replay-prevention or single-use mechanism. The
  application owns idempotency, durable replay tracking, authorization on each
  request, and secret distribution. This helper imposes a 16 KiB token size
  limit.
  """

  alias Snodo.Context
  alias Snodo.Error
  alias Snodo.JSONValue

  @unidentified_prefix "mrtr1."
  @identified_prefix "mrtr2."
  @unidentified_version 1
  @identified_version 2
  @default_ttl 300
  @max_ttl 900
  @max_token_bytes 16_384
  @max_keys 8
  @max_key_id_bytes 32
  @min_secret_bytes 32
  @ignored_params ["_meta", "requestState", "inputResponses"]
  @allowed_options [:secret, :keys, :principal, :ttl, :clock]

  @doc "Seals JSON state, raising for invalid application configuration or state."
  @spec seal(term(), Context.t(), keyword()) :: String.t()
  def seal(data, %Context{} = context, opts) do
    policy = policy!(opts)
    binding = binding!(context, policy)
    now = now!(policy)
    validate_json!(data)

    [{key_id, secret} | _retired] = policy.keys
    version = if key_id, do: @identified_version, else: @unidentified_version

    encoded =
      [version, now, now + policy.ttl, scope(binding, secret), data]
      |> encode_json!()
      |> Base.url_encode64(padding: false)

    token =
      case key_id do
        nil ->
          @unidentified_prefix <> encoded <> "." <> signature(encoded, secret)

        key_id ->
          @identified_prefix <>
            key_id <> "." <> encoded <> "." <> signature(key_id, encoded, secret)
      end

    if byte_size(token) > @max_token_bytes do
      raise ArgumentError, "request state exceeds the 16 KiB token size limit"
    end

    token
  end

  @doc """
  Opens valid, unexpired state for this principal and request.

  The token is verified with the key it names, from `:keys`, or with
  `:secret`. Untrusted token failures, including an unknown key identifier,
  all return the same protocol error with no data or cause. Invalid
  application configuration still raises an `ArgumentError`.
  """
  @spec open(term(), Context.t(), keyword()) :: {:ok, term()} | {:error, Error.t()}
  def open(token, %Context{} = context, opts) do
    policy = policy!(opts)
    binding = binding!(context, policy)
    now = now!(policy)

    with {:ok, version, secret, payload} <- authenticated_payload(token, policy.keys),
         [^version, issued, expires, token_scope, data] <- payload,
         true <- valid_lifetime?(issued, expires, now, policy.ttl),
         true <- secure_equal?(token_scope, scope(binding, secret)) do
      {:ok, data}
    else
      _invalid -> {:error, Error.invalid_params("Invalid or expired request state")}
    end
  end

  defp policy!(opts) do
    unless Keyword.keyword?(opts) and Keyword.keys(opts) -- @allowed_options == [] do
      raise ArgumentError, "request state requires supported keyword options"
    end

    keys = keys!(opts)
    ttl = Keyword.get(opts, :ttl, @default_ttl)
    clock = Keyword.get(opts, :clock, fn -> System.system_time(:second) end)
    validate_policy!(ttl, clock)

    principal =
      case Keyword.fetch(opts, :principal) do
        {:ok, principal} -> principal
        :error -> raise ArgumentError, "request state requires an explicit principal option"
      end

    validate_json!(principal)
    %{keys: keys, principal: principal, ttl: ttl, clock: clock}
  end

  defp keys!(opts) do
    case {Keyword.fetch(opts, :secret), Keyword.fetch(opts, :keys)} do
      {{:ok, secret}, :error} ->
        validate_secret!(secret)
        [{nil, secret}]

      {:error, {:ok, keys}} ->
        validate_keys!(keys)
        keys

      _other ->
        raise ArgumentError, "request state requires exactly one of the :secret and :keys options"
    end
  end

  defp validate_keys!(keys) do
    unless is_list(keys) and not List.improper?(keys) and keys != [] and
             length(keys) <= @max_keys and
             Enum.all?(keys, &match?({_key_id, _secret}, &1)) do
      raise ArgumentError,
            "request state keys must be a list of 1 to #{@max_keys} {key_id, secret} pairs"
    end

    Enum.each(keys, fn {key_id, secret} ->
      unless valid_key_id?(key_id) do
        raise ArgumentError,
              "request state key identifiers must be 1 to #{@max_key_id_bytes} characters " <>
                "from A-Z, a-z, 0-9, _ and -"
      end

      validate_secret!(secret)
    end)

    key_ids = Enum.map(keys, &elem(&1, 0))

    unless Enum.uniq(key_ids) == key_ids do
      raise ArgumentError, "request state key identifiers must be unique"
    end
  end

  defp valid_key_id?(key_id) when is_binary(key_id) do
    byte_size(key_id) in 1..@max_key_id_bytes and
      key_id |> :binary.bin_to_list() |> Enum.all?(&key_id_byte?/1)
  end

  defp valid_key_id?(_key_id), do: false

  defp key_id_byte?(byte),
    do: byte in ?A..?Z or byte in ?a..?z or byte in ?0..?9 or byte in [?_, ?-]

  defp validate_secret!(secret) do
    unless is_binary(secret) and byte_size(secret) >= @min_secret_bytes do
      raise ArgumentError, "request state requires a secret of at least 32 bytes"
    end
  end

  defp validate_policy!(ttl, clock) do
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

  defp binding!(%Context{request_method: method, request_params: params}, policy)
       when is_binary(method) and method != "" and is_map(params) do
    values = [method, Map.drop(params, @ignored_params), policy.principal]
    validate_json!(values)
    canonical(values)
  end

  defp binding!(_context, _policy) do
    raise ArgumentError, "request state requires a request method and parameter map in context"
  end

  defp scope(binding, secret) do
    :crypto.mac(:hmac, :sha256, secret, ["snodo-mrtr-scope-v1:", binding])
    |> Base.url_encode64(padding: false)
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
    :crypto.mac(:hmac, :sha256, secret, ["snodo-mrtr-token-v1:", encoded])
    |> Base.url_encode64(padding: false)
  end

  defp signature(key_id, encoded, secret) do
    :crypto.mac(:hmac, :sha256, secret, ["snodo-mrtr-token-v2:", key_id, ".", encoded])
    |> Base.url_encode64(padding: false)
  end

  defp authenticated_payload(token, keys)
       when is_binary(token) and byte_size(token) <= @max_token_bytes do
    with {:ok, version, candidates} <- candidates(token, keys),
         {:ok, encoded, secret} <- verified(candidates),
         {:ok, json} <- Base.url_decode64(encoded, padding: false),
         {:ok, payload} <- JSON.decode(json) do
      {:ok, version, secret, payload}
    else
      _invalid -> :error
    end
  end

  defp authenticated_payload(_token, _keys), do: :error

  # A token without a key identifier is checked against every key, which is
  # bounded by the keyring limit. A token with one must carry a well-formed
  # identifier, and is checked against the key it names, or against
  # `:secret`, which has no identifier to match.
  defp candidates(@unidentified_prefix <> rest, keys) do
    case :binary.split(rest, ".", [:global]) do
      [encoded, mac] ->
        {:ok, @unidentified_version,
         Enum.map(keys, fn {_key_id, secret} ->
           {encoded, mac, secret, signature(encoded, secret)}
         end)}

      _invalid ->
        :error
    end
  end

  defp candidates(@identified_prefix <> rest, keys) do
    with [token_key_id, encoded, mac] <- :binary.split(rest, ".", [:global]),
         true <- valid_key_id?(token_key_id) do
      candidates =
        for {key_id, secret} <- keys, key_id == nil or secure_equal?(key_id, token_key_id) do
          {encoded, mac, secret, signature(token_key_id, encoded, secret)}
        end

      {:ok, @identified_version, candidates}
    else
      _invalid -> :error
    end
  end

  defp candidates(_token, _keys), do: :error

  # Every candidate is compared, so the time taken does not depend on which
  # key matched.
  defp verified(candidates) do
    Enum.reduce(candidates, :error, fn {encoded, mac, secret, expected}, found ->
      if secure_equal?(mac, expected) and found == :error do
        {:ok, encoded, secret}
      else
        found
      end
    end)
  end

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
