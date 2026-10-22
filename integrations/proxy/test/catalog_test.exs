defmodule Snodo.Proxy.CatalogTest do
  use ExUnit.Case, async: true

  alias Snodo.Proxy.Catalog

  defp backend(catalog) do
    %{
      id: "files",
      prefix: "files.",
      client: nil,
      pid: self(),
      subscribed_uris: MapSet.new(),
      catalog:
        Map.merge(%{tools: [], prompts: [], resources: [], resource_templates: []}, catalog)
    }
  end

  test "resources and templates that share a name are kept apart by URI" do
    snapshot =
      backend(%{
        resources: [
          %{"name" => "README.md", "uri" => "file:///a/README.md"},
          %{"name" => "README.md", "uri" => "file:///b/README.md"}
        ],
        resource_templates: [
          %{"name" => "README.md", "uriTemplate" => "file:///{dir}/README.md"}
        ]
      })

    assert {:ok, catalog} = Catalog.new([snapshot], 100)

    assert ["mcp-proxy://files/file:///a/README.md", "mcp-proxy://files/file:///b/README.md"] =
             Enum.map(catalog.lists.resources, & &1["uri"])

    assert [%{"name" => "files.README.md"}] = catalog.lists.resource_templates

    assert {:ok, %{original_uri: "file:///b/README.md"}, "file:///b/README.md"} =
             Catalog.lookup_resource(catalog, "mcp-proxy://files/file:///b/README.md")
  end

  test "a repeated resource URI or tool name is still a collision" do
    same_uri =
      backend(%{
        resources: [
          %{"name" => "one", "uri" => "file:///a"},
          %{"name" => "two", "uri" => "file:///a"}
        ]
      })

    assert {:error, {:resources, {:collision, "mcp-proxy://files/file:///a"}}} =
             Catalog.new([same_uri], 100)

    same_tool = backend(%{tools: [%{"name" => "read"}, %{"name" => "read"}]})
    assert {:error, {:tools, {:collision, "files.read"}}} = Catalog.new([same_tool], 100)
  end
end
