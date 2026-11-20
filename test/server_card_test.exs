defmodule Snodo.ServerCardTest do
  use ExUnit.Case, async: true

  alias Snodo.ServerCard
  alias SnodoTest.TestFixtures

  @endpoint "https://example.com/services/mcp"
  @info %{
    "name" => "com.example/weather",
    "version" => "1.2.3",
    "description" => "Weather forecasts",
    "title" => "Weather",
    "websiteUrl" => "https://example.com",
    "icons" => [%{"src" => "https://example.com/icon.png", "token" => "secret"}],
    "_meta" => %{"com.example/credential" => "secret"}
  }

  test "serializes only public schema fields and lists enabled protocol versions" do
    runtime =
      %{
        TestFixtures.runtime(protocols: [Snodo.Protocol.V2026_07_28, Snodo.Protocol.V2025_11_25])
        | server_info: @info
      }

    assert map_size(runtime.router.tools) > 0
    card = runtime |> ServerCard.build(@endpoint) |> JSON.encode!() |> JSON.decode!()

    assert card == %{
             "$schema" =>
               "https://static.modelcontextprotocol.io/schemas/v1/server-card.schema.json",
             "name" => "com.example/weather",
             "version" => "1.2.3",
             "description" => "Weather forecasts",
             "title" => "Weather",
             "websiteUrl" => "https://example.com",
             "icons" => [%{"src" => "https://example.com/icon.png"}],
             "remotes" => [
               %{
                 "type" => "streamable-http",
                 "url" => @endpoint,
                 "supportedProtocolVersions" => ["2026-07-28", "2025-11-25"]
               }
             ]
           }
  end

  test "rejects invalid names, missing descriptions, and overlong descriptions" do
    for {key, value, error} <- [
          {"name", "weather", ~r/Server Card name/},
          {"description", nil, ~r/Server Card description/},
          {"description", String.duplicate("é", 101), ~r/Server Card description/},
          {"version", "^1.2.3", ~r/Server Card version/},
          {"version", "1.x", ~r/Server Card version/},
          {"version", "1.*+build", ~r/Server Card version/}
        ] do
      info = if is_nil(value), do: Map.delete(@info, key), else: Map.put(@info, key, value)
      runtime = %{TestFixtures.runtime() | server_info: info}
      assert_raise ArgumentError, error, fn -> ServerCard.build(runtime, @endpoint) end
    end
  end

  test "accepts x in prerelease and build identifiers" do
    for version <- ["1.0.0+build.x", "1.0.0-alpha.x"] do
      runtime = %{TestFixtures.runtime() | server_info: %{@info | "version" => version}}
      assert ServerCard.build(runtime, @endpoint)["version"] == version
    end
  end

  test "requires a public HTTP(S) website URL" do
    info = %{@info | "websiteUrl" => "javascript:void(0)"}
    runtime = %{TestFixtures.runtime() | server_info: info}

    assert_raise ArgumentError, ~r/websiteUrl must be an absolute HTTP/, fn ->
      ServerCard.build(runtime, @endpoint)
    end
  end

  test "rejects transport URLs containing user information or queries" do
    runtime = %{TestFixtures.runtime() | server_info: @info}

    for url <- ["/mcp", "https://user:secret@example.com/mcp", @endpoint <> "?token=abc"] do
      assert_raise ArgumentError, ~r/Server Card URL/, fn -> ServerCard.build(runtime, url) end
    end
  end

  test "builds a minimal AI Catalog pointing to hosted cards" do
    assert ServerCard.catalog([{"urn:air:example.com:mcp:weather", @endpoint <> "/server-card"}]) ==
             %{
               "specVersion" => "1.0",
               "entries" => [
                 %{
                   "identifier" => "urn:air:example.com:mcp:weather",
                   "type" => "application/mcp-server-card+json",
                   "url" => @endpoint <> "/server-card"
                 }
               ]
             }
  end

  test "requires catalog entry tuples with string identifiers" do
    for entry <- [:invalid, {123, @endpoint}] do
      assert_raise ArgumentError, ~r/AI Catalog entries must be/, fn ->
        ServerCard.catalog([entry])
      end
    end
  end
end
