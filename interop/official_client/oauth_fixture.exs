# A server protected by snodo_oauth, and the loopback authorization server
# that issues its tokens. The resource server holds no static keys: it
# fetches the authorization server's JWKS document like a deployment would.
project = Path.expand("../..", __DIR__)

build =
  cond do
    path = System.get_env("SNODO_OAUTH_BUILD") -> path
    path = System.get_env("MIX_BUILD_PATH") -> Path.join(path, "lib")
    true -> Path.join(project, "integrations/oauth/_build/dev/lib")
  end

ebins = Path.wildcard(Path.join(build, "*/ebin"))

if ebins == [] do
  raise "no compiled code under #{build}; run mix compile in integrations/oauth first"
end

Enum.each(ebins, &Code.prepend_path/1)
{:ok, _applications} = Application.ensure_all_started([:snodo_oauth, :bandit])

defmodule OAuthFixture.AS do
  @moduledoc false
  # Authorization server: metadata (RFC 8414), dynamic client registration
  # (RFC 7591), the authorization code flow with PKCE S256 and the resource
  # parameter (RFC 8707), the client credentials grant, and the JWKS. Every
  # refusal carries a description, so a failing check shows which rule broke.
  @behaviour Plug

  import Plug.Conn

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    route(conn.method, conn.path_info, conn)
  end

  defp route("GET", [".well-known", "oauth-authorization-server"], conn) do
    issuer = config(:issuer)

    json(conn, 200, %{
      "issuer" => issuer,
      "authorization_endpoint" => issuer <> "/authorize",
      "token_endpoint" => issuer <> "/token",
      "registration_endpoint" => issuer <> "/register",
      "jwks_uri" => issuer <> "/jwks",
      "response_types_supported" => ["code"],
      "grant_types_supported" => ["authorization_code", "client_credentials"],
      "code_challenge_methods_supported" => ["S256"],
      "token_endpoint_auth_methods_supported" => ["none", "client_secret_basic"],
      "scopes_supported" => config(:scopes),
      "authorization_response_iss_parameter_supported" => true
    })
  end

  defp route("GET", ["jwks"], conn) do
    {_fields, public} = config(:signing_key) |> JOSE.JWK.to_public() |> JOSE.JWK.to_map()
    json(conn, 200, %{"keys" => [Map.merge(public, %{"use" => "sig", "alg" => "ES256"})]})
  end

  defp route("POST", ["register"], conn) do
    {:ok, body, conn} = read_body(conn)
    metadata = JSON.decode!(body)

    case metadata["redirect_uris"] do
      [_ | _] = uris ->
        client_id = "dcr-" <> random()
        remember({:client, client_id}, uris)

        json(
          conn,
          201,
          Map.merge(metadata, %{
            "client_id" => client_id,
            "client_id_issued_at" => System.os_time(:second),
            "token_endpoint_auth_method" => "none"
          })
        )

      _missing ->
        refuse(conn, "invalid_redirect_uri", "redirect_uris is required")
    end
  end

  defp route("GET", ["authorize"], conn) do
    query = URI.decode_query(conn.query_string)
    redirect_uris = recall({:client, query["client_id"]})

    cond do
      redirect_uris == nil ->
        refuse(conn, "invalid_client", "client_id is not registered")

      query["redirect_uri"] not in redirect_uris ->
        refuse(conn, "invalid_request", "redirect_uri is not registered")

      query["response_type"] != "code" ->
        refuse(conn, "unsupported_response_type", "response_type must be code")

      query["code_challenge_method"] != "S256" or query["code_challenge"] in [nil, ""] ->
        refuse(conn, "invalid_request", "a PKCE S256 code_challenge is required")

      query["resource"] != config(:resource) ->
        refuse(conn, "invalid_target", "resource must name the MCP server")

      true ->
        code = random()
        remember({:code, code}, query)

        location =
          query["redirect_uri"] <>
            "?" <>
            URI.encode_query(%{
              "code" => code,
              "state" => query["state"],
              "iss" => config(:issuer)
            })

        conn |> put_resp_header("location", location) |> send_resp(302, "")
    end
  end

  defp route("POST", ["token"], conn) do
    {:ok, body, conn} = read_body(conn)
    params = URI.decode_query(body)

    cond do
      Map.has_key?(params, "resource") and params["resource"] != config(:resource) ->
        refuse(conn, "invalid_target", "resource must name the MCP server")

      params["grant_type"] == "authorization_code" ->
        authorization_code(conn, params)

      params["grant_type"] == "client_credentials" ->
        client_credentials(conn, params)

      true ->
        refuse(conn, "unsupported_grant_type", "unsupported grant_type")
    end
  end

  defp route(_method, _path, conn), do: json(conn, 404, %{"error" => "not_found"})

  defp authorization_code(conn, params) do
    request = forget({:code, params["code"]})

    cond do
      request == nil ->
        refuse(conn, "invalid_grant", "unknown or reused code")

      params["client_id"] != request["client_id"] ->
        refuse(conn, "invalid_grant", "code was issued to another client")

      params["redirect_uri"] != request["redirect_uri"] ->
        refuse(conn, "invalid_grant", "redirect_uri differs from the authorization request")

      challenge(params["code_verifier"]) != request["code_challenge"] ->
        refuse(conn, "invalid_grant", "code_verifier does not match the code_challenge")

      true ->
        issue(conn, "interop-user", request["client_id"], request["scope"])
    end
  end

  defp client_credentials(conn, params) do
    expected = "Basic " <> Base.encode64(config(:client_id) <> ":" <> config(:client_secret))

    if get_req_header(conn, "authorization") == [expected] do
      issue(conn, config(:client_id), config(:client_id), params["scope"])
    else
      json(conn, 401, %{"error" => "invalid_client", "error_description" => "bad credentials"})
    end
  end

  defp issue(conn, subject, client_id, scope) do
    now = System.os_time(:second)

    claims = %{
      "iss" => config(:issuer),
      "sub" => subject,
      "aud" => config(:resource),
      "client_id" => client_id,
      "scope" => scope || "",
      "iat" => now,
      "exp" => now + 300,
      "jti" => random()
    }

    {_alg, token} =
      config(:signing_key)
      |> JOSE.JWT.sign(%{"alg" => "ES256", "kid" => "interop", "typ" => "at+jwt"}, claims)
      |> JOSE.JWS.compact()

    json(conn, 200, %{
      "access_token" => token,
      "token_type" => "Bearer",
      "expires_in" => 300,
      "scope" => claims["scope"]
    })
  end

  defp challenge(nil), do: nil
  defp challenge(verifier), do: Base.url_encode64(:crypto.hash(:sha256, verifier), padding: false)

  defp refuse(conn, error, description),
    do: json(conn, 400, %{"error" => error, "error_description" => description})

  defp json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, JSON.encode!(body))
  end

  defp random, do: Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)
  defp config(key), do: :persistent_term.get({__MODULE__, key})
  defp remember(key, value), do: Agent.update(__MODULE__, &Map.put(&1, key, value))
  defp recall(key), do: Agent.get(__MODULE__, &Map.get(&1, key))
  defp forget(key), do: Agent.get_and_update(__MODULE__, &Map.pop(&1, key))
end

defmodule OAuthFixture.Server do
  @moduledoc false
  use Snodo.Server,
    name: "oauth-interop-fixture",
    version: "1.0.0",
    protocols: [Snodo.Protocol.V2026_07_28],
    authorization:
      {Snodo.OAuth.ResourceServer.ScopePolicy, required: %{{:tool, "publish"} => ["mcp:write"]}}

  tool "whoami", description: "Reports the verified principal and client" do
    @impl true
    def call(_arguments, context) do
      {:ok,
       Snodo.Result.text(JSON.encode!(Map.take(context.auth, [:principal, :client_id, :scopes])))}
    end
  end

  tool "publish", description: "Needs the mcp:write scope" do
    @impl true
    def call(_arguments, _context), do: {:ok, Snodo.Result.text("published")}
  end
end

defmodule OAuthFixture.Endpoint do
  @moduledoc false
  # The composition the snodo_oauth README gives for Bandit.
  @behaviour Plug

  alias Snodo.OAuth.ResourceServer.Bearer
  alias Snodo.OAuth.ResourceServer.Metadata

  @impl true
  def init(opts) do
    %{
      metadata: Metadata.init(Keyword.fetch!(opts, :metadata)),
      bearer: Bearer.init(Keyword.fetch!(opts, :bearer)),
      transport: Snodo.Transport.Plug.init(Keyword.fetch!(opts, :transport))
    }
  end

  @impl true
  def call(conn, plugs) do
    conn
    |> Metadata.call(plugs.metadata)
    |> Bearer.call(plugs.bearer)
    |> Snodo.Transport.Plug.call(plugs.transport)
  end
end

free_port = fn ->
  {:ok, socket} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
  {:ok, port} = :inet.port(socket)
  :ok = :gen_tcp.close(socket)
  port
end

{:ok, _state} = Agent.start_link(fn -> %{} end, name: OAuthFixture.AS)

{:ok, as_listener} =
  Bandit.start_link(plug: OAuthFixture.AS, ip: {127, 0, 0, 1}, port: 0, startup_log: false)

{:ok, {_ip, as_port}} = ThousandIsland.listener_info(as_listener)
issuer = "http://127.0.0.1:#{as_port}"
mcp_port = free_port.()
resource = "http://127.0.0.1:#{mcp_port}/mcp"
scopes = ["mcp:read", "mcp:write"]

signing_key =
  {:ec, "P-256"} |> JOSE.JWK.generate_key() |> JOSE.JWK.merge(%{"kid" => "interop"})

for {key, value} <- [
      issuer: issuer,
      resource: resource,
      scopes: scopes,
      signing_key: signing_key,
      client_id: "interop-service",
      client_secret: Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)
    ] do
  :persistent_term.put({OAuthFixture.AS, key}, value)
end

{:ok, _jwks} =
  Snodo.OAuth.ResourceServer.JWKS.start_link(name: OAuthFixture.JWKS, url: issuer <> "/jwks")

metadata = [resource: resource, authorization_servers: [issuer], scopes_supported: scopes]

bearer = [
  resource: resource,
  verifier: {Snodo.OAuth.ResourceServer.Verifier.JWT, keys: OAuthFixture.JWKS, issuer: issuer},
  required_scopes: ["mcp:read"]
]

runtime = OAuthFixture.Server.runtime()

stop =
  case System.argv() do
    ["--native"] ->
      {:ok, listener} =
        Snodo.Transport.StreamableHTTP.Server.start_link(
          runtime: runtime,
          ip: {127, 0, 0, 1},
          port: mcp_port,
          path: "/mcp",
          request_gate: {Snodo.OAuth.ResourceServer.Native, metadata: metadata, bearer: bearer}
        )

      fn -> GenServer.stop(listener) end

    ["--plug"] ->
      {:ok, executor} = Snodo.Server.Executor.start_link(max_concurrency: 8, max_queue: 16)

      {:ok, listener} =
        Bandit.start_link(
          plug:
            {OAuthFixture.Endpoint,
             metadata: metadata,
             bearer: bearer,
             transport: [runtime: runtime, executor: executor, path: "/mcp"]},
          ip: {127, 0, 0, 1},
          port: mcp_port,
          startup_log: false
        )

      fn -> Supervisor.stop(listener) end

    _arguments ->
      raise "usage: elixir oauth_fixture.exs --native|--plug"
  end

IO.puts(
  JSON.encode!(%{
    "resource" => resource,
    "issuer" => issuer,
    "clientId" => :persistent_term.get({OAuthFixture.AS, :client_id}),
    "clientSecret" => :persistent_term.get({OAuthFixture.AS, :client_secret})
  })
)

_input = IO.read(:stdio, :eof)
:ok = stop.()
