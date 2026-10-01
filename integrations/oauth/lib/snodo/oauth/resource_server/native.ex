defmodule Snodo.OAuth.ResourceServer.Native do
  @moduledoc """
  OAuth request gate for the native Streamable HTTP listener.

  Configure it as `:request_gate` on
  `Snodo.Transport.StreamableHTTP.Server`. The metadata document is public;
  other requests pass through the same bearer verifier and scope checks as
  `Snodo.OAuth.ResourceServer.Bearer`. The gate runs after the HTTP request
  head is parsed and before its body is read.

      request_gate: {Snodo.OAuth.ResourceServer.Native,
        metadata: [
          resource: "https://mcp.example.com/mcp",
          authorization_servers: ["https://auth.example.com"]
        ],
        bearer: [
          resource: "https://mcp.example.com/mcp",
          verifier: {Snodo.OAuth.ResourceServer.Verifier.JWT,
            keys: MyApp.JWKS, issuer: "https://auth.example.com"},
          required_scopes: ["mcp:read"]
        ]}

  The metadata and bearer options have the same meaning as their Plug
  counterparts. Both must name the same resource. The resource URI cannot
  have a query, and the listener's `:path` must match its path. A TLS reverse
  proxy may give the resource an `https` URL while the listener binds locally
  over HTTP.
  """

  @behaviour Snodo.Transport.StreamableHTTP.RequestGate

  alias Snodo.OAuth.ResourceServer
  alias Snodo.OAuth.ResourceServer.Bearer
  alias Snodo.OAuth.ResourceServer.Metadata
  alias Snodo.Transport.StreamableHTTP.Request
  alias Snodo.Transport.StreamableHTTP.Response

  @impl true
  def init(opts, %{path: listener_path}) when is_list(opts) do
    metadata_opts = Keyword.fetch!(opts, :metadata)
    bearer_opts = Keyword.fetch!(opts, :bearer)
    metadata = Metadata.init(metadata_opts)
    resource = Metadata.document(metadata_opts)["resource"]

    if ResourceServer.resource!(Keyword.fetch!(bearer_opts, :resource)) != resource do
      raise ArgumentError, "metadata and bearer options must name the same resource"
    end

    uri = URI.parse(resource)

    if uri.query do
      raise ArgumentError, "native listener resource must not contain a query"
    end

    if (uri.path || "/") != listener_path do
      raise ArgumentError, "resource path must match the native listener path"
    end

    %{metadata: metadata, bearer: Bearer.init(bearer_opts)}
  end

  @impl true
  def check(%Request{path: path, method: method}, %{metadata: %{path: path} = metadata}) do
    case method do
      "GET" ->
        {:response, metadata_response(metadata.body)}

      "HEAD" ->
        {:response,
         %Response{
           status: 200,
           headers: [
             {"content-type", "application/json; charset=utf-8"},
             {"content-length", Integer.to_string(byte_size(metadata.body))}
           ]
         }}

      _other ->
        {:response, %Response{status: 405, headers: [{"allow", "GET, HEAD"}]}}
    end
  end

  def check(%Request{headers: headers}, %{bearer: bearer}) do
    case Bearer.authorize(headers, bearer) do
      {:ok, auth} ->
        {:ok, auth}

      {:error, status, challenge, body} ->
        {:response,
         %Response{
           status: status,
           headers: [
             {"www-authenticate", challenge},
             {"content-type", "application/json; charset=utf-8"}
           ],
           body: body
         }}
    end
  end

  defp metadata_response(body) do
    %Response{
      status: 200,
      headers: [{"content-type", "application/json; charset=utf-8"}],
      body: body
    }
  end
end
