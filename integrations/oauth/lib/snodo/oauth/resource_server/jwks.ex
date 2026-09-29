defmodule Snodo.OAuth.ResourceServer.JWKS do
  @moduledoc """
  A bounded, rate-limited cache of the keys that verify access tokens.

  Start one per authorization server under the application's supervisor and
  name it for `Snodo.OAuth.ResourceServer.Verifier.JWT`:

      {Snodo.OAuth.ResourceServer.JWKS,
       name: MyApp.JWKS, url: "https://auth.example.com/.well-known/jwks.json"}

  The document is fetched lazily on the first lookup, again when it is older
  than `:ttl_ms`, and again when a token names a `kid` the cache does not
  hold, so a key rotation is picked up without a restart. A fetch is never
  attempted more often than `:min_refresh_ms`, so unknown key identifiers
  in hostile tokens cannot turn the cache into a request amplifier. When a
  fetch fails, the keys from the last successful fetch stay in use.

  `:keys` adds static keys, which a refresh never removes: JWK maps with
  string keys, PEM-encoded public keys, `%JOSE.JWK{}` structs, or
  `{kid, key}` tuples that attach a key identifier. A cache may hold static
  keys only, with no URL.

  ## Options

  | Option | Default | Meaning |
  |---|---|---|
  | `:name` | none | Registered name; the verifier's `keys:` option |
  | `:url` | none | JWKS document URL. `https` is required except for loopback hosts |
  | `:keys` | `[]` | Static keys, kept across refreshes |
  | `:max_keys` | 32 | Keys kept from one fetched document; further keys are ignored |
  | `:ttl_ms` | 3,600,000 | Age after which a lookup refreshes the document first |
  | `:min_refresh_ms` | 60,000 | Minimum time between two fetch attempts |
  | `:timeout_ms` | 5,000 | Connect and receive timeout of the default fetch |
  | `:max_body_bytes` | 1,048,576 | Largest document the default fetch accepts |
  | `:ssl` | peer verification against the OS trust store | `:ssl` options of the default fetch |
  | `:fetch` | `:httpc` GET | A function from the URL to `{:ok, body}` or `{:error, reason}` |

  The default fetch runs `:httpc` with TLS peer verification against the
  operating system's trust store (`:public_key.cacerts_get/0`) and hostname
  checking. It runs inside this process, so lookups wait while a fetch is in
  flight, at most `:timeout_ms` to connect and again to receive. A response
  larger than `:max_body_bytes` is discarded after it has been received; the
  bound protects the cache, not the network.

  A fetched document is filtered to signature keys: an entry whose `use` is
  not `sig`, whose `kty` is `oct`, or that `jose` cannot parse is skipped.
  """

  use GenServer

  @type key ::
          %{optional(String.t()) => term()}
          | String.t()
          | JOSE.JWK.t()
          | {String.t(), %{optional(String.t()) => term()} | String.t() | JOSE.JWK.t()}

  @type option ::
          {:name, GenServer.name()}
          | {:url, String.t()}
          | {:keys, [key()]}
          | {:max_keys, pos_integer()}
          | {:ttl_ms, pos_integer() | :infinity}
          | {:min_refresh_ms, non_neg_integer()}
          | {:timeout_ms, pos_integer()}
          | {:max_body_bytes, pos_integer()}
          | {:ssl, keyword()}
          | {:fetch, (String.t() -> {:ok, binary()} | {:error, term()})}

  @typep entry :: %{
           kid: String.t() | nil,
           alg: String.t() | nil,
           kty: String.t(),
           jwk: JOSE.JWK.t()
         }

  @call_timeout 30_000
  @loopback ["localhost", "127.0.0.1", "::1"]

  @doc """
  Starts the cache. See the module documentation for the options.
  """
  @spec start_link([option()]) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    case Keyword.get(opts, :name) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @doc """
  Returns the keys that may verify a token signed with `alg` and, when the
  token names one, the key identifier `kid`.

  A token with a `kid` matches only keys with that identifier; a token
  without one matches every key of the algorithm's key type. Keys that
  declare an `alg` match only that algorithm. An empty list means no key is
  known for the token, after a refresh when one was allowed. `{:error,
  reason}` means the document has never been fetched and the last attempt
  failed.
  """
  @spec lookup(GenServer.server(), String.t() | nil, String.t()) ::
          {:ok, [JOSE.JWK.t()]} | {:error, term()}
  def lookup(server, kid, alg) when (is_binary(kid) or is_nil(kid)) and is_binary(alg) do
    GenServer.call(server, {:lookup, kid, alg}, @call_timeout)
  end

  @doc """
  Fetches the document now, regardless of `:ttl_ms` and `:min_refresh_ms`.
  """
  @spec refresh(GenServer.server()) :: :ok | {:error, term()}
  def refresh(server), do: GenServer.call(server, :refresh, @call_timeout)

  @doc """
  Returns the number of static and fetched keys, whether a fetch has
  succeeded, and the last fetch error.
  """
  @spec stats(GenServer.server()) :: %{
          static: non_neg_integer(),
          fetched: non_neg_integer(),
          fetched?: boolean(),
          last_error: term()
        }
  def stats(server), do: GenServer.call(server, :stats, @call_timeout)

  @doc false
  @spec key_type(String.t()) :: String.t() | nil
  def key_type("RS" <> _), do: "RSA"
  def key_type("PS" <> _), do: "RSA"
  def key_type("ES" <> _), do: "EC"
  def key_type("EdDSA"), do: "OKP"
  def key_type("HS" <> _), do: "oct"
  def key_type(_alg), do: nil

  @impl true
  def init(opts) do
    url = url!(Keyword.get(opts, :url))
    static = opts |> Keyword.get(:keys, []) |> Enum.map(&static_entry!/1)

    if url == nil and static == [] do
      raise ArgumentError, "JWKS needs a :url, static :keys, or both"
    end

    timeout_ms = positive!(opts, :timeout_ms, 5_000)
    max_body_bytes = positive!(opts, :max_body_bytes, 1_048_576)
    ssl = Keyword.get(opts, :ssl)

    fetch =
      case Keyword.get(opts, :fetch) do
        nil ->
          &http_fetch(&1, timeout_ms, max_body_bytes, ssl)

        fun when is_function(fun, 1) ->
          fun

        other ->
          raise ArgumentError, ":fetch must be a one-argument function, got: #{inspect(other)}"
      end

    {:ok,
     %{
       url: url,
       fetch: fetch,
       static: static,
       keys: [],
       max_keys: positive!(opts, :max_keys, 32),
       ttl_ms: ttl!(opts),
       min_refresh_ms: non_negative!(opts, :min_refresh_ms, 60_000),
       fetched_at: nil,
       attempted_at: nil,
       last_error: nil
     }}
  end

  @impl true
  def handle_call({:lookup, kid, alg}, _from, state) do
    state = maybe_fetch(state, :expiry)
    candidates = select(state, kid, alg)

    {state, candidates} =
      if candidates == [] and kid != nil do
        state = maybe_fetch(state, :miss)
        {state, select(state, kid, alg)}
      else
        {state, candidates}
      end

    reply =
      if candidates == [] and state.url != nil and state.fetched_at == nil and
           state.last_error != nil,
         do: {:error, state.last_error},
         else: {:ok, Enum.map(candidates, & &1.jwk)}

    {:reply, reply, state}
  end

  def handle_call(:refresh, _from, %{url: nil} = state), do: {:reply, :ok, state}

  def handle_call(:refresh, _from, state) do
    state = fetch(state, now())
    {:reply, if(state.last_error == nil, do: :ok, else: {:error, state.last_error}), state}
  end

  def handle_call(:stats, _from, state) do
    {:reply,
     %{
       static: length(state.static),
       fetched: length(state.keys),
       fetched?: state.fetched_at != nil,
       last_error: state.last_error
     }, state}
  end

  defp select(state, kid, alg) do
    kty = key_type(alg)

    Enum.filter(state.static ++ state.keys, fn entry ->
      (kid == nil or entry.kid == kid) and (entry.alg == nil or entry.alg == alg) and
        (kty == nil or entry.kty == kty)
    end)
  end

  defp maybe_fetch(%{url: nil} = state, _reason), do: state

  defp maybe_fetch(state, reason) do
    now = now()

    expired? =
      state.fetched_at == nil or
        (state.ttl_ms != :infinity and now - state.fetched_at >= state.ttl_ms)

    allowed? = state.attempted_at == nil or now - state.attempted_at >= state.min_refresh_ms

    cond do
      reason == :expiry and not expired? -> state
      not allowed? -> state
      true -> fetch(state, now)
    end
  end

  defp fetch(state, now) do
    state = %{state | attempted_at: now}

    case run_fetch(state.fetch, state.url) do
      {:ok, body} when is_binary(body) ->
        case parse(body, state.max_keys) do
          {:ok, entries} -> %{state | keys: entries, fetched_at: now, last_error: nil}
          {:error, reason} -> %{state | last_error: reason}
        end

      {:error, reason} ->
        %{state | last_error: reason}

      other ->
        %{state | last_error: {:invalid_fetch_result, other}}
    end
  end

  # A fetch function that raises would otherwise take the cached keys down
  # with the process.
  defp run_fetch(fetch, url) do
    fetch.(url)
  rescue
    exception -> {:error, {:fetch_raised, exception}}
  catch
    kind, reason -> {:error, {:fetch_raised, {kind, reason}}}
  end

  defp parse(body, max_keys) do
    case JSON.decode(body) do
      {:ok, %{"keys" => keys}} when is_list(keys) ->
        {:ok, keys |> Enum.flat_map(&remote_entry/1) |> Enum.take(max_keys)}

      _other ->
        {:error, :invalid_document}
    end
  end

  defp remote_entry(%{"kty" => kty} = map) when is_binary(kty) and kty != "oct" do
    if Map.get(map, "use", "sig") == "sig" do
      case entry(map) do
        {:ok, entry} -> [entry]
        :error -> []
      end
    else
      []
    end
  end

  defp remote_entry(_other), do: []

  defp static_entry!({kid, key}) when is_binary(kid) do
    %{static_entry!(key) | kid: kid}
  end

  defp static_entry!(%JOSE.JWK{} = jwk), do: describe(jwk)

  defp static_entry!(pem) when is_binary(pem) do
    case JOSE.JWK.from_pem(pem) do
      %JOSE.JWK{} = jwk -> describe(jwk)
      _other -> raise ArgumentError, "static key is not a PEM-encoded key"
    end
  end

  defp static_entry!(%{} = map) do
    case entry(map) do
      {:ok, entry} -> entry
      :error -> raise ArgumentError, "static key is not a JWK map: #{inspect(map)}"
    end
  end

  defp static_entry!(other) do
    raise ArgumentError,
          "static key must be a JWK map, a PEM string, or a JOSE.JWK: #{inspect(other)}"
  end

  defp entry(map) do
    {:ok, describe(JOSE.JWK.from_map(map))}
  rescue
    _exception -> :error
  end

  @spec describe(JOSE.JWK.t()) :: entry()
  defp describe(%JOSE.JWK{} = jwk) do
    {_kty, map} = JOSE.JWK.to_map(jwk)
    %{kid: string(map["kid"]), alg: string(map["alg"]), kty: map["kty"], jwk: jwk}
  end

  defp string(value) when is_binary(value), do: value
  defp string(_value), do: nil

  defp http_fetch(url, timeout_ms, max_body_bytes, ssl) do
    request = {String.to_charlist(url), [{~c"accept", ~c"application/json"}]}

    http_options =
      [timeout: timeout_ms, connect_timeout: timeout_ms, autoredirect: false] ++
        ssl_options(url, ssl)

    case :httpc.request(:get, request, http_options, body_format: :binary) do
      {:ok, {{_version, 200, _reason}, _headers, body}} when byte_size(body) <= max_body_bytes ->
        {:ok, body}

      {:ok, {{_version, 200, _reason}, _headers, _body}} ->
        {:error, :body_too_large}

      {:ok, {{_version, status, _reason}, _headers, _body}} ->
        {:error, {:http_status, status}}

      {:error, reason} ->
        {:error, {:http_error, reason}}
    end
  end

  defp ssl_options(url, ssl) do
    cond do
      URI.parse(url).scheme != "https" ->
        []

      ssl != nil ->
        [ssl: ssl]

      true ->
        [
          ssl: [
            verify: :verify_peer,
            cacerts: :public_key.cacerts_get(),
            depth: 3,
            customize_hostname_check: [
              match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
            ]
          ]
        ]
    end
  end

  defp url!(nil), do: nil

  defp url!(url) when is_binary(url) do
    uri = URI.parse(url)

    cond do
      uri.host in [nil, ""] ->
        raise ArgumentError, ":url must be an absolute URL: #{inspect(url)}"

      uri.scheme == "https" ->
        url

      uri.scheme == "http" and uri.host in @loopback ->
        url

      true ->
        raise ArgumentError, ":url must use https, except on a loopback host: #{inspect(url)}"
    end
  end

  defp url!(other), do: raise(ArgumentError, ":url must be a string, got: #{inspect(other)}")

  defp ttl!(opts) do
    case Keyword.get(opts, :ttl_ms, 3_600_000) do
      :infinity ->
        :infinity

      ms when is_integer(ms) and ms > 0 ->
        ms

      other ->
        raise ArgumentError,
              ":ttl_ms must be a positive integer or :infinity, got: #{inspect(other)}"
    end
  end

  defp positive!(opts, key, default) do
    case Keyword.get(opts, key, default) do
      value when is_integer(value) and value > 0 ->
        value

      other ->
        raise ArgumentError, "#{inspect(key)} must be a positive integer, got: #{inspect(other)}"
    end
  end

  defp non_negative!(opts, key, default) do
    case Keyword.get(opts, key, default) do
      value when is_integer(value) and value >= 0 ->
        value

      other ->
        raise ArgumentError,
              "#{inspect(key)} must be a non-negative integer, got: #{inspect(other)}"
    end
  end

  defp now, do: System.monotonic_time(:millisecond)
end
