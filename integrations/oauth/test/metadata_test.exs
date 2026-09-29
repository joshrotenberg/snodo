defmodule Snodo.OAuth.ResourceServer.MetadataTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias Snodo.OAuth.ResourceServer.Metadata

  @servers ["https://auth.example.test"]

  test "serves the document at the root well-known path for a root resource" do
    opts = Metadata.init(resource: "https://mcp.example.test", authorization_servers: @servers)
    conn = Metadata.call(conn(:get, "/.well-known/oauth-protected-resource"), opts)

    assert conn.halted
    assert conn.status == 200
    assert get_resp_header(conn, "content-type") == ["application/json; charset=utf-8"]

    assert JSON.decode!(conn.resp_body) == %{
             "resource" => "https://mcp.example.test",
             "authorization_servers" => @servers,
             "bearer_methods_supported" => ["header"]
           }
  end

  test "serves the document under the resource path for a prefixed resource" do
    opts =
      Metadata.init(
        resource: "https://mcp.example.test/public/mcp",
        authorization_servers: @servers,
        scopes_supported: ["mcp:read", "mcp:write"],
        resource_name: "Example MCP",
        extra: %{
          "resource_documentation" => "https://mcp.example.test/docs",
          "resource" => "ignored"
        }
      )

    refute Metadata.call(conn(:get, "/.well-known/oauth-protected-resource"), opts).halted
    refute Metadata.call(conn(:get, "/public/mcp"), opts).halted

    conn = Metadata.call(conn(:get, "/.well-known/oauth-protected-resource/public/mcp"), opts)
    assert conn.status == 200

    assert JSON.decode!(conn.resp_body) == %{
             "resource" => "https://mcp.example.test/public/mcp",
             "authorization_servers" => @servers,
             "bearer_methods_supported" => ["header"],
             "scopes_supported" => ["mcp:read", "mcp:write"],
             "resource_name" => "Example MCP",
             "resource_documentation" => "https://mcp.example.test/docs"
           }
  end

  test "path: overrides the derived path" do
    opts =
      Metadata.init(
        resource: "https://mcp.example.test/mcp",
        authorization_servers: @servers,
        path: "/.well-known/oauth-protected-resource"
      )

    assert Metadata.call(conn(:get, "/.well-known/oauth-protected-resource"), opts).status == 200
    refute Metadata.call(conn(:get, "/.well-known/oauth-protected-resource/mcp"), opts).halted
  end

  test "HEAD is served, other methods get 405, and a halted conn passes through" do
    opts =
      Metadata.init(resource: "https://mcp.example.test/mcp", authorization_servers: @servers)

    path = "/.well-known/oauth-protected-resource/mcp"

    assert Metadata.call(conn(:head, path), opts).status == 200

    post = Metadata.call(conn(:post, path), opts)
    assert post.status == 405
    assert get_resp_header(post, "allow") == ["GET, HEAD"]

    halted = conn(:get, path) |> halt()
    assert Metadata.call(halted, opts) == halted
  end

  test "document/1 exposes the map, and invalid options raise at init" do
    assert Metadata.document(
             resource: "https://mcp.example.test/mcp",
             authorization_servers: @servers
           )["resource"] ==
             "https://mcp.example.test/mcp"

    for bad <- [
          [authorization_servers: @servers],
          [resource: "https://mcp.example.test/mcp"],
          [resource: "https://mcp.example.test/mcp", authorization_servers: []],
          [resource: "https://mcp.example.test/mcp", authorization_servers: [:atom]],
          [
            resource: "https://mcp.example.test/mcp",
            authorization_servers: @servers,
            scopes_supported: ["a b"]
          ],
          [
            resource: "https://mcp.example.test/mcp",
            authorization_servers: @servers,
            scopes_supported: ["with\"quote"]
          ],
          [
            resource: "https://mcp.example.test/mcp",
            authorization_servers: @servers,
            extra: %{atom: 1}
          ],
          [resource: "https://mcp.example.test/mcp", authorization_servers: @servers, extra: []],
          [
            resource: "https://mcp.example.test/mcp",
            authorization_servers: @servers,
            resource_name: 1
          ],
          [
            resource: "https://mcp.example.test/mcp",
            authorization_servers: @servers,
            path: "relative"
          ],
          [resource: "mcp.example.test", authorization_servers: @servers]
        ] do
      assert_raise ArgumentError, fn -> Metadata.init(bad) end
    end
  end
end
