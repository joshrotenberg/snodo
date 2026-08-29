defmodule MCPEx.TestResources.InvalidCache do
  use MCP.Resource,
    uri: "test://errors/cache",
    name: "invalid_cache"

  @impl true
  def read(%{"uri" => uri}, _context) do
    {:ok,
     MCP.Result.resource_read(MCP.Resource.text(uri, "invalid"),
       metadata: %{ttl_ms: -1, cache_scope: "shared"}
     )}
  end
end

defmodule MCP.ResourceProtocolAcceptanceTest do
  use ExUnit.Case, async: true

  alias MCP.Protocol.V2026_07_28
  alias MCP.Test, as: MCPTest
  alias MCPEx.TestFixtures
  alias MCPEx.TestResources.DeclaredError
  alias MCPEx.TestResources.InvalidCache
  alias MCPEx.TestResources.PackageTemplate
  alias MCPEx.TestResources.StaticBlob
  alias MCPEx.TestResources.StaticJSON
  alias MCPEx.TestResources.StaticText

  @resources [StaticText, StaticJSON, StaticBlob, PackageTemplate]

  defp runtime(opts \\ []) do
    defaults = [
      resources: @resources,
      resources_cache: [ttl_ms: 321, scope: "public"]
    ]

    TestFixtures.runtime(Keyword.merge(defaults, opts))
  end

  test "discovery advertises only the implemented base resources capability" do
    assert {:ok, %{"result" => discovery}} =
             MCPTest.dispatch(runtime(),
               protocol: "2026-07-28",
               method: "server/discover"
             )

    assert discovery["capabilities"]["resources"] == %{}

    assert_raise ArgumentError, ~r/configured subscription_source/, fn ->
      runtime(capabilities: %{"resources" => %{"subscribe" => true}})
    end

    assert_raise ArgumentError, ~r/configured subscription_source/, fn ->
      runtime(capabilities: %{"resources" => %{"listChanged" => true}})
    end

    assert TestFixtures.runtime(resources: []).capabilities == %{"tools" => %{}}
  end

  test "resource and template lists are separate, deterministic, and cacheable" do
    assert {:ok, %{"result" => listed}} =
             MCPTest.dispatch(runtime(),
               protocol: "2026-07-28",
               method: "resources/list"
             )

    assert Enum.map(listed["resources"], & &1["uri"]) == [
             "test://static/blob",
             "test://static/data",
             "test://static/readme"
           ]

    assert listed["resultType"] == "complete"
    assert listed["ttlMs"] == 321
    assert listed["cacheScope"] == "public"
    assert get_in(listed, ["_meta", V2026_07_28.server_info_key(), "name"]) == "mcp-ex-spike"

    readme = Enum.find(listed["resources"], &(&1["uri"] == "test://static/readme"))
    assert readme == MCP.Resource.definition_to_map(StaticText.definition())

    assert {:ok, %{"result" => templates}} =
             MCPTest.dispatch(runtime(),
               protocol: "2026-07-28",
               method: "resources/templates/list"
             )

    assert templates["resourceTemplates"] == [
             MCP.Resource.definition_to_map(PackageTemplate.definition())
           ]

    assert templates["ttlMs"] == 321
    assert templates["cacheScope"] == "public"
    refute Map.has_key?(listed, "nextCursor")
    refute Map.has_key?(templates, "nextCursor")
  end

  test "resource reads shape text, JSON, and binary contents exactly" do
    assert {:ok, %{"result" => text}} = read(runtime(), "test://static/readme")
    assert text["resultType"] == "complete"
    assert text["ttlMs"] == 321
    assert text["cacheScope"] == "public"
    assert [%{"text" => "# Static resource\n"} = text_content] = text["contents"]
    assert text_content["mimeType"] == "text/markdown"

    assert get_in(text, ["_meta", "com.example/result"]) == %{"kind" => "text"}

    assert {:ok, %{"result" => json}} = read(runtime(), "test://static/data")
    assert [%{"text" => encoded_json, "mimeType" => "application/json"}] = json["contents"]
    assert JSON.decode!(encoded_json)["name"] == "resource-json"

    assert {:ok, %{"result" => blob}} = read(runtime(), "test://static/blob")

    assert [%{"blob" => encoded_blob, "mimeType" => "application/octet-stream"}] =
             blob["contents"]

    assert Base.decode64!(encoded_blob) == <<0, 1, 2, 127, 128, 255>>
  end

  test "explicit template routing receives the URI and preserves request metadata" do
    metadata =
      TestFixtures.metadata("2026-07-28", %{
        "com.example/request" => %{"trace" => "resource-read"}
      })

    assert {:ok, %{"result" => result}} =
             MCPTest.dispatch(runtime(),
               protocol: "2026-07-28",
               method: "resources/read",
               params: %{
                 "uri" => "test://packages/plug",
                 "com.example/param" => [true, nil],
                 "_meta" => metadata
               }
             )

    assert [%{"uri" => "test://packages/plug", "text" => encoded}] = result["contents"]
    decoded = JSON.decode!(encoded)
    assert decoded["name"] == "plug"
    assert decoded["params"]["com.example/param"] == [true, nil]
    assert decoded["params"]["_meta"] == metadata
  end

  test "missing and failed reads use protocol errors rather than empty contents" do
    assert {:ok, %{"error" => missing}} = read(runtime(), "test://missing")

    assert missing == %{
             "code" => -32_602,
             "message" => "Resource not found",
             "data" => %{"uri" => "test://missing"}
           }

    error_runtime = runtime(resources: [DeclaredError])
    assert {:ok, %{"error" => declared}} = read(error_runtime, "test://errors/declared")
    assert declared["code"] == -32_602
    assert declared["message"] == "Resource access denied"

    invalid_cache_runtime = runtime(resources: [InvalidCache])
    assert {:ok, %{"error" => invalid_cache}} = read(invalid_cache_runtime, "test://errors/cache")

    assert invalid_cache == %{
             "code" => -32_603,
             "message" => "Resource returned invalid cache metadata"
           }
  end

  test "resource parameter and capability admission fail closed" do
    for uri <- [nil, 7, "relative/path"] do
      assert {:ok, %{"error" => %{"code" => -32_602}}} =
               MCPTest.dispatch(runtime(),
                 protocol: "2026-07-28",
                 method: "resources/read",
                 params: %{"uri" => uri}
               )
    end

    for method <- ["resources/list", "resources/templates/list"] do
      assert {:ok, %{"error" => cursor_error}} =
               MCPTest.dispatch(runtime(),
                 protocol: "2026-07-28",
                 method: method,
                 params: %{"cursor" => "next-page"}
               )

      assert cursor_error["code"] == -32_602
      assert cursor_error["message"] == "Invalid pagination cursor"
    end

    unadvertised = runtime(capabilities: %{"tools" => %{}})

    assert {:ok, %{"error" => %{"code" => -32_601}}} =
             MCPTest.dispatch(unadvertised,
               protocol: "2026-07-28",
               method: "resources/list"
             )
  end

  defp read(runtime, uri) do
    MCPTest.dispatch(runtime,
      protocol: "2026-07-28",
      method: "resources/read",
      params: %{"uri" => uri}
    )
  end
end
