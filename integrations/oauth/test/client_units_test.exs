defmodule Snodo.OAuth.ClientUnitsTest do
  use ExUnit.Case, async: true

  alias Snodo.OAuth.Client.ClientAuth
  alias Snodo.OAuth.Client.Discovery
  alias Snodo.OAuth.Client.HTTP
  alias Snodo.OAuth.Client.Loopback
  alias Snodo.OAuth.Client.PKCE

  describe "PKCE" do
    test "matches the RFC 7636 appendix B vector" do
      assert PKCE.challenge("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk") ==
               "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"
    end

    test "verifiers are 43 unreserved characters and fresh" do
      verifier = PKCE.verifier()
      assert String.length(verifier) == 43
      assert verifier =~ ~r/^[A-Za-z0-9_-]+$/
      refute PKCE.verifier() == verifier
    end
  end

  describe "Discovery.resource_allowed?/2" do
    test "accepts the same resource and a path prefix at a segment boundary" do
      assert Discovery.resource_allowed?(
               "https://mcp.example.com/mcp",
               "https://mcp.example.com/mcp"
             )

      assert Discovery.resource_allowed?("https://mcp.example.com/mcp", "https://mcp.example.com")

      assert Discovery.resource_allowed?(
               "https://mcp.example.com/mcp",
               "https://mcp.example.com/"
             )

      assert Discovery.resource_allowed?(
               "https://mcp.example.com/mcp/v1",
               "https://mcp.example.com/mcp"
             )

      assert Discovery.resource_allowed?(
               "https://MCP.example.com/mcp",
               "https://mcp.example.com/mcp"
             )

      assert Discovery.resource_allowed?(
               "https://mcp.example.com:443/mcp",
               "https://mcp.example.com/mcp"
             )
    end

    test "refuses another origin or a path that is not a prefix" do
      refute Discovery.resource_allowed?(
               "http://localhost:4000/mcp",
               "https://evil.example.com/mcp"
             )

      refute Discovery.resource_allowed?(
               "https://mcp.example.com/mcp",
               "https://mcp.example.com/mcpx"
             )

      refute Discovery.resource_allowed?(
               "https://mcp.example.com/mcp",
               "https://mcp.example.com/mcp/v1"
             )

      refute Discovery.resource_allowed?(
               "https://mcp.example.com/mcp",
               "https://mcp.example.com:8443/mcp"
             )

      refute Discovery.resource_allowed?(
               "https://mcp.example.com/mcp",
               "http://mcp.example.com/mcp"
             )

      refute Discovery.resource_allowed?("https://mcp.example.com/mcp", "mcp")
      refute Discovery.resource_allowed?("https://mcp.example.com/mcp", nil)
    end
  end

  describe "Discovery.issuer/1" do
    test "takes the first authorization server" do
      assert Discovery.issuer(%{"authorization_servers" => ["https://a", "https://b"]}) ==
               "https://a"

      assert Discovery.issuer(%{"authorization_servers" => []}) == nil
      assert Discovery.issuer(%{}) == nil
    end
  end

  describe "HTTP.check_url/1" do
    test "allows https and loopback http only" do
      assert HTTP.check_url("https://auth.example.com/token") == :ok
      assert HTTP.check_url("http://localhost:4000/token") == :ok
      assert HTTP.check_url("http://127.0.0.1:4000/token") == :ok
      assert {:error, {:insecure_url, _url}} = HTTP.check_url("http://auth.example.com/token")
      assert {:error, {:insecure_url, _url}} = HTTP.check_url("ftp://localhost/x")
      assert {:error, {:insecure_url, _url}} = HTTP.check_url("/relative")
      assert {:error, {:insecure_url, nil}} = HTTP.check_url(nil)
    end
  end

  describe "ClientAuth" do
    @config %{
      token_endpoint_auth_method: nil,
      private_key: nil,
      signing_algorithm: nil,
      client_assertion_audience: nil
    }

    test "picks the method from the configuration, the registration, then the credentials" do
      basic = %{"token_endpoint_auth_methods_supported" => ["client_secret_basic"]}
      post = %{"token_endpoint_auth_methods_supported" => ["client_secret_post"]}
      none = %{"token_endpoint_auth_methods_supported" => ["none"]}
      secret = %{client_id: "c", client_secret: "s", token_endpoint_auth_method: nil}
      public = %{client_id: "c", client_secret: nil, token_endpoint_auth_method: nil}

      assert ClientAuth.method(secret, basic, %{
               @config
               | token_endpoint_auth_method: "client_secret_post"
             }) ==
               "client_secret_post"

      assert ClientAuth.method(
               %{secret | token_endpoint_auth_method: "client_secret_post"},
               basic,
               @config
             ) ==
               "client_secret_post"

      assert ClientAuth.method(secret, basic, @config) == "client_secret_basic"
      assert ClientAuth.method(secret, post, @config) == "client_secret_post"
      assert ClientAuth.method(secret, none, @config) == "none"
      assert ClientAuth.method(secret, %{}, @config) == "client_secret_basic"
      assert ClientAuth.method(public, basic, @config) == "none"

      jwk = JOSE.JWK.generate_key({:ec, "P-256"})
      assert ClientAuth.method(public, basic, %{@config | private_key: jwk}) == "private_key_jwt"
    end

    test "asks for none in a registration when the server supports it" do
      assert ClientAuth.registration_method(
               %{"token_endpoint_auth_methods_supported" => ["none", "client_secret_basic"]},
               @config
             ) == "none"

      assert ClientAuth.registration_method(
               %{"token_endpoint_auth_methods_supported" => ["client_secret_post"]},
               @config
             ) == "client_secret_post"

      assert ClientAuth.registration_method(%{}, @config) == "client_secret_basic"
    end

    test "encodes basic credentials per RFC 6749 section 2.3.1" do
      identity = %{client_id: "id with space", client_secret: "s:e/c"}

      assert {:ok, fields, [{"authorization", "Basic " <> encoded}]} =
               ClientAuth.apply("client_secret_basic", identity, @config, %{}, [{"x", "y"}])

      assert Base.decode64!(encoded) == "id+with+space:s%3Ae%2Fc"
      assert fields == [{"client_id", "id with space"}, {"x", "y"}]

      assert {:error, :missing_client_secret} =
               ClientAuth.apply(
                 "client_secret_basic",
                 %{client_id: "c", client_secret: nil},
                 @config,
                 %{},
                 []
               )

      assert {:error, {:unsupported_token_endpoint_auth_method, "mtls"}} =
               ClientAuth.apply("mtls", identity, @config, %{}, [])
    end

    test "derives the signing algorithm from the key" do
      assert {:ok, "ES256"} = ClientAuth.algorithm(JOSE.JWK.generate_key({:ec, "P-256"}))
      assert {:ok, "ES384"} = ClientAuth.algorithm(JOSE.JWK.generate_key({:ec, "P-384"}))
      assert {:ok, "RS256"} = ClientAuth.algorithm(JOSE.JWK.generate_key({:rsa, 2048}))
      assert {:ok, "EdDSA"} = ClientAuth.algorithm(JOSE.JWK.generate_key({:okp, :Ed25519}))

      assert {:error, {:unsupported_key_type, "oct"}} =
               ClientAuth.algorithm(JOSE.JWK.generate_key({:oct, 32}))
    end

    test "reads keys as PEM, JWK map, or struct" do
      jwk = JOSE.JWK.generate_key({:ec, "P-256"})
      {_kty, map} = JOSE.JWK.to_map(jwk)
      {_kty, pem} = JOSE.JWK.to_pem(jwk)

      assert %JOSE.JWK{} = ClientAuth.jwk!(jwk)
      assert ClientAuth.jwk!(map) == jwk
      assert ClientAuth.jwk!(pem) == jwk
      assert_raise ArgumentError, ~r/PEM/, fn -> ClientAuth.jwk!("nonsense") end
      assert_raise ArgumentError, ~r/JWK map/, fn -> ClientAuth.jwk!(%{"kty" => "??"}) end
      assert_raise ArgumentError, ~r/must be/, fn -> ClientAuth.jwk!(42) end
    end
  end

  describe "Loopback" do
    test "binds on 127.0.0.1 and answers the callback once" do
      assert {:ok, listener} = Loopback.listen(port: 0, path: "/cb")
      assert listener.uri =~ ~r{^http://127\.0\.0\.1:\d+/cb$}
      ref = make_ref()
      acceptor = Loopback.accept(listener, self(), ref, 5_000)
      monitor = Process.monitor(acceptor)

      assert {:ok, {{_version, 404, _reason}, _headers, _body}} =
               :httpc.request(
                 :get,
                 {String.to_charlist(listener.uri <> "x"), []},
                 [timeout: 5_000],
                 body_format: :binary
               )

      assert {:ok, {{_version, 405, _reason}, _headers, _body}} =
               :httpc.request(
                 :post,
                 {String.to_charlist(listener.uri), [], ~c"text/plain", "x"},
                 [timeout: 5_000],
                 body_format: :binary
               )

      assert {:ok, {{_version, 200, _reason}, headers, body}} =
               :httpc.request(
                 :get,
                 {String.to_charlist(listener.uri <> "?code=abc&state=s+t"), []},
                 [timeout: 5_000],
                 body_format: :binary
               )

      assert body =~ "Authorization complete"
      assert {~c"cache-control", ~c"no-store"} in headers
      assert_receive {:redirect, ^ref, %{"code" => "abc", "state" => "s t"}}, 1_000
      assert_receive {:DOWN, ^monitor, :process, ^acceptor, :normal}, 1_000
      Loopback.close(listener)
    end

    test "gives up after the timeout" do
      assert {:ok, listener} = Loopback.listen([])
      acceptor = Loopback.accept(listener, self(), make_ref(), 50)
      monitor = Process.monitor(acceptor)
      assert_receive {:DOWN, ^monitor, :process, ^acceptor, :normal}, 1_000
      Loopback.close(listener)
    end

    test "checks its options" do
      assert_raise ArgumentError, ~r/:port/, fn -> Loopback.listen(port: 70_000) end
      assert_raise ArgumentError, ~r/:path/, fn -> Loopback.listen(path: "cb?x") end
    end
  end
end
