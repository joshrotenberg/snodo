defmodule Snodo.ClientChallengeTest do
  use ExUnit.Case, async: true

  alias Snodo.Client.Challenge

  @metadata "https://mcp.example.test/.well-known/oauth-protected-resource/mcp"

  describe "parse/1" do
    test "reads a bearer challenge with quoted parameters" do
      header =
        ~s(Bearer realm="mcp", resource_metadata="#{@metadata}", scope="mcp:read mcp:write")

      assert [
               %Challenge{
                 scheme: "bearer",
                 resource_metadata: @metadata,
                 scope: ["mcp:read", "mcp:write"],
                 error: nil,
                 error_description: nil,
                 params: %{"realm" => "mcp"}
               }
             ] = Challenge.parse(header)
    end

    test "reads an insufficient_scope challenge" do
      header =
        ~s(Bearer error="insufficient_scope", scope="mcp:write", ) <>
          ~s(error_description="Token has insufficient scope", resource_metadata="#{@metadata}")

      assert [%Challenge{error: "insufficient_scope", scope: ["mcp:write"]} = challenge] =
               Challenge.parse(header)

      assert challenge.error_description == "Token has insufficient scope"
      assert challenge.resource_metadata == @metadata
    end

    test "accepts token values, extra spacing, and any case" do
      header = ~s(bearer  RESOURCE_METADATA="#{@metadata}" ,Error=invalid_token)

      assert [%Challenge{scheme: "bearer", resource_metadata: @metadata, error: "invalid_token"}] =
               Challenge.parse(header)
    end

    test "unescapes quoted strings" do
      assert [%Challenge{params: %{"realm" => ~s(say "hi" \\ there)}}] =
               Challenge.parse(~s(Bearer realm="say \\"hi\\" \\\\ there"))
    end

    test "splits several challenges in one header" do
      header = ~s(Bearer realm="a", scope="x", Basic realm="b", DPoP algs="ES256")

      assert [
               %Challenge{scheme: "bearer", scope: ["x"], params: %{"realm" => "a"}},
               %Challenge{scheme: "basic", params: %{"realm" => "b"}},
               %Challenge{scheme: "dpop", params: %{"algs" => "ES256"}}
             ] = Challenge.parse(header)
    end

    test "keeps the first of a repeated parameter" do
      assert [%Challenge{scope: ["a"]}] = Challenge.parse(~s(Bearer scope="a", scope="b"))
    end

    test "a scheme without parameters is a challenge" do
      assert [%Challenge{scheme: "bearer", params: %{}, scope: []}] = Challenge.parse("Bearer")

      assert [%Challenge{scheme: "bearer"}, %Challenge{scheme: "basic"}] =
               Challenge.parse("Bearer, Basic")
    end

    test "reads past a token68 credential to the challenges after it" do
      assert [
               %Challenge{scheme: "negotiate", params: %{}},
               %Challenge{scheme: "bearer", scope: ["x"]}
             ] = Challenge.parse(~s(Negotiate YII+/abc==, Bearer scope="x"))

      assert [%Challenge{scheme: "basic", params: %{}}, %Challenge{scheme: "bearer"}] =
               Challenge.parse("Basic dXNlcjpwYXNz, Bearer")

      assert [%Challenge{scheme: "negotiate", params: %{}}] = Challenge.parse("Negotiate abc")
    end

    test "an empty scope parameter is no scope" do
      assert [%Challenge{scope: []}] = Challenge.parse(~s(Bearer scope=""))
    end

    test "rejects what does not follow the grammar" do
      assert Challenge.parse("") == []
      assert Challenge.parse(~s(Bearer resource_metadata=#{@metadata})) == []
      assert Challenge.parse(~s(")) == []
      assert Challenge.parse(~s(Bearer realm="unterminated)) == []
      assert Challenge.parse("Bearer realm=\"a\x01b\"") == []
      assert Challenge.parse(<<0xFF, 0xFE>>) == []
    end

    test "stops at a parameter without a value and keeps what came before" do
      assert [%Challenge{scheme: "bearer", params: %{"realm" => "a"}}] =
               Challenge.parse(~s(Bearer realm="a", scope=))
    end

    test "refuses a header over 8 KiB" do
      header = ~s(Bearer realm=") <> String.duplicate("a", 8_192) <> ~s(")
      assert Challenge.parse(header) == []
    end

    test "only accepts binaries" do
      assert Challenge.parse(nil) == []
    end
  end

  describe "select/1" do
    test "prefers the bearer challenge across headers" do
      headers = [
        {"content-type", "application/json"},
        {"www-authenticate", ~s(DPoP algs="ES256")},
        {"WWW-Authenticate", ~s(Bearer scope="mcp:read")}
      ]

      assert %Challenge{scheme: "bearer", scope: ["mcp:read"]} = Challenge.select(headers)
    end

    test "falls back to the first challenge of another scheme" do
      assert %Challenge{scheme: "dpop"} =
               Challenge.select([{"www-authenticate", ~s(DPoP resource_metadata="#{@metadata}")}])
    end

    test "is nil without a usable challenge" do
      assert Challenge.select([]) == nil
      assert Challenge.select([{"www-authenticate", ""}]) == nil
      assert Challenge.select([{"content-type", "text/plain"}]) == nil
    end
  end
end
