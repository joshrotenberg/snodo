defmodule MCP.CompletionProtocolAcceptanceTest do
  use ExUnit.Case, async: true

  alias MCP.Protocol.V2026_07_28
  alias MCP.Test, as: MCPTest
  alias MCPEx.TestCompletions.PackagePrompt
  alias MCPEx.TestCompletions.RepositoryTemplate
  alias MCPEx.TestFixtures

  defp runtime(opts \\ []) do
    defaults = [tools: [], prompts: [PackagePrompt], resources: [RepositoryTemplate]]
    TestFixtures.runtime(Keyword.merge(defaults, opts))
  end

  test "discovery advertises completions only for completion-capable definitions" do
    assert runtime().capabilities == %{
             "completions" => %{},
             "prompts" => %{},
             "resources" => %{}
           }

    assert {:ok, %{"result" => discovery}} =
             MCPTest.dispatch(runtime(),
               protocol: "2026-07-28",
               method: "server/discover"
             )

    assert discovery["capabilities"]["completions"] == %{}

    refute Map.has_key?(
             TestFixtures.runtime(tools: [], prompts: [], resources: []).capabilities,
             "completions"
           )

    assert_raise ArgumentError, ~r/completions capability requires/, fn ->
      TestFixtures.runtime(
        tools: [],
        prompts: [],
        resources: [],
        capabilities: %{"completions" => %{}}
      )
    end
  end

  test "completion/complete shapes prompt and resource-template results without cache hints" do
    request_metadata =
      TestFixtures.metadata("2026-07-28", %{
        "com.example/request" => %{"trace" => "completion"}
      })

    assert {:ok, %{"result" => prompt_result}} =
             MCPTest.dispatch(runtime(),
               protocol: "2026-07-28",
               id: "complete-prompt",
               method: "completion/complete",
               params: %{
                 "ref" => %{"type" => "ref/prompt", "name" => "package_search"},
                 "argument" => %{"name" => "name", "value" => "ec"},
                 "_meta" => request_metadata
               }
             )

    assert prompt_result["resultType"] == "complete"

    assert prompt_result["completion"] == %{
             "values" => ["ecto", "ecto_sql"],
             "total" => 2,
             "hasMore" => false
           }

    refute Map.has_key?(prompt_result, "ttlMs")
    refute Map.has_key?(prompt_result, "cacheScope")

    assert get_in(prompt_result, ["_meta", V2026_07_28.server_info_key(), "name"]) ==
             "mcp-ex-spike"

    assert {:ok, %{"result" => resource_result}} =
             MCPTest.dispatch(runtime(),
               protocol: "2026-07-28",
               method: "completion/complete",
               params: %{
                 "ref" => %{
                   "type" => "ref/resource",
                   "uri" => "repo://{owner}/{name}"
                 },
                 "argument" => %{"name" => "name", "value" => "ec"},
                 "context" => %{"arguments" => %{"owner" => "elixir-ecto"}}
               }
             )

    assert resource_result["completion"]["values"] == ["ecto", "ecto_sql"]
  end

  test "wire validation and capability admission fail closed" do
    valid_ref = %{"type" => "ref/prompt", "name" => "package_search"}
    valid_argument = %{"name" => "name", "value" => "ec"}

    invalid_params = [
      %{"argument" => valid_argument},
      %{"ref" => valid_ref},
      %{"ref" => %{"type" => "ref/tool", "name" => "echo"}, "argument" => valid_argument},
      %{"ref" => valid_ref, "argument" => %{"name" => "name", "value" => 7}},
      %{"ref" => valid_ref, "argument" => valid_argument, "context" => []},
      %{
        "ref" => valid_ref,
        "argument" => valid_argument,
        "context" => %{"arguments" => %{"focus" => 7}}
      }
    ]

    Enum.each(invalid_params, fn params ->
      assert {:ok, %{"error" => %{"code" => -32_602}}} =
               MCPTest.dispatch(runtime(),
                 protocol: "2026-07-28",
                 method: "completion/complete",
                 params: params
               )
    end)

    unadvertised =
      runtime(capabilities: %{"prompts" => %{}, "resources" => %{}})

    assert {:ok, %{"error" => %{"code" => -32_601}}} =
             MCPTest.dispatch(unadvertised,
               protocol: "2026-07-28",
               method: "completion/complete",
               params: %{"ref" => valid_ref, "argument" => valid_argument}
             )
  end
end
