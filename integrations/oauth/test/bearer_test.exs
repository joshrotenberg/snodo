defmodule Snodo.OAuth.ResourceServer.BearerTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias Snodo.OAuth.ResourceServer.Bearer
  alias SnodoTest.OAuthFixtures, as: Fixtures
  alias SnodoTest.OAuthFixtures.StubVerifier

  @metadata "https://mcp.example.test/.well-known/oauth-protected-resource/mcp"

  defp bearer(results, extra \\ []) do
    Bearer.init([resource: Fixtures.resource(), verifier: {StubVerifier, results}] ++ extra)
  end

  defp request(token) do
    conn = conn(:post, "/mcp")
    if token, do: put_req_header(conn, "authorization", token), else: conn
  end

  defp challenge(conn) do
    [value] = get_resp_header(conn, "www-authenticate")
    value
  end

  defp body(conn), do: JSON.decode!(conn.resp_body)

  describe "token extraction" do
    test "a request without a token gets 401 and a challenge without an error code" do
      conn = Bearer.call(request(nil), bearer(%{}))
      assert conn.halted
      assert conn.status == 401
      assert challenge(conn) == ~s(Bearer resource_metadata="#{@metadata}")
      assert get_resp_header(conn, "content-type") == ["application/json; charset=utf-8"]
      assert body(conn) == %{"error_description" => "A bearer token is required"}
    end

    test "another scheme is treated as no token" do
      conn = Bearer.call(request("Basic dXNlcjpwYXNz"), bearer(%{}))
      assert conn.status == 401
      assert challenge(conn) == ~s(Bearer resource_metadata="#{@metadata}")
    end

    test "the scheme is case-insensitive and surrounding whitespace is tolerated" do
      results = %{"good" => {:ok, Fixtures.claims()}}
      assert Bearer.call(request("bearer good"), bearer(results)).status == nil
      assert Bearer.call(request("BEARER   good \t"), bearer(results)).status == nil
    end

    test "a malformed token or more than one header gets 400 invalid_request" do
      conn = Bearer.call(request("Bearer not a token"), bearer(%{}))
      assert conn.status == 400
      assert challenge(conn) =~ ~s(error="invalid_request")
      assert body(conn)["error"] == "invalid_request"

      assert Bearer.call(request("Bearer"), bearer(%{})).status == 400
      assert Bearer.call(request("Bearer "), bearer(%{})).status == 400
      assert Bearer.call(request("Bearer tok\"en"), bearer(%{})).status == 400

      two = prepend_req_headers(request("Bearer good"), [{"authorization", "Bearer other"}])
      conn = Bearer.call(two, bearer(%{"good" => {:ok, Fixtures.claims()}}))
      assert conn.status == 400
      assert body(conn)["error_description"] == "More than one Authorization header"
    end
  end

  describe "verifier results" do
    test "a refused token gets 401 invalid_token naming the reason" do
      results = %{
        "expired" => {:error, :expired_signature},
        "tuple" => {:error, {:keys_unavailable, :down}}
      }

      conn = Bearer.call(request("Bearer expired"), bearer(results))
      assert conn.status == 401

      assert challenge(conn) ==
               ~s(Bearer error="invalid_token", error_description="Token verification failed: expired_signature", ) <>
                 ~s(resource_metadata="#{@metadata}")

      assert body(conn) == %{
               "error" => "invalid_token",
               "error_description" => "Token verification failed: expired_signature"
             }

      conn = Bearer.call(request("Bearer tuple"), bearer(results))

      assert challenge(conn) =~
               ~s(error_description="Token verification failed: keys_unavailable")

      assert Bearer.call(request("Bearer unknown"), bearer(results)).status == 401
    end

    test "a reason is reduced to the characters a quoted parameter allows" do
      results = %{"weird" => {:error, "bad \"quote\" \\ back\r\nslash \x01 and é"}}
      conn = Bearer.call(request("Bearer weird"), bearer(results, realm: ~s(mcp "realm"\n)))
      assert conn.status == 401

      assert challenge(conn) ==
               ~s(Bearer realm="mcp realm", error="invalid_token", ) <>
                 ~s(error_description="Token verification failed: bad quote  backslash  and ", ) <>
                 ~s(resource_metadata="#{@metadata}")
    end

    test "an invalid verifier return raises" do
      assert_raise ArgumentError, ~r/StubVerifier.verify\/2 returned :garbage/, fn ->
        Bearer.call(request("Bearer weird"), bearer(%{"weird" => :garbage}))
      end

      assert_raise ArgumentError, fn ->
        Bearer.call(request("Bearer weird"), bearer(%{"weird" => {:ok, "claims"}}))
      end
    end
  end

  describe "claims checks" do
    test "an admitted token sets the trusted assign" do
      claims = Fixtures.claims(%{"scope" => "mcp:read mcp:write"})
      conn = Bearer.call(request("Bearer good"), bearer(%{"good" => {:ok, claims}}))
      refute conn.halted
      assert conn.status == nil

      assert conn.assigns.mcp_auth == %{
               principal: "user-1",
               client_id: "client-1",
               scopes: ["mcp:read", "mcp:write"],
               claims: claims
             }
    end

    test "expiry and not-before are checked against the clock with leeway" do
      now = System.os_time(:second)

      refused = fn claims, extra ->
        conn = Bearer.call(request("Bearer t"), bearer(%{"t" => {:ok, claims}}, extra))
        assert conn.status == 401
        assert body(conn)["error"] == "invalid_token"
        body(conn)["error_description"]
      end

      admitted = fn claims, extra ->
        refute Bearer.call(request("Bearer t"), bearer(%{"t" => {:ok, claims}}, extra)).halted
      end

      assert refused.(Fixtures.claims(%{"exp" => now - 10}), []) == "The access token has expired"
      assert refused.(Fixtures.claims(%{"exp" => now}), []) == "The access token has expired"
      admitted.(Fixtures.claims(%{"exp" => now - 10}), leeway: 30)
      assert refused.(Fixtures.claims(%{"exp" => "later"}), []) == "The exp claim is not a number"
      admitted.(Fixtures.claims(%{"exp" => nil}), [])

      assert refused.(Fixtures.claims(%{"nbf" => now + 30}), []) ==
               "The access token is not yet valid"

      admitted.(Fixtures.claims(%{"nbf" => now + 30}), leeway: 60)
      admitted.(Fixtures.claims(%{"nbf" => now - 1}), [])
      assert refused.(Fixtures.claims(%{"nbf" => "soon"}), []) == "The nbf claim is not a number"
    end

    test "the audience must name the resource" do
      refused = fn claims, extra ->
        conn = Bearer.call(request("Bearer t"), bearer(%{"t" => {:ok, claims}}, extra))
        assert conn.status == 401
        body(conn)["error_description"]
      end

      assert refused.(Fixtures.claims(%{"aud" => nil}), []) == "The access token has no audience"

      assert refused.(Fixtures.claims(%{"aud" => "https://other.example.test/mcp"}), []) ==
               "The access token was not issued for this resource"

      assert refused.(Fixtures.claims(%{"aud" => ["a", "b"]}), []) ==
               "The access token was not issued for this resource"

      assert refused.(Fixtures.claims(%{"aud" => 42}), []) ==
               "The access token was not issued for this resource"

      admitted = fn claims, extra ->
        refute Bearer.call(request("Bearer t"), bearer(%{"t" => {:ok, claims}}, extra)).halted
      end

      admitted.(Fixtures.claims(%{"aud" => ["other", "https://MCP.example.test/mcp"]}), [])

      admitted.(Fixtures.claims(%{"aud" => "api://mcp"}),
        audience: ["api://mcp", Fixtures.resource()]
      )

      assert refused.(Fixtures.claims(), audience: ["api://mcp"]) ==
               "The access token was not issued for this resource"
    end

    test "scopes come from scope or scp and required scopes give 403 insufficient_scope" do
      opts = bearer(%{}, required_scopes: ["mcp:read", "mcp:write"])

      # The 401 challenge advertises the scopes to request.
      conn = Bearer.call(request(nil), opts)

      assert challenge(conn) ==
               ~s(Bearer scope="mcp:read mcp:write", resource_metadata="#{@metadata}")

      results = %{
        "read" => {:ok, Fixtures.claims(%{"scope" => "mcp:read"})},
        "both" => {:ok, Fixtures.claims(%{"scope" => "mcp:write mcp:read extra"})},
        "scp" => {:ok, Fixtures.claims(%{"scope" => nil, "scp" => ["mcp:read", "mcp:write"]})},
        "none" => {:ok, Fixtures.claims(%{"scope" => nil})},
        "bad" => {:ok, Fixtures.claims(%{"scope" => 42})},
        "badlist" => {:ok, Fixtures.claims(%{"scope" => nil, "scp" => [1]})}
      }

      opts = bearer(results, required_scopes: ["mcp:read", "mcp:write"])

      conn = Bearer.call(request("Bearer read"), opts)
      assert conn.status == 403

      assert challenge(conn) ==
               ~s(Bearer error="insufficient_scope", error_description="The access token lacks a required scope", ) <>
                 ~s(scope="mcp:read mcp:write", resource_metadata="#{@metadata}")

      assert body(conn)["error"] == "insufficient_scope"
      assert Bearer.call(request("Bearer none"), opts).status == 403

      both = Bearer.call(request("Bearer both"), opts)
      refute both.halted
      assert both.assigns.mcp_auth.scopes == ["mcp:write", "mcp:read", "extra"]

      assert Bearer.call(request("Bearer scp"), opts).assigns.mcp_auth.scopes == [
               "mcp:read",
               "mcp:write"
             ]

      for token <- ["bad", "badlist"] do
        conn = Bearer.call(request("Bearer #{token}"), opts)
        assert conn.status == 401
        assert body(conn)["error_description"] == "The scope claim is malformed"
      end

      # Without an endpoint requirement, no scope is needed.
      assert Bearer.call(request("Bearer none"), bearer(results)).assigns.mcp_auth.scopes == []
    end
  end

  describe "options" do
    test "resource_metadata, realm, and auth_assign are configurable" do
      claims = Fixtures.claims()

      opts =
        bearer(%{"good" => {:ok, claims}},
          resource_metadata: "https://cdn.example.test/prm.json",
          realm: "mcp",
          auth_assign: :current_token
        )

      assert challenge(Bearer.call(request(nil), opts)) ==
               ~s(Bearer realm="mcp", resource_metadata="https://cdn.example.test/prm.json")

      conn = Bearer.call(request("Bearer good"), opts)
      assert conn.assigns.current_token.claims == claims
      refute Map.has_key?(conn.assigns, :mcp_auth)
    end

    test "a bare verifier module gets empty options" do
      opts = Bearer.init(resource: Fixtures.resource(), verifier: StubVerifier)
      assert opts.verifier == {StubVerifier, []}
    end

    test "a halted conn passes through untouched" do
      halted = request(nil) |> halt()
      assert Bearer.call(halted, bearer(%{})) == halted
    end

    test "invalid options raise" do
      base = [resource: Fixtures.resource(), verifier: StubVerifier]

      for bad <- [
            Keyword.delete(base, :resource),
            Keyword.delete(base, :verifier),
            Keyword.put(base, :verifier, "Mod"),
            Keyword.put(base, :verifier, {nil, []}),
            Keyword.put(base, :audience, []),
            Keyword.put(base, :audience, "one"),
            Keyword.put(base, :audience, [:atom]),
            Keyword.put(base, :required_scopes, "mcp:read"),
            Keyword.put(base, :required_scopes, ["mcp read"]),
            Keyword.put(base, :required_scopes, [~s(a"b)]),
            Keyword.put(base, :resource_metadata, 1),
            Keyword.put(base, :realm, 1),
            Keyword.put(base, :leeway, -1),
            Keyword.put(base, :leeway, 1.5),
            Keyword.put(base, :auth_assign, "mcp_auth"),
            Keyword.put(base, :resource, "mcp.example.test/mcp")
          ] do
        assert_raise ArgumentError, fn -> Bearer.init(bad) end
      end
    end
  end
end
