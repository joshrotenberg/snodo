defmodule Snodo.OAuth.Client.HTTP do
  @moduledoc false
  # The flow's HTTP client: `:httpc` with TLS peer verification, connect and
  # receive timeouts, no redirect following, and a body bound. Every URL the
  # flow fetches or posts to must be `https`, or `http` to a loopback host,
  # so a metadata document cannot send credentials over plain HTTP.

  @loopback ["localhost", "127.0.0.1", "::1"]
  @accept {~c"accept", ~c"application/json"}
  @form ~c"application/x-www-form-urlencoded"
  @json ~c"application/json"

  @type config :: %{
          timeout_ms: pos_integer(),
          max_body_bytes: pos_integer(),
          ssl: keyword() | nil
        }

  @type response :: {:ok, non_neg_integer(), map() | nil} | {:error, term()}

  @spec defaults() :: config()
  def defaults, do: %{timeout_ms: 10_000, max_body_bytes: 262_144, ssl: nil}

  @doc false
  @spec config(keyword()) :: config()
  def config(opts) when is_list(opts) do
    config = Map.merge(defaults(), Map.new(opts))

    for key <- [:timeout_ms, :max_body_bytes],
        not (is_integer(config[key]) and config[key] > 0),
        do: raise(ArgumentError, ":http #{key} must be a positive integer")

    unless is_nil(config.ssl) or is_list(config.ssl),
      do: raise(ArgumentError, ":http ssl must be a keyword list")

    Map.take(config, [:timeout_ms, :max_body_bytes, :ssl])
  end

  @doc "GET `url` and decode a JSON object body. Any status is returned."
  @spec get_json(config(), String.t()) :: response()
  def get_json(config, url) do
    with :ok <- check_url(url) do
      config
      |> request(url, :get, {String.to_charlist(url), [@accept]})
      |> decode()
    end
  end

  @doc "POST `fields` as a form and decode a JSON object body."
  @spec post_form(config(), String.t(), [{String.t(), String.t()}], [{String.t(), String.t()}]) ::
          response()
  def post_form(config, url, fields, headers \\ []) do
    with :ok <- check_url(url) do
      body = URI.encode_query(fields, :www_form)
      request = {String.to_charlist(url), [@accept | charlists(headers)], @form, body}
      config |> request(url, :post, request) |> decode()
    end
  end

  @doc "POST `map` as JSON and decode a JSON object body."
  @spec post_json(config(), String.t(), map()) :: response()
  def post_json(config, url, map) do
    with :ok <- check_url(url) do
      request = {String.to_charlist(url), [@accept], @json, JSON.encode!(map)}
      config |> request(url, :post, request) |> decode()
    end
  end

  @doc """
  Checks that `url` is absolute, `https`, or `http` to a loopback host.
  """
  @spec check_url(term()) :: :ok | {:error, {:insecure_url, term()}}
  def check_url(url) when is_binary(url) do
    case URI.new(url) do
      {:ok, %URI{scheme: "https", host: host}} when is_binary(host) and host != "" -> :ok
      {:ok, %URI{scheme: "http", host: host}} when host in @loopback -> :ok
      _other -> {:error, {:insecure_url, url}}
    end
  end

  def check_url(url), do: {:error, {:insecure_url, url}}

  defp request(config, url, method, request) do
    {:ok, _started} = Application.ensure_all_started([:inets, :ssl])

    http_options =
      [timeout: config.timeout_ms, connect_timeout: config.timeout_ms, autoredirect: false] ++
        ssl_options(url, config.ssl)

    case :httpc.request(method, request, http_options, body_format: :binary) do
      {:ok, {{_version, status, _reason}, _headers, body}}
      when byte_size(body) <= config.max_body_bytes ->
        {:ok, status, body}

      {:ok, {{_version, _status, _reason}, _headers, _body}} ->
        {:error, :body_too_large}

      {:error, reason} ->
        {:error, {:http_error, reason}}
    end
  end

  # A body that is not a JSON object decodes as nil; the caller judges the
  # status. A 2xx without a JSON object is an error, since every document
  # and token response the flow reads is one.
  defp decode({:ok, status, body}) do
    case JSON.decode(body) do
      {:ok, %{} = map} -> {:ok, status, map}
      _other when status in 200..299 -> {:error, {:invalid_json, status}}
      _other -> {:ok, status, nil}
    end
  end

  defp decode({:error, _reason} = error), do: error

  defp charlists(headers),
    do:
      Enum.map(headers, fn {name, value} ->
        {String.to_charlist(name), String.to_charlist(value)}
      end)

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
end
