defmodule Snodo.OAuth.ResourceServer.Metadata do
  @moduledoc """
  Serves the OAuth 2.0 protected resource metadata document (RFC 9728).

  The document tells an MCP client which authorization servers issue tokens
  for this resource. It is served at the well-known path derived from the
  resource identifier: `/.well-known/oauth-protected-resource` for a resource
  at the root of its host, or `/.well-known/oauth-protected-resource/mcp` for
  `https://mcp.example.com/mcp`. Put the plug before the bearer plug, so the
  document is reachable without a token, or mount it on that path in a
  router. Other paths pass through untouched.

      plug Snodo.OAuth.ResourceServer.Metadata,
        resource: "https://mcp.example.com/mcp",
        authorization_servers: ["https://auth.example.com"],
        scopes_supported: ["mcp:read", "mcp:write"]

  `GET` and `HEAD` return the document as `application/json`; another
  method gets 405.

  ## Options

  | Option | Default | Meaning |
  |---|---|---|
  | `:resource` | required | The canonical resource URI; see `Snodo.OAuth.ResourceServer.resource!/1` |
  | `:authorization_servers` | required | Issuer URLs of the authorization servers, at least one |
  | `:scopes_supported` | omitted | Scopes a client may request; clients without a scope challenge request all of them |
  | `:bearer_methods_supported` | `["header"]` | Where a token is accepted; the bearer plug reads only the header |
  | `:resource_name` | omitted | Human-readable name of the resource |
  | `:extra` | `%{}` | Further RFC 9728 fields, with string keys; the options above take precedence |
  | `:path` | derived from `:resource` | The request path that serves the document |

  The plug does not set CORS headers. A browser-based client fetching the
  document from another origin needs the application to add them.
  """

  @behaviour Plug

  alias Plug.Conn
  alias Snodo.OAuth.ResourceServer

  @scope_token ~r/\A[\x21\x23-\x5B\x5D-\x7E]+\z/

  @impl true
  def init(opts) do
    document = document(opts)

    path =
      case Keyword.get(opts, :path, ResourceServer.metadata_path(document["resource"])) do
        "/" <> _ = path -> path
        other -> raise ArgumentError, ":path must be an absolute path, got: #{inspect(other)}"
      end

    %{path: path, body: JSON.encode!(document)}
  end

  @impl true
  def call(%Conn{halted: true} = conn, _opts), do: conn

  def call(%Conn{request_path: path} = conn, %{path: path} = opts) do
    if conn.method in ["GET", "HEAD"] do
      conn
      |> Conn.put_resp_content_type("application/json")
      |> Conn.send_resp(200, opts.body)
      |> Conn.halt()
    else
      conn
      |> Conn.put_resp_header("allow", "GET, HEAD")
      |> Conn.send_resp(405, "")
      |> Conn.halt()
    end
  end

  def call(%Conn{} = conn, _opts), do: conn

  @doc """
  Builds the metadata document from the same options as `init/1`.
  """
  @spec document(keyword()) :: %{optional(String.t()) => term()}
  def document(opts) when is_list(opts) do
    resource = ResourceServer.resource!(required!(opts, :resource))

    Keyword.get(opts, :extra, %{})
    |> extra!()
    |> Map.merge(%{
      "resource" => resource,
      "authorization_servers" => strings!(opts, :authorization_servers, :required),
      "bearer_methods_supported" => strings!(opts, :bearer_methods_supported, ["header"])
    })
    |> put_optional("scopes_supported", scopes!(opts))
    |> put_optional("resource_name", optional_string!(opts, :resource_name))
  end

  defp required!(opts, key) do
    case Keyword.get(opts, key) do
      nil -> raise ArgumentError, "#{inspect(key)} is required"
      value -> value
    end
  end

  defp put_optional(document, _key, nil), do: document
  defp put_optional(document, key, value), do: Map.put(document, key, value)

  defp extra!(%{} = extra) do
    if Enum.all?(Map.keys(extra), &is_binary/1),
      do: extra,
      else: raise(ArgumentError, ":extra must have string keys, got: #{inspect(extra)}")
  end

  defp extra!(other), do: raise(ArgumentError, ":extra must be a map, got: #{inspect(other)}")

  defp scopes!(opts) do
    case strings!(opts, :scopes_supported, nil) do
      nil -> nil
      scopes -> Enum.map(scopes, &scope_token!/1)
    end
  end

  defp scope_token!(scope) do
    if Regex.match?(@scope_token, scope),
      do: scope,
      else:
        raise(
          ArgumentError,
          "scope must match the RFC 6749 scope-token syntax: #{inspect(scope)}"
        )
  end

  defp strings!(opts, key, default) do
    case Keyword.get(opts, key, default) do
      :required ->
        raise ArgumentError, "#{inspect(key)} is required"

      nil ->
        nil

      [_ | _] = values ->
        if Enum.all?(values, &is_binary/1),
          do: values,
          else:
            raise(
              ArgumentError,
              "#{inspect(key)} must be a list of strings, got: #{inspect(values)}"
            )

      other ->
        raise ArgumentError,
              "#{inspect(key)} must be a non-empty list of strings, got: #{inspect(other)}"
    end
  end

  defp optional_string!(opts, key) do
    case Keyword.get(opts, key) do
      nil -> nil
      value when is_binary(value) -> value
      other -> raise ArgumentError, "#{inspect(key)} must be a string, got: #{inspect(other)}"
    end
  end
end
