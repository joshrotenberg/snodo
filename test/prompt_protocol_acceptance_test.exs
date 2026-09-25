defmodule Snodo.PromptProtocolAcceptanceTest do
  use ExUnit.Case, async: true

  alias Snodo.Protocol.V2026_07_28
  alias Snodo.Test, as: MCPTest
  alias SnodoTest.TestFixtures
  alias SnodoTest.TestPrompts.MediaReview
  alias SnodoTest.TestPrompts.PackageAnalysis

  @prompts [PackageAnalysis, MediaReview]

  defp runtime(opts \\ []) do
    defaults = [
      prompts: @prompts,
      prompts_cache: [ttl_ms: 654, scope: "public"]
    ]

    TestFixtures.runtime(Keyword.merge(defaults, opts))
  end

  test "discovery advertises only the implemented base prompts capability" do
    assert {:ok, %{"result" => discovery}} =
             MCPTest.dispatch(runtime(),
               protocol: "2026-07-28",
               method: "server/discover"
             )

    assert discovery["capabilities"]["prompts"] == %{}

    assert_raise ArgumentError, ~r/configured subscription_source/, fn ->
      runtime(capabilities: %{"prompts" => %{"listChanged" => true}})
    end

    refute Map.has_key?(TestFixtures.runtime(prompts: []).capabilities, "prompts")
  end

  test "prompts/list is deterministic, cacheable, and preserves definition metadata" do
    assert {:ok, %{"result" => listed}} =
             MCPTest.dispatch(runtime(),
               protocol: "2026-07-28",
               method: "prompts/list"
             )

    assert Enum.map(listed["prompts"], & &1["name"]) == ["media_review", "package_analysis"]
    assert listed["resultType"] == "complete"
    assert listed["ttlMs"] == 654
    assert listed["cacheScope"] == "public"
    refute Map.has_key?(listed, "nextCursor")

    analysis = Enum.find(listed["prompts"], &(&1["name"] == "package_analysis"))
    assert analysis == Snodo.Prompt.definition_to_map(PackageAnalysis.definition())
    assert get_in(listed, ["_meta", V2026_07_28.server_info_key(), "name"]) == "snodo-spike"
  end

  test "prompts/get shapes multi-turn messages and result metadata" do
    request_metadata =
      TestFixtures.metadata("2026-07-28", %{
        "com.example/request" => %{"trace" => "prompt-get"}
      })

    assert {:ok, %{"result" => result}} =
             MCPTest.dispatch(runtime(),
               protocol: "2026-07-28",
               method: "prompts/get",
               id: "get-1",
               params: %{
                 "name" => "package_analysis",
                 "arguments" => %{"name" => "ecto", "focus" => "adoption"},
                 "_meta" => request_metadata
               }
             )

    assert result["resultType"] == "complete"
    assert result["description"] == "Analysis workflow for ecto"
    assert Enum.map(result["messages"], & &1["role"]) == ["user", "assistant"]
    assert get_in(hd(result["messages"]), ["content", "text"]) =~ "ecto"
    refute Map.has_key?(result, "ttlMs")
    refute Map.has_key?(result, "cacheScope")

    assert get_in(result, ["_meta", "com.example/result"]) == %{
             "requestId" => "get-1",
             "request" => %{"trace" => "prompt-get"}
           }
  end

  test "prompt request validation and capability admission fail closed" do
    assert {:ok, %{"error" => missing}} =
             MCPTest.dispatch(runtime(),
               protocol: "2026-07-28",
               method: "prompts/get",
               params: %{"name" => "package_analysis"}
             )

    assert missing["code"] == -32_602
    assert missing["data"] == %{"missing" => ["name"]}

    for arguments <- [[], %{"name" => 7}, %{name: "ecto"}] do
      assert {:ok, %{"error" => %{"code" => -32_602}}} =
               MCPTest.dispatch(runtime(),
                 protocol: "2026-07-28",
                 method: "prompts/get",
                 params: %{"name" => "package_analysis", "arguments" => arguments}
               )
    end

    assert {:ok, %{"error" => cursor_error}} =
             MCPTest.dispatch(runtime(),
               protocol: "2026-07-28",
               method: "prompts/list",
               params: %{"cursor" => "next-page"}
             )

    assert cursor_error["message"] == "Invalid pagination cursor"

    unadvertised = runtime(capabilities: %{"tools" => %{}})

    for method <- ["prompts/list", "prompts/get"] do
      params = if method == "prompts/get", do: %{"name" => "package_analysis"}, else: %{}

      assert {:ok, %{"error" => %{"code" => -32_601}}} =
               MCPTest.dispatch(unadvertised,
                 protocol: "2026-07-28",
                 method: method,
                 params: params
               )
    end
  end
end
