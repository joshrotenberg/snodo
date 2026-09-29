defmodule Snodo.OAuth.ResourceServer.PlugIntegrationTest do
  use ExUnit.Case, async: true

  alias Snodo.OAuth.ResourceServer.JWKS
  alias Snodo.OAuth.ResourceServer.ScopePolicy
  alias Snodo.OAuth.ResourceServer.Verifier.JWT
  alias Snodo.Server.Executor
  alias SnodoTest.OAuthFixtures, as: Fixtures

  @protocol "2026-07-28"
  @version_key "io.modelcontextprotocol/protocolVersion"
  @capabilities_key "io.modelcontextprotocol/clientCapabilities"
  @metadata_url "https://mcp.example.test/.well-known/oauth-protected-resource/mcp"

  setup_all do
    %{rsa: Fixtures.rsa_key("rsa-1")}
  end

  setup %{rsa: rsa} do
    jwks = start_supervised!({JWKS, keys: [Fixtures.public_map(rsa)]})
    %{port: listen(jwks, Fixtures.resource(), :prefixed), jwks: jwks}
  end

  test "the metadata document is served without a token", %{port: port} do
    assert {200, headers, body} = get(port, "/.well-known/oauth-protected-resource/mcp")
    assert headers["content-type"] == "application/json; charset=utf-8"

    assert JSON.decode!(body) == %{
             "resource" => "https://mcp.example.test/mcp",
             "authorization_servers" => ["https://auth.example.test"],
             "bearer_methods_supported" => ["header"],
             "scopes_supported" => ["mcp:read", "mcp:write"]
           }

    # The bare well-known path is not this resource's document, so the bearer
    # plug guards it like any other path.
    assert {401, _headers, _body} = get(port, "/.well-known/oauth-protected-resource")
  end

  test "a root resource serves the document at the bare well-known path", %{jwks: jwks} do
    port = listen(jwks, "https://mcp.example.test", :root)
    assert {200, _headers, body} = get(port, "/.well-known/oauth-protected-resource")
    assert JSON.decode!(body)["resource"] == "https://mcp.example.test"
  end

  test "a request without a token gets 401 naming the metadata document", %{port: port} do
    assert {401, headers, body} = rpc(port, request("tools/list", %{}), nil)

    assert headers["www-authenticate"] ==
             ~s(Bearer scope="mcp:read", resource_metadata="#{@metadata_url}")

    assert body == %{"error_description" => "A bearer token is required"}
  end

  test "an invalid token gets 401 invalid_token", %{port: port, rsa: rsa} do
    for claims <- [
          Fixtures.claims(%{"exp" => System.os_time(:second) - 60}),
          Fixtures.claims(%{"aud" => "https://other.example.test/mcp"}),
          Fixtures.claims(%{"iss" => "https://evil.example.test"})
        ] do
      assert {401, headers, %{"error" => "invalid_token"}} =
               rpc(port, request("tools/list", %{}), Fixtures.sign(rsa, "RS256", claims))

      assert headers["www-authenticate"] =~ ~s(error="invalid_token")
      assert headers["www-authenticate"] =~ ~s(resource_metadata="#{@metadata_url}")
    end

    assert {401, _headers, _body} =
             rpc(
               port,
               request("tools/list", %{}),
               Fixtures.sign(Fixtures.rsa_key("rsa-1"), "RS256", Fixtures.claims())
             )
  end

  test "a token without the endpoint scope gets 403 insufficient_scope", %{port: port, rsa: rsa} do
    token = Fixtures.sign(rsa, "RS256", Fixtures.claims(%{"scope" => "other"}))
    assert {403, headers, body} = rpc(port, request("tools/list", %{}), token)

    assert headers["www-authenticate"] ==
             ~s(Bearer error="insufficient_scope", error_description="The access token lacks a required scope", ) <>
               ~s(scope="mcp:read", resource_metadata="#{@metadata_url}")

    assert body["error"] == "insufficient_scope"
  end

  test "tools/list is filtered by scope and a call without the scope is refused below the transport",
       %{port: port, rsa: rsa} do
    reader = Fixtures.sign(rsa, "RS256", Fixtures.claims(%{"scope" => "mcp:read"}))
    writer = Fixtures.sign(rsa, "RS256", Fixtures.claims(%{"scope" => "mcp:read mcp:write"}))

    assert {200, _headers, listed} = rpc(port, request("tools/list", %{}), reader)
    assert Enum.map(listed["result"]["tools"], & &1["name"]) == ["read_thing"]

    assert {200, _headers, listed} = rpc(port, request("tools/list", %{}), writer)
    assert Enum.map(listed["result"]["tools"], & &1["name"]) == ["read_thing", "write_thing"]

    write = request("tools/call", %{"name" => "write_thing", "arguments" => %{}})

    # The request was authenticated, so the refusal is the policy's own
    # JSON-RPC error inside a 200, with the scope to step up to.
    assert {200, _headers, refused} = rpc(port, write, reader)
    assert refused["error"]["code"] == -32_003
    assert refused["error"]["data"] == %{"error" => "insufficient_scope", "scope" => "mcp:write"}

    assert {200, _headers, written} = rpc(port, write, writer)
    assert written["result"]["content"] == [%{"type" => "text", "text" => "written"}]

    read = request("tools/call", %{"name" => "read_thing", "arguments" => %{}})
    assert {200, _headers, result} = rpc(port, read, reader)

    assert result["result"]["structuredContent"] == %{
             "principal" => "user-1",
             "scopes" => ["mcp:read"]
           }
  end

  defp listen(jwks, resource, id) do
    executor = start_supervised!({Executor, []}, id: {Executor, id})

    router =
      Snodo.Router.new()
      |> Snodo.Router.register_tool(Fixtures.ReadTool)
      |> Snodo.Router.register_tool(Fixtures.WriteTool)

    runtime =
      Snodo.Server.Runtime.new(
        router: router,
        protocols: [Snodo.Protocol.V2026_07_28],
        server_info: %{"name" => "oauth-acceptance", "version" => "0.1.0"},
        capabilities: %{"tools" => %{}},
        authorization: {ScopePolicy, required: %{{:tool, "write_thing"} => ["mcp:write"]}}
      )

    opts = [
      metadata: [
        resource: resource,
        authorization_servers: [Fixtures.issuer()],
        scopes_supported: ["mcp:read", "mcp:write"]
      ],
      bearer: [
        resource: resource,
        verifier: {JWT, keys: jwks, issuer: Fixtures.issuer()},
        required_scopes: ["mcp:read"]
      ],
      runtime: runtime,
      executor: executor
    ]

    listener =
      start_supervised!(
        {Bandit,
         plug: {Fixtures.Endpoint, opts}, ip: {127, 0, 0, 1}, port: 0, startup_log: false},
        id: {Bandit, id}
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(listener)
    port
  end

  defp request(method, params) do
    %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => method,
      "params" => Map.put(params, "_meta", %{@version_key => @protocol, @capabilities_key => %{}})
    }
  end

  defp get(port, path) do
    exchange(port, ["GET ", path, " HTTP/1.1\r\nhost: localhost\r\nconnection: close\r\n\r\n"])
  end

  defp rpc(port, body, token) do
    encoded = JSON.encode!(body)

    headers =
      [
        {"host", "localhost"},
        {"connection", "close"},
        {"content-type", "application/json"},
        {"accept", "application/json, text/event-stream"},
        {"mcp-protocol-version", @protocol},
        {"mcp-method", body["method"]},
        {"content-length", to_string(byte_size(encoded))}
      ] ++
        if(name = get_in(body, ["params", "name"]), do: [{"mcp-name", name}], else: []) ++
        if(token, do: [{"authorization", "Bearer " <> token}], else: [])

    lines = Enum.map(headers, fn {key, value} -> [key, ": ", value, "\r\n"] end)

    {status, response_headers, raw} =
      exchange(port, ["POST /mcp HTTP/1.1\r\n", lines, "\r\n", encoded])

    {status, response_headers, if(raw == "", do: nil, else: JSON.decode!(raw))}
  end

  defp exchange(port, request) do
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
    case :gen_tcp.recv(socket, 0, 2_000) do
      {:ok, data} -> read_all(socket, acc <> data)
      {:error, :closed} -> acc
      {:error, reason} -> flunk("HTTP read failed: #{inspect(reason)}; received #{inspect(acc)}")
    end
  end
end
