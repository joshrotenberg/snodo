defmodule Snodo.Catalog.MarkdownTest do
  use ExUnit.Case, async: false

  alias Mix.Tasks.Snodo.Catalog, as: CatalogTask
  alias Snodo.Catalog.Markdown
  alias Snodo.Client
  alias Snodo.Protocol.V2025_11_25
  alias Snodo.Transport.StreamableHTTP.Server, as: HTTPServer
  alias SnodoTest.TestFixtures
  alias SnodoTest.TestPrompts.PackageAnalysis
  alias SnodoTest.TestResources.StaticText
  alias SnodoTest.TestTools.Echo

  test "renders the component details and names missing descriptions" do
    catalog = %{
      "serverInfo" => %{"name" => "catalog server", "version" => "1.0"},
      "protocolVersion" => "2026-07-28",
      "tools" => [
        %{
          "name" => "search",
          "description" => "Search packages",
          "inputSchema" => %{
            "type" => "object",
            "properties" => %{
              "query" => %{"type" => "string", "description" => "Search term", "minLength" => 1},
              "limit" => %{"type" => "integer"}
            },
            "required" => ["query"]
          },
          "outputSchema" => %{
            "type" => "object",
            "properties" => %{"count" => %{"type" => "integer"}}
          },
          "annotations" => %{"readOnlyHint" => true}
        }
      ],
      "resources" => [
        %{"name" => "readme", "uri" => "test://readme", "mimeType" => "text/markdown"}
      ],
      "resourceTemplates" => [
        %{
          "name" => "package",
          "description" => "A package",
          "uriTemplate" => "test://packages/{name}"
        }
      ],
      "prompts" => [
        %{
          "name" => "review",
          "description" => "Review a package",
          "arguments" => [
            %{"name" => "package", "required" => true, "description" => "Package name"}
          ]
        }
      ]
    }

    markdown = Markdown.render(catalog)

    assert markdown =~ "# MCP catalog: catalog server"
    assert markdown =~ "### Tool: search"
    assert markdown =~ "| query | string | Yes | Search term | minLength=1 |"
    assert markdown =~ "#### Output schema"
    assert markdown =~ "| readOnlyHint | true |"
    assert markdown =~ "| URI template | test://packages/\\{name\\} |"
    assert markdown =~ "| package | Yes | Package name |"
    assert markdown =~ "| Component descriptions | 1 | 4 |"
    assert markdown =~ "| Argument descriptions | 1 | 3 |"
    assert markdown =~ "- resource readme"
    assert markdown =~ "- tool search\\.limit"
  end

  test "renders server-supplied Markdown characters as literal text" do
    catalog = %{
      "tools" => [
        %{
          "name" => "*lookup*",
          "description" => "Read [docs](https://example.test)\n# next line",
          "inputSchema" => %{
            "properties" => %{"q|x" => %{"type" => "string", "description" => "Use `code`"}}
          }
        }
      ]
    }

    markdown = Markdown.render(catalog)

    assert markdown =~ "### Tool: \\*lookup\\*"
    assert markdown =~ "Read \\[docs\\]\\(https://example\\.test\\) \\# next line"
    assert markdown =~ "| q\\|x | string | No | Use \\`code\\` | None |"
    assert markdown =~ "| --- | --- | --- | --- | --- |"
  end

  test "collects every page through a direct client" do
    runtime =
      TestFixtures.runtime(
        pagination: [page_size: 1],
        prompts: [PackageAnalysis],
        resources: [StaticText]
      )

    {:ok, client} = Client.direct(runtime)
    assert {:ok, catalog} = Markdown.collect(client)

    assert catalog["serverInfo"]["name"] == "snodo-spike"
    assert catalog["protocolVersion"] == "2026-07-28"
    assert length(catalog["tools"]) == 6
    assert length(catalog["resources"]) == 1
    assert length(catalog["prompts"]) == 1
    assert Markdown.render(catalog) =~ "### Prompt: package\\_analysis"
    assert :ok = Client.close(client)
  end

  test "collects from an initialize-era server" do
    runtime = TestFixtures.runtime(protocols: [V2025_11_25], tools: [Echo])
    {:ok, client} = Client.direct(runtime)

    assert {:ok, %{"protocolVersion" => "2025-11-25", "serverInfo" => info}} =
             Markdown.collect(client)

    assert info["name"] == "snodo-spike"
    assert :ok = Client.close(client)
  end

  test "mix task writes the catalog from a local module and an HTTP endpoint" do
    local_path = temp_path("local")
    remote_path = temp_path("remote")
    on_exit(fn -> Enum.each([local_path, remote_path], &File.rm/1) end)

    CatalogTask.run(["--server", "SnodoTest.TestServer", "--output", local_path])
    assert File.read!(local_path) =~ "### Tool: echo"

    runtime = TestFixtures.runtime()
    {:ok, server} = start_supervised({HTTPServer, runtime: runtime, port: 0})
    CatalogTask.run(["--url", HTTPServer.url(server), "--output", remote_path])
    assert File.read!(remote_path) =~ "### Tool: complex\\_schema"
  end

  test "mix task requires exactly one source" do
    assert_raise Mix.Error, ~r/usage: mix snodo.catalog/, fn -> CatalogTask.run([]) end

    assert_raise Mix.Error, ~r/usage: mix snodo.catalog/, fn ->
      CatalogTask.run(["--server", "SnodoTest.TestServer", "--url", "http://localhost/mcp"])
    end
  end

  defp temp_path(name) do
    Path.join(System.tmp_dir!(), "snodo-catalog-#{name}-#{System.unique_integer([:positive])}.md")
  end
end
