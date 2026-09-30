defmodule Snodo.OAuth.Client.Discovery do
  @moduledoc """
  Discovery of the protected resource metadata (RFC 9728) and the
  authorization server metadata (RFC 8414 and OpenID Connect Discovery) for
  an MCP server, as the MCP authorization specification orders it.

  `Snodo.OAuth.Client` runs these on every authorization, so a change of
  authorization server in the resource's metadata is noticed. The functions
  are public so an application can inspect what a server publishes.
  """

  alias Snodo.OAuth.Client.HTTP

  @typedoc """
  Settings for the requests: a keyword list or map with `:timeout_ms`
  (default 10,000), `:max_body_bytes` (default 262,144), and `:ssl`, the
  `:ssl` client options for `https` (default: peer verification against the
  operating system's trust store). Every URL must be `https`, or `http` to a
  loopback host.
  """
  @type http ::
          keyword()
          | %{
              timeout_ms: pos_integer(),
              max_body_bytes: pos_integer(),
              ssl: keyword() | nil
            }

  @prm_well_known "/.well-known/oauth-protected-resource"
  @as_well_known "/.well-known/oauth-authorization-server"
  @oidc_well_known "/.well-known/openid-configuration"

  @doc """
  Fetches the protected resource metadata for `resource`, the canonical
  server URL.

  With `metadata_url`, the `resource_metadata` value of a `WWW-Authenticate`
  challenge, only that URL is fetched. Without one, the path-based
  well-known location is tried first and the root one second, per RFC 9728.
  The document's `resource` must name the server: the same scheme, host,
  and port, with a path that is the server path or a prefix of it at a
  segment boundary. A document for another resource is refused with
  `{:error, {:resource_mismatch, requested, configured}}`, and no
  authorization starts.
  """
  @spec protected_resource(http(), String.t(), String.t() | nil) ::
          {:ok, map()} | {:error, term()}
  def protected_resource(http, resource, metadata_url \\ nil) do
    urls = if metadata_url, do: [metadata_url], else: prm_urls(resource)

    with {:ok, metadata} <- fetch_first(settings(http), urls, :no_protected_resource_metadata),
         :ok <- check_resource(metadata, resource) do
      {:ok, metadata}
    end
  end

  @doc """
  Fetches the authorization server metadata for `issuer`.

  For an issuer without a path the RFC 8414 document at
  `/.well-known/oauth-authorization-server` is tried, then the OpenID
  configuration at `/.well-known/openid-configuration`. For an issuer with a
  path, the well-known segment is inserted before the path for both, and
  the OpenID configuration is also tried after the path. The `issuer` in the
  document must equal `issuer` exactly (RFC 8414 section 3.3, no
  normalization); otherwise `{:error, {:issuer_mismatch, issuer, found}}`.
  """
  @spec authorization_server(http(), String.t()) :: {:ok, map()} | {:error, term()}
  def authorization_server(http, issuer) do
    with {:ok, urls} <- as_urls(issuer),
         {:ok, metadata} <-
           fetch_first(settings(http), urls, {:no_authorization_server_metadata, issuer}),
         :ok <- check_issuer(metadata, issuer),
         :ok <- check_endpoint(metadata, "token_endpoint") do
      {:ok, metadata}
    end
  end

  @doc "The issuer an MCP server's metadata names, or `nil`."
  @spec issuer(map()) :: String.t() | nil
  def issuer(%{"authorization_servers" => [issuer | _others]}) when is_binary(issuer), do: issuer
  def issuer(_metadata), do: nil

  @doc """
  Whether `requested`, the server URL, is covered by `configured`, the
  `resource` in the protected resource metadata.
  """
  @spec resource_allowed?(String.t(), String.t()) :: boolean()
  def resource_allowed?(requested, configured)
      when is_binary(requested) and is_binary(configured) do
    with {:ok, %URI{} = wanted} <- URI.new(requested),
         {:ok, %URI{} = given} <- URI.new(configured),
         true <- same_origin?(wanted, given) do
      wanted_path = path(wanted)
      given_path = path(given)

      given_path == "/" or wanted_path == given_path or
        String.starts_with?(wanted_path, String.trim_trailing(given_path, "/") <> "/")
    else
      _other -> false
    end
  end

  def resource_allowed?(_requested, _configured), do: false

  defp settings(http) when is_list(http), do: HTTP.config(http)
  defp settings(%{} = http), do: http

  defp prm_urls(resource) do
    %URI{path: path} = uri = URI.parse(resource)
    origin = origin(uri)

    case path do
      nil ->
        [origin <> @prm_well_known]

      "" ->
        [origin <> @prm_well_known]

      "/" ->
        [origin <> @prm_well_known]

      path ->
        [origin <> @prm_well_known <> String.trim_trailing(path, "/"), origin <> @prm_well_known]
    end
  end

  defp as_urls(issuer) do
    case URI.new(issuer) do
      {:ok, %URI{scheme: scheme, host: host, fragment: nil, query: nil} = uri}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        origin = origin(uri)

        case String.trim_trailing(uri.path || "", "/") do
          "" ->
            {:ok, [origin <> @as_well_known, origin <> @oidc_well_known]}

          path ->
            {:ok,
             [
               origin <> @as_well_known <> path,
               origin <> @oidc_well_known <> path,
               origin <> path <> @oidc_well_known
             ]}
        end

      _other ->
        {:error, {:invalid_issuer, issuer}}
    end
  end

  # The first document served with a JSON object body wins; any other status
  # moves to the next location. A transport failure is returned as it is.
  defp fetch_first(_http, [], reason), do: {:error, reason}

  defp fetch_first(http, [url | rest], reason) do
    case HTTP.get_json(http, url) do
      {:ok, 200, %{} = metadata} -> {:ok, metadata}
      {:ok, _status, _body} -> fetch_first(http, rest, reason)
      {:error, {:invalid_json, _status}} -> fetch_first(http, rest, reason)
      {:error, _other} = error -> error
    end
  end

  defp check_resource(%{"resource" => configured}, requested) when is_binary(configured) do
    if resource_allowed?(requested, configured),
      do: :ok,
      else: {:error, {:resource_mismatch, requested, configured}}
  end

  defp check_resource(_metadata, requested), do: {:error, {:resource_mismatch, requested, nil}}

  defp check_issuer(%{"issuer" => found}, issuer) when found == issuer, do: :ok

  defp check_issuer(metadata, issuer),
    do: {:error, {:issuer_mismatch, issuer, metadata["issuer"]}}

  defp check_endpoint(metadata, name) do
    case metadata do
      %{^name => url} when is_binary(url) -> :ok
      _other -> {:error, {:missing_endpoint, name}}
    end
  end

  defp origin(%URI{scheme: scheme, host: host, port: port}) do
    host = if String.contains?(host, ":"), do: "[#{host}]", else: host
    default = URI.default_port(scheme)
    if port in [nil, default], do: "#{scheme}://#{host}", else: "#{scheme}://#{host}:#{port}"
  end

  defp same_origin?(%URI{} = a, %URI{} = b) do
    is_binary(a.scheme) and is_binary(b.scheme) and is_binary(a.host) and is_binary(b.host) and
      String.downcase(a.scheme) == String.downcase(b.scheme) and
      String.downcase(a.host) == String.downcase(b.host) and a.port == b.port
  end

  defp path(%URI{path: path}) when path in [nil, ""], do: "/"
  defp path(%URI{path: path}), do: path
end
