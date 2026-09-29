defmodule Snodo.OAuth.ResourceServerTest do
  use ExUnit.Case, async: true

  alias Snodo.OAuth.ResourceServer

  describe "resource!/1" do
    test "canonicalizes scheme, host, and a lone trailing slash" do
      assert ResourceServer.resource!("HTTPS://MCP.Example.com/") == "https://mcp.example.com"
      assert ResourceServer.resource!("https://mcp.example.com") == "https://mcp.example.com"

      assert ResourceServer.resource!("https://mcp.example.com:8443/mcp") ==
               "https://mcp.example.com:8443/mcp"

      assert ResourceServer.resource!("https://mcp.example.com/mcp/") ==
               "https://mcp.example.com/mcp/"

      assert ResourceServer.resource!("http://localhost:4000/mcp") == "http://localhost:4000/mcp"
    end

    test "refuses a relative URI, another scheme, a missing host, and a fragment" do
      for bad <- [
            "mcp.example.com",
            "/mcp",
            "ftp://mcp.example.com",
            "https:///mcp",
            "https://x/mcp#frag"
          ] do
        assert_raise ArgumentError, fn -> ResourceServer.resource!(bad) end
      end

      assert_raise ArgumentError, fn -> ResourceServer.resource!(:atom) end
    end
  end

  describe "metadata_path/1 and metadata_url/1" do
    test "a root resource serves the document at the bare well-known path" do
      assert ResourceServer.metadata_path("https://mcp.example.com") ==
               "/.well-known/oauth-protected-resource"

      assert ResourceServer.metadata_path("https://mcp.example.com/") ==
               "/.well-known/oauth-protected-resource"

      assert ResourceServer.metadata_url("https://mcp.example.com") ==
               "https://mcp.example.com/.well-known/oauth-protected-resource"
    end

    test "a resource with a path inserts the well-known segment before it" do
      assert ResourceServer.metadata_path("https://mcp.example.com/mcp") ==
               "/.well-known/oauth-protected-resource/mcp"

      assert ResourceServer.metadata_path("https://mcp.example.com/public/mcp/") ==
               "/.well-known/oauth-protected-resource/public/mcp"

      assert ResourceServer.metadata_url("https://mcp.example.com:8443/public/mcp") ==
               "https://mcp.example.com:8443/.well-known/oauth-protected-resource/public/mcp"
    end

    test "a query component is kept on the URL" do
      assert ResourceServer.metadata_url("https://mcp.example.com/mcp?tenant=a") ==
               "https://mcp.example.com/.well-known/oauth-protected-resource/mcp?tenant=a"
    end
  end

  describe "audience_match?/2" do
    test "matches a string or any element of a list after canonicalization" do
      accepted = ["https://mcp.example.com/mcp"]
      assert ResourceServer.audience_match?("https://MCP.example.com/mcp", accepted)
      assert ResourceServer.audience_match?(["other", "https://mcp.example.com/mcp"], accepted)

      assert ResourceServer.audience_match?("https://mcp.example.com/", [
               "https://mcp.example.com"
             ])

      assert ResourceServer.audience_match?("api://mcp", ["api://mcp"])
    end

    test "a different path, port, or scheme does not match" do
      accepted = ["https://mcp.example.com/mcp"]
      refute ResourceServer.audience_match?("https://mcp.example.com/mcp/", accepted)
      refute ResourceServer.audience_match?("https://mcp.example.com:8443/mcp", accepted)
      refute ResourceServer.audience_match?("http://mcp.example.com/mcp", accepted)
      refute ResourceServer.audience_match?("https://mcp.example.com", accepted)
      refute ResourceServer.audience_match?(["a", "b"], accepted)
      refute ResourceServer.audience_match?(nil, accepted)
      refute ResourceServer.audience_match?(42, accepted)
      refute ResourceServer.audience_match?([42], accepted)
    end
  end
end
