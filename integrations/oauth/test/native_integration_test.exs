defmodule Snodo.OAuth.ResourceServer.NativeIntegrationTest do
  use ExUnit.Case, async: true

  alias Snodo.OAuth.ResourceServer.JWKS
  alias Snodo.OAuth.ResourceServer.Native
  alias Snodo.OAuth.ResourceServer.ScopePolicy
  alias Snodo.OAuth.ResourceServer.Verifier.JWT
  alias Snodo.Transport.StreamableHTTP.Server, as: HTTPServer
  alias SnodoTest.OAuthFixtures, as: Fixtures

  @protocol "2026-07-28"
  @metadata_path "/.well-known/oauth-protected-resource/mcp"
  @metadata_url "https://mcp.example.test#{@metadata_path}"

  setup_all do
    %{rsa: Fixtures.rsa_key("rsa-1")}
  end

  setup %{rsa: rsa} do
    jwks = start_supervised!({JWKS, keys: [Fixtures.public_map(rsa)]})
    %{port: listen(jwks), jwks: jwks}
  end

  test "serves path-aware metadata without a token", %{port: port} do
    assert {200, headers, body} = exchange(port, "GET", @metadata_path)
    assert headers["content-type"] == "application/json; charset=utf-8"

    assert JSON.decode!(body) == %{
             "resource" => Fixtures.resource(),
             "authorization_servers" => [Fixtures.issuer()],
             "bearer_methods_supported" => ["header"],
             "scopes_supported" => ["mcp:read", "mcp:write"]
           }

    assert {200, head_headers, ""} = exchange(port, "HEAD", @metadata_path)
    assert head_headers["content-length"] == Integer.to_string(byte_size(body))

    assert {405, %{"allow" => "GET, HEAD"}, ""} =
             exchange(port, "POST", @metadata_path, [{"content-length", "0"}])

    assert {401, _, _} = exchange(port, "GET", "/.well-known/oauth-protected-resource")
  end

  test "rejects a missing token before waiting for the request body", %{port: port} do
    head =
      "POST /mcp HTTP/1.1\r\nhost: localhost\r\ncontent-length: 1000\r\nconnection: close\r\n\r\n"

    assert {401, headers, body} = raw_exchange(port, head)

    assert headers["www-authenticate"] ==
             ~s(Bearer scope="mcp:read", resource_metadata="#{@metadata_url}")

    assert JSON.decode!(body) == %{"error_description" => "A bearer token is required"}
  end

  test "rejects malformed, invalid, and under-scoped tokens", %{port: port, rsa: rsa} do
    request = request("tools/list", %{})

    assert {400, headers, %{"error" => "invalid_request"}} =
             rpc(port, request, ["Bearer bad token"])

    assert headers["www-authenticate"] =~ ~s(error="invalid_request")

    for claims <- [
          Fixtures.claims(%{"exp" => System.os_time(:second) - 60}),
          Fixtures.claims(%{"aud" => "https://other.example.test/mcp"}),
          Fixtures.claims(%{"iss" => "https://evil.example.test"})
        ] do
      token = Fixtures.sign(rsa, "RS256", claims)
      assert {401, headers, %{"error" => "invalid_token"}} = rpc(port, request, [token])
      assert headers["www-authenticate"] =~ ~s(resource_metadata="#{@metadata_url}")
    end

    token = Fixtures.sign(rsa, "RS256", Fixtures.claims(%{"scope" => "other"}))
    assert {403, headers, %{"error" => "insufficient_scope"}} = rpc(port, request, [token])
    assert headers["www-authenticate"] =~ ~s(scope="mcp:read")
  end

  test "passes verified identity to authorization and handlers", %{port: port, rsa: rsa} do
    reader = Fixtures.sign(rsa, "RS256", Fixtures.claims())
    writer = Fixtures.sign(rsa, "RS256", Fixtures.claims(%{"scope" => "mcp:read mcp:write"}))

    assert {200, _, %{"result" => %{"tools" => tools}}} =
             rpc(port, request("tools/list", %{}), [reader])

    assert Enum.map(tools, & &1["name"]) == ["read_thing"]

    read = request("tools/call", %{"name" => "read_thing", "arguments" => %{}})

    assert {200, _, %{"result" => %{"structuredContent" => content}}} =
             rpc(port, read, [reader])

    assert content == %{"principal" => "user-1", "scopes" => ["mcp:read"]}

    write = request("tools/call", %{"name" => "write_thing", "arguments" => %{}})
    assert {200, _, %{"error" => %{"code" => -32_003}}} = rpc(port, write, [reader])
    assert {200, _, %{"result" => result}} = rpc(port, write, [writer])
    assert result["content"] == [%{"type" => "text", "text" => "written"}]
  end

  test "refuses inconsistent resource configuration", %{jwks: jwks} do
    assert_raise ArgumentError, ~r/same resource/, fn ->
      Native.init(
        [
          metadata: [resource: Fixtures.resource(), authorization_servers: [Fixtures.issuer()]],
          bearer: [
            resource: "https://other.example.test/mcp",
            verifier: {JWT, keys: jwks, issuer: Fixtures.issuer()}
          ]
        ],
        %{path: "/mcp"}
      )
    end
  end

  test "refuses a resource path that differs from the listener", %{jwks: jwks} do
    opts = [
      metadata: [resource: Fixtures.resource(), authorization_servers: [Fixtures.issuer()]],
      bearer: [
        resource: Fixtures.resource(),
        verifier: {JWT, keys: jwks, issuer: Fixtures.issuer()}
      ]
    ]

    assert_raise ArgumentError, ~r/resource path must match/, fn ->
      Native.init(opts, %{path: "/private"})
    end
  end

  test "refuses a query-bearing resource", %{jwks: jwks} do
    resource = Fixtures.resource() <> "?tenant=a"

    assert_raise ArgumentError, ~r/must not contain a query/, fn ->
      Native.init(
        [
          metadata: [resource: resource, authorization_servers: [Fixtures.issuer()]],
          bearer: [resource: resource, verifier: {JWT, keys: jwks, issuer: Fixtures.issuer()}]
        ],
        %{path: "/mcp"}
      )
    end
  end

  defp listen(jwks) do
    router =
      Snodo.Router.new()
      |> Snodo.Router.register_tool(Fixtures.ReadTool)
      |> Snodo.Router.register_tool(Fixtures.WriteTool)

    runtime =
      Snodo.Server.Runtime.new(
        router: router,
        protocols: [Snodo.Protocol.V2026_07_28],
        server_info: %{"name" => "native-oauth", "version" => "0.1.0"},
        capabilities: %{"tools" => %{}},
        authorization: {ScopePolicy, required: %{{:tool, "write_thing"} => ["mcp:write"]}}
      )

    gate =
      {Native,
       metadata: [
         resource: Fixtures.resource(),
         authorization_servers: [Fixtures.issuer()],
         scopes_supported: ["mcp:read", "mcp:write"]
       ],
       bearer: [
         resource: Fixtures.resource(),
         verifier: {JWT, keys: jwks, issuer: Fixtures.issuer()},
         required_scopes: ["mcp:read"]
       ]}

    {:ok, server} = start_supervised({HTTPServer, runtime: runtime, port: 0, request_gate: gate})
    {_ip, port, "/mcp"} = HTTPServer.address(server)
    port
  end

  defp request(method, params) do
    %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => method,
      "params" =>
        Map.put(params, "_meta", %{
          "io.modelcontextprotocol/protocolVersion" => @protocol,
          "io.modelcontextprotocol/clientCapabilities" => %{}
        })
    }
  end

  defp rpc(port, request, tokens) do
    body = JSON.encode!(request)

    headers =
      [
        {"content-type", "application/json"},
        {"accept", "application/json, text/event-stream"},
        {"mcp-protocol-version", @protocol},
        {"mcp-method", request["method"]},
        {"content-length", to_string(byte_size(body))}
      ] ++
        if(name = get_in(request, ["params", "name"]), do: [{"mcp-name", name}], else: []) ++
        Enum.map(tokens, &{"authorization", "Bearer " <> &1})

    {status, response_headers, response_body} = exchange(port, "POST", "/mcp", headers, body)
    {status, response_headers, JSON.decode!(response_body)}
  end

  defp exchange(port, method, path, headers \\ [], body \\ "") do
    headers = [{"host", "localhost"}, {"connection", "close"} | headers]
    lines = Enum.map(headers, fn {name, value} -> [name, ": ", value, "\r\n"] end)
    raw_exchange(port, [method, " ", path, " HTTP/1.1\r\n", lines, "\r\n", body])
  end

  defp raw_exchange(port, request) do
    {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false], 1_000)
    :ok = :gen_tcp.send(socket, request)
    raw = read_all(socket)
    [head, body] = String.split(raw, "\r\n\r\n", parts: 2)
    [status_line | header_lines] = String.split(head, "\r\n")
    [_version, code | _reason] = String.split(status_line, " ")

    headers =
      Map.new(header_lines, fn line ->
        [name, value] = String.split(line, ": ", parts: 2)
        {String.downcase(name), value}
      end)

    {String.to_integer(code), headers, body}
  end

  defp read_all(socket, acc \\ "") do
    case :gen_tcp.recv(socket, 0, 5_000) do
      {:ok, data} -> read_all(socket, acc <> data)
      {:error, :closed} -> acc
      {:error, reason} -> flunk("HTTP read failed: #{inspect(reason)}; received #{inspect(acc)}")
    end
  end
end
