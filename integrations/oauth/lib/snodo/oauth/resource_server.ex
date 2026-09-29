defmodule Snodo.OAuth.ResourceServer do
  @moduledoc """
  The OAuth 2.1 resource-server side of the MCP authorization specification.

  An MCP server over HTTP is an OAuth 2.1 resource server: it publishes
  protected resource metadata (RFC 9728), requires a bearer token on every
  request, validates the token's signature, lifetime, and audience (RFC 8707),
  and answers a missing or invalid token with a `WWW-Authenticate` challenge
  that names the metadata document. This package supplies those parts as
  plugs and a verifier, ahead of `Snodo.Transport.Plug`:

  | Module | Role |
  |---|---|
  | `Snodo.OAuth.ResourceServer.Metadata` | Serves the RFC 9728 document at its well-known path |
  | `Snodo.OAuth.ResourceServer.Bearer` | Extracts and checks the token, sets the trusted `:mcp_auth` assign, answers 400, 401, and 403 |
  | `Snodo.OAuth.ResourceServer.Verifier` | The token verification behaviour |
  | `Snodo.OAuth.ResourceServer.Verifier.JWT` | JWS verification against a JWKS document or static keys |
  | `Snodo.OAuth.ResourceServer.JWKS` | Bounded, rate-limited key cache |
  | `Snodo.OAuth.ResourceServer.ScopePolicy` | `Snodo.Authorization` policy keyed on granted scopes |

  The functions here derive the metadata location from a resource identifier
  and compare audiences. The identifier is the canonical URI clients send as
  the RFC 8707 `resource` parameter: an absolute `http` or `https` URI with a
  host and no fragment, such as `https://mcp.example.com/mcp`.
  """

  @well_known "/.well-known/oauth-protected-resource"

  @doc """
  Validates a resource identifier and returns it in canonical form.

  The scheme and host are lowercased and a lone trailing slash is removed,
  so `https://MCP.example.com/` becomes `https://mcp.example.com`. Any other
  path is kept exactly. Raises `ArgumentError` for a relative URI, a scheme
  other than `http` or `https`, a missing host, or a fragment.
  """
  @spec resource!(String.t()) :: String.t()
  def resource!(resource) when is_binary(resource) do
    uri = URI.parse(resource)

    cond do
      uri.scheme == nil or String.downcase(uri.scheme) not in ["http", "https"] ->
        raise ArgumentError,
              "resource must be an absolute http or https URI: #{inspect(resource)}"

      uri.host in [nil, ""] ->
        raise ArgumentError, "resource must have a host: #{inspect(resource)}"

      uri.fragment != nil ->
        raise ArgumentError, "resource must not have a fragment: #{inspect(resource)}"

      true ->
        canonical(uri)
    end
  end

  def resource!(other) do
    raise ArgumentError, "resource must be a string, got: #{inspect(other)}"
  end

  @doc """
  The path of the protected resource metadata document for `resource`.

  Per RFC 9728, a resource whose path is empty or `/` serves its metadata at
  `/.well-known/oauth-protected-resource`; otherwise the well-known segment is
  inserted between the host and the path, so `https://mcp.example.com/mcp`
  serves it at `/.well-known/oauth-protected-resource/mcp`.
  """
  @spec metadata_path(String.t()) :: String.t()
  def metadata_path(resource) when is_binary(resource) do
    case URI.parse(resource!(resource)).path do
      nil -> @well_known
      "" -> @well_known
      "/" -> @well_known
      path -> @well_known <> String.trim_trailing(path, "/")
    end
  end

  @doc """
  The URL of the protected resource metadata document for `resource`, for
  the `resource_metadata` parameter of a `WWW-Authenticate` challenge.
  """
  @spec metadata_url(String.t()) :: String.t()
  def metadata_url(resource) when is_binary(resource) do
    uri = URI.parse(resource!(resource))
    query = if uri.query, do: "?" <> uri.query, else: ""

    to_string(%URI{uri | path: metadata_path(resource), query: nil, fragment: nil}) <> query
  end

  @doc """
  Whether an `aud` claim names one of `accepted`.

  `aud` is a string or a list of strings, as RFC 7519 allows. Values are
  compared after the same normalization as `resource!/1`, so scheme and host
  case and a lone trailing slash do not matter; any other difference does.
  """
  @spec audience_match?(term(), [String.t()]) :: boolean()
  def audience_match?(aud, accepted) when is_binary(aud) and is_list(accepted) do
    normalized = normalize_audience(aud)
    Enum.any?(accepted, &(normalize_audience(&1) == normalized))
  end

  def audience_match?(aud, accepted) when is_list(aud) and is_list(accepted) do
    Enum.any?(aud, &(is_binary(&1) and audience_match?(&1, accepted)))
  end

  def audience_match?(_aud, _accepted), do: false

  defp normalize_audience(value) do
    uri = URI.parse(value)

    if uri.scheme != nil and uri.host not in [nil, ""],
      do: canonical(uri),
      else: value
  end

  defp canonical(%URI{} = uri) do
    path =
      case uri.path do
        "/" -> nil
        path -> path
      end

    to_string(%URI{
      uri
      | scheme: String.downcase(uri.scheme),
        host: String.downcase(uri.host),
        path: path,
        authority: nil
    })
  end
end
