defmodule Snodo.ToolMetadataAcceptanceTest do
  use ExUnit.Case, async: true

  @icons [
    %{
      "src" => "https://example.test/search.png",
      "mimeType" => "image/png",
      "sizes" => ["48x48"],
      "theme" => "dark"
    }
  ]
  @metadata %{"com.example/tool" => %{"owner" => "catalog"}}

  defmodule RawTool do
    use Snodo.Tool,
      name: "metadata_tool",
      title: "Search packages",
      description: "Find packages",
      icons: [
        %{
          "src" => "https://example.test/search.png",
          "mimeType" => "image/png",
          "sizes" => ["48x48"],
          "theme" => "dark"
        }
      ],
      metadata: %{"com.example/tool" => %{"owner" => "catalog"}}

    input_schema(%{"type" => "object", "properties" => %{}})

    @impl true
    def call(_arguments, _context), do: {:ok, "found"}
  end

  defmodule SimpleTool do
    use Snodo.Tool.Simple,
      name: "metadata_tool",
      title: "Search packages",
      description: "Find packages",
      icons: [
        %{
          "src" => "https://example.test/search.png",
          "mimeType" => "image/png",
          "sizes" => ["48x48"],
          "theme" => "dark"
        }
      ],
      metadata: %{"com.example/tool" => %{"owner" => "catalog"}}

    @impl true
    def call(_arguments, _context), do: {:ok, "found"}
  end

  defmodule MacroTool do
    use Snodo.Tool, name: "macro_tool", title: "Old title"

    title("New title")
    icons([%{"src" => "data:image/png;base64,AA=="}])
    metadata(%{"com.example/feature" => true})

    @impl true
    def call(_arguments, _context), do: {:ok, "ok"}
  end

  defmodule DirectTool do
    @behaviour Snodo.Tool

    @impl true
    def name, do: "direct_tool"
    @impl true
    def description, do: nil
    @impl true
    def input_schema, do: %{"type" => "object"}
    @impl true
    def output_schema, do: nil
    @impl true
    def annotations, do: %{}
    @impl true
    def call(_arguments, _context), do: {:ok, "ok"}
  end

  defmodule DirectRichTool do
    @behaviour Snodo.Tool

    @impl true
    def name, do: "direct_rich_tool"
    @impl true
    def title, do: "Direct title"
    @impl true
    def description, do: nil
    @impl true
    def input_schema, do: %{"type" => "object"}
    @impl true
    def output_schema, do: nil
    @impl true
    def annotations, do: %{}
    @impl true
    def icons, do: [%{"src" => "data:image/png;base64,AA=="}]
    @impl true
    def metadata, do: %{"com.example/direct" => true}
    @impl true
    def call(_arguments, _context), do: {:ok, "ok"}
  end

  defmodule InvalidDirectTool do
    @behaviour Snodo.Tool

    @impl true
    def name, do: "invalid_direct_tool"
    @impl true
    def description, do: nil
    @impl true
    def input_schema, do: %{"type" => "object"}
    @impl true
    def output_schema, do: nil
    @impl true
    def annotations, do: %{}
    @impl true
    def icons, do: [%{"src" => "relative.png"}]
    @impl true
    def call(_arguments, _context), do: {:ok, "ok"}
  end

  defmodule Server do
    use Snodo.Server,
      name: "tool-metadata-test",
      version: "1",
      protocols: [
        Snodo.Protocol.V2026_07_28,
        Snodo.Protocol.V2025_11_25,
        Snodo.Protocol.V2025_06_18
      ]

    tool(RawTool)
    tool(DirectTool)

    tool "inline_tool",
      title: "Inline title",
      icons: [%{"src" => "data:image/png;base64,AA=="}],
      metadata: %{"com.example/inline" => ["present"]} do
      @impl true
      def call(_arguments, _context), do: {:ok, "ok"}
    end
  end

  test "raw and simple tools produce the same definition with metadata" do
    definition = Snodo.Tool.definition(RawTool)

    assert definition == Snodo.Tool.definition(SimpleTool)
    assert definition.title == "Search packages"
    assert definition.icons == @icons
    assert definition.metadata == @metadata

    assert MacroTool.title() == "New title"
    assert MacroTool.icons() == [%{"src" => "data:image/png;base64,AA=="}]
    assert MacroTool.metadata() == %{"com.example/feature" => true}
  end

  test "direct tool implementations can omit the new callbacks" do
    definition = Snodo.Tool.definition(DirectTool)
    assert definition.title == nil
    assert definition.icons == []
    assert definition.metadata == %{}

    rich = Snodo.Tool.definition(DirectRichTool)
    assert rich.title == "Direct title"
    assert rich.icons == [%{"src" => "data:image/png;base64,AA=="}]
    assert rich.metadata == %{"com.example/direct" => true}

    assert_raise ArgumentError, ~r/tool icon src must be an absolute URI/, fn ->
      Snodo.Tool.definition(InvalidDirectTool)
    end
  end

  test "tool list fields match each protocol revision" do
    for version <- ["2026-07-28", "2025-11-25", "2025-06-18"] do
      {:ok, %{"result" => %{"tools" => tools}}} =
        Snodo.Test.dispatch(Server.runtime(), protocol: version, method: "tools/list")

      assert Enum.map(tools, & &1["name"]) == ["direct_tool", "inline_tool", "metadata_tool"]

      direct = Enum.find(tools, &(&1["name"] == "direct_tool"))
      refute Map.has_key?(direct, "title")
      refute Map.has_key?(direct, "icons")
      refute Map.has_key?(direct, "_meta")

      raw = Enum.find(tools, &(&1["name"] == "metadata_tool"))
      assert raw["title"] == "Search packages"
      assert raw["_meta"] == @metadata

      inline = Enum.find(tools, &(&1["name"] == "inline_tool"))
      assert inline["title"] == "Inline title"
      assert inline["_meta"] == %{"com.example/inline" => ["present"]}

      if version == "2025-06-18" do
        refute Map.has_key?(raw, "icons")
        refute Map.has_key?(inline, "icons")
      else
        assert raw["icons"] == @icons
        assert inline["icons"] == [%{"src" => "data:image/png;base64,AA=="}]
      end
    end
  end

  test "bad title, icon, and metadata declarations fail at compile time" do
    invalid = [
      {"title: 1", ~r/title must evaluate to a string or nil/},
      {"icons: [%{\"src\" => \"relative.png\"}]", ~r/tool icon src must be an absolute URI/},
      {"icons: [%{\"src\" => \"https:\/\/example.test\/icon.png\", \"theme\" => \"blue\"}]",
       ~r/tool icon theme must be light or dark/},
      {"metadata: %{\"bad key\" => true}", ~r/tool _meta contains an invalid entry/}
    ]

    for {{option, message}, index} <- Enum.with_index(invalid) do
      source = """
      defmodule SnodoTest.BadToolMetadata#{index} do
        use Snodo.Tool, name: "bad_metadata_#{index}", #{option}
        @impl true
        def call(_arguments, _context), do: {:ok, "never"}
      end
      """

      assert_raise CompileError, message, fn -> Code.compile_string(source) end
    end
  end
end
