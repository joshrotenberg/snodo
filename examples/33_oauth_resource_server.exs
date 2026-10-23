defmodule Examples.OAuth.Server do
  @moduledoc false
  use Snodo.Server, name: "oauth-example", version: "1.0.0"

  tool "whoami", description: "Reports the verified caller" do
    @impl true
    def call(_arguments, context), do: {:ok, "hello, #{context.auth[:principal]}"}
  end
end

defmodule Examples.OAuth.Runner do
  @moduledoc false

  alias Examples.OAuth.Server
  alias Snodo.Client
  alias Snodo.OAuth.ResourceServer.JWKS
  alias Snodo.OAuth.ResourceServer.Native
  alias Snodo.OAuth.ResourceServer.Verifier.JWT

  @issuer "https://auth.example.test"

  def run(args) do
    check? = check_mode!(args)

    # A real deployment points JWKS at the authorization server's jwks_uri.
    # Here the example plays the authorization server: it generates a signing
    # key, gives the resource server only the public half, and mints tokens.
    signing_key =
      {:ec, "P-256"} |> JOSE.JWK.generate_key() |> JOSE.JWK.merge(%{"kid" => "example"})

    {:ok, _jwks} =
      JWKS.start_link(name: Examples.OAuth.JWKS, keys: [JOSE.JWK.to_public(signing_key)])

    port = free_port()
    resource = "http://127.0.0.1:#{port}/mcp"

    {:ok, _server} =
      Snodo.Transport.StreamableHTTP.Server.start_link(
        runtime: Server.runtime(),
        ip: {127, 0, 0, 1},
        port: port,
        path: "/mcp",
        request_gate:
          {Native,
           metadata: [resource: resource, authorization_servers: [@issuer]],
           bearer: [
             resource: resource,
             verifier: {JWT, keys: Examples.OAuth.JWKS, issuer: @issuer},
             required_scopes: ["mcp:read"]
           ]}
      )

    # A token with the required scope: the tool sees the verified subject.
    token = mint(signing_key, resource, "ada", "mcp:read")

    {:ok, client} =
      Client.connect({:http, resource}, headers: [{"authorization", "Bearer " <> token}])

    {:ok, %{"content" => [%{"text" => greeting}]}} = Client.call_tool(client, "whoami")
    ensure(greeting == "hello, ada", "verified principal")

    # No token: the gate answers 401 before the request reaches the server.
    # A client with an OAuth token provider (Snodo.OAuth.Client) would follow
    # the challenge and obtain a token instead.
    {:error, %Snodo.Error{cause: {:http_status, 401, _body}}} = Client.connect({:http, resource})

    # A token without the required scope: 403.
    narrow = mint(signing_key, resource, "ada", "mcp:other")

    {:error, %Snodo.Error{cause: {:http_status, 403, _body}}} =
      Client.connect({:http, resource}, headers: [{"authorization", "Bearer " <> narrow}])

    if check? do
      IO.puts("33_oauth_resource_server: ok")
    else
      IO.puts("With a token: #{greeting}")
      IO.puts("Without a token: 401; without the mcp:read scope: 403")
    end
  end

  defp mint(key, resource, subject, scope) do
    claims = %{
      "iss" => @issuer,
      "sub" => subject,
      "aud" => resource,
      "scope" => scope,
      "exp" => System.os_time(:second) + 300
    }

    {_alg, token} =
      key
      |> JOSE.JWT.sign(%{"alg" => "ES256", "kid" => "example"}, claims)
      |> JOSE.JWS.compact()

    token
  end

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, port} = :inet.port(socket)
    :ok = :gen_tcp.close(socket)
    port
  end

  defp ensure(true, _label), do: :ok
  defp ensure(false, label), do: raise("check failed: #{label}")

  defp check_mode!([]), do: false
  defp check_mode!(["--check"]), do: true

  defp check_mode!(_arguments),
    do: raise("usage: mix example.oauth (from integrations/oauth)")
end

Examples.OAuth.Runner.run(System.argv())
