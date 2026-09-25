defmodule Snodo.PaginationProtocolAcceptanceTest do
  use ExUnit.Case, async: true

  alias Snodo.Test, as: MCPTest
  alias SnodoTest.TestFixtures
  alias SnodoTest.TestPrompts.MediaReview
  alias SnodoTest.TestPrompts.PackageAnalysis
  alias SnodoTest.TestResources.ArchiveTemplate
  alias SnodoTest.TestResources.PackageTemplate
  alias SnodoTest.TestResources.StaticBlob
  alias SnodoTest.TestResources.StaticJSON
  alias SnodoTest.TestResources.StaticText
  alias SnodoTest.TestTools.ContextEcho
  alias SnodoTest.TestTools.Echo
  alias SnodoTest.TestTools.Structured

  @tag mcp_contract: ["list-pagination-wire"]
  test "one cursor engine traverses every list operation in stable router order" do
    runtime = runtime()

    cases = [
      {"tools/list", "tools", "name", ["context_echo", "echo", "structured"], 11, "private"},
      {"prompts/list", "prompts", "name", ["media_review", "package_analysis"], 22, "public"},
      {"resources/list", "resources", "uri",
       ["test://static/blob", "test://static/data", "test://static/readme"], 33, "private"},
      {"resources/templates/list", "resourceTemplates", "uriTemplate",
       ["test://archives/{year}/{name}", "test://packages/{name}"], 33, "private"}
    ]

    Enum.each(cases, fn {method, field, identity, expected, ttl_ms, cache_scope} ->
      {actual, pages} = collect_pages(runtime, method, field, identity)

      assert actual == expected
      assert Enum.all?(pages, &(length(&1[field]) == 1))
      assert Enum.all?(pages, &(&1["resultType"] == "complete"))
      assert Enum.all?(pages, &(&1["ttlMs"] == ttl_ms))
      assert Enum.all?(pages, &(&1["cacheScope"] == cache_scope))
      assert Enum.all?(Enum.drop(pages, -1), &is_binary(&1["nextCursor"]))
      refute Map.has_key?(List.last(pages), "nextCursor")
    end)
  end

  test "equivalent requests issue reusable deterministic cursors" do
    runtime = runtime()
    first = list(runtime, "tools/list")
    repeated = list(runtime(), "tools/list")

    assert first["nextCursor"] == repeated["nextCursor"]

    second = list(runtime, "tools/list", first["nextCursor"])
    replayed = list(runtime(), "tools/list", first["nextCursor"])

    assert second == replayed
    assert [%{"name" => "echo"}] = second["tools"]
  end

  test "malformed, cross-method, and stale-catalog cursors fail closed" do
    runtime = runtime()
    cursor = list(runtime, "tools/list")["nextCursor"]

    assert_error(runtime, "tools/list", "not-a-framework-cursor", "Invalid pagination cursor")
    assert_error(runtime, "prompts/list", cursor, "Invalid pagination cursor")

    stale_runtime =
      TestFixtures.runtime(
        tools: [Echo, Structured],
        pagination: [page_size: 1]
      )

    assert_error(stale_runtime, "tools/list", cursor, "Pagination cursor has expired")

    resized_runtime = runtime(pagination: [page_size: 2])
    assert_error(resized_runtime, "tools/list", cursor, "Pagination cursor has expired")

    assert {:ok, %{"error" => non_string}} =
             MCPTest.dispatch(runtime,
               protocol: "2026-07-28",
               method: "tools/list",
               params: %{"cursor" => 7}
             )

    assert non_string["code"] == -32_602
  end

  defp runtime(opts \\ []) do
    defaults = [
      tools: [ContextEcho, Echo, Structured],
      prompts: [PackageAnalysis, MediaReview],
      resources: [StaticText, StaticJSON, StaticBlob, PackageTemplate, ArchiveTemplate],
      tools_cache: [ttl_ms: 11, scope: "private"],
      prompts_cache: [ttl_ms: 22, scope: "public"],
      resources_cache: [ttl_ms: 33, scope: "private"],
      pagination: [page_size: 1]
    ]

    TestFixtures.runtime(Keyword.merge(defaults, opts))
  end

  defp collect_pages(runtime, method, field, identity) do
    collect_pages(runtime, method, field, identity, nil, MapSet.new(), [], [])
  end

  defp collect_pages(runtime, method, field, identity, cursor, seen, values, pages) do
    result = list(runtime, method, cursor)
    page_values = Enum.map(result[field], &Map.fetch!(&1, identity))

    case Map.fetch(result, "nextCursor") do
      {:ok, next_cursor} ->
        refute MapSet.member?(seen, next_cursor)

        collect_pages(
          runtime,
          method,
          field,
          identity,
          next_cursor,
          MapSet.put(seen, next_cursor),
          values ++ page_values,
          pages ++ [result]
        )

      :error ->
        {values ++ page_values, pages ++ [result]}
    end
  end

  defp list(runtime, method, cursor \\ nil) do
    params = if is_nil(cursor), do: %{}, else: %{"cursor" => cursor}

    assert {:ok, %{"result" => result}} =
             MCPTest.dispatch(runtime,
               protocol: "2026-07-28",
               method: method,
               params: params
             )

    result
  end

  defp assert_error(runtime, method, cursor, message) do
    assert {:ok, %{"error" => error}} =
             MCPTest.dispatch(runtime,
               protocol: "2026-07-28",
               method: method,
               params: %{"cursor" => cursor}
             )

    assert error == %{"code" => -32_602, "message" => message}
  end
end
