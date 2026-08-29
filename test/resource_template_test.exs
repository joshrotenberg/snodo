defmodule MCP.ResourceTemplateTest do
  use ExUnit.Case, async: true

  alias MCP.Resource.Template

  describe "compile/1 accepts the simple-expansion subset" do
    test "a variable authority with a literal segment" do
      assert {:ok, template} = Template.compile("hex://{name}/info")
      assert Template.variables(template) == ["name"]
    end

    test "several variables" do
      assert {:ok, template} = Template.compile("toolbox://{group}/{category}")
      assert Template.variables(template) == ["group", "category"]
    end

    test "a literal authority" do
      assert {:ok, template} = Template.compile("toolbox://groups/{category}")
      assert Template.variables(template) == ["category"]
    end

    test "no path at all" do
      assert {:ok, template} = Template.compile("hex://{name}")
      assert Template.variables(template) == ["name"]
    end
  end

  describe "compile/1 refuses everything else" do
    test "an RFC 6570 operator" do
      assert Template.compile("hex://{+name}/info") == :unsupported
      assert Template.compile("hex://{name}{?sort}") == :unsupported
      assert Template.compile("hex://{/name}") == :unsupported
    end

    test "an explode or prefix modifier" do
      assert Template.compile("hex://{name*}/info") == :unsupported
      assert Template.compile("hex://{name:3}/info") == :unsupported
    end

    test "a variable that is only part of a segment" do
      assert Template.compile("hex://{name}/v{version}") == :unsupported
      assert Template.compile("hex://pkg-{name}/info") == :unsupported
    end

    test "a query, fragment, port, or userinfo" do
      assert Template.compile("hex://{name}/info?full=1") == :unsupported
      assert Template.compile("hex://{name}/info#top") == :unsupported
      assert Template.compile("hex://{name}:8080/info") == :unsupported
      assert Template.compile("hex://user@{name}/info") == :unsupported
    end

    test "a templated scheme, or no scheme" do
      assert Template.compile("{scheme}://host/path") == :unsupported
      assert Template.compile("hex:/{name}") == :unsupported
      assert Template.compile("not a uri") == :unsupported
    end

    test "an empty segment" do
      assert Template.compile("hex://{name}//info") == :unsupported
    end
  end

  describe "match/2" do
    setup do
      {:ok, hex} = Template.compile("hex://{name}/info")
      {:ok, toolbox} = Template.compile("toolbox://{group}/{category}")
      {:ok, bare} = Template.compile("hex://{name}")

      %{hex: hex, toolbox: toolbox, bare: bare}
    end

    test "binds each variable to a whole segment", %{hex: hex, toolbox: toolbox} do
      assert Template.match(hex, "hex://jason/info") == {:ok, %{"name" => "jason"}}
      assert Template.match(hex, "hex://ecto_sql/info") == {:ok, %{"name" => "ecto_sql"}}

      assert Template.match(toolbox, "toolbox://web/frameworks") ==
               {:ok, %{"group" => "web", "category" => "frameworks"}}
    end

    test "requires the literal segments to match", %{hex: hex} do
      assert Template.match(hex, "hex://jason/readme") == :error
    end

    test "requires the scheme to match", %{hex: hex} do
      assert Template.match(hex, "npm://jason/info") == :error
    end

    test "requires the segment count to match", %{hex: hex, bare: bare} do
      assert Template.match(hex, "hex://jason") == :error
      assert Template.match(hex, "hex://jason/info/extra") == :error
      assert Template.match(bare, "hex://jason/info") == :error
    end

    test "never binds an empty segment", %{hex: hex} do
      assert Template.match(hex, "hex:///info") == :error
    end

    test "rejects a URI carrying a query, fragment, or port", %{hex: hex} do
      assert Template.match(hex, "hex://jason/info?full=1") == :error
      assert Template.match(hex, "hex://jason/info#top") == :error
      assert Template.match(hex, "hex://jason:8080/info") == :error
    end

    test "percent-decodes bound values", %{toolbox: toolbox} do
      assert Template.match(toolbox, "toolbox://web/web%20frameworks") ==
               {:ok, %{"group" => "web", "category" => "web frameworks"}}
    end

    test "does not match the template string itself", %{hex: hex} do
      assert Template.match(hex, "hex://{name}/info") == :error
    end

    test "a single-segment URI does not reach a two-segment template", %{toolbox: toolbox} do
      assert Template.match(toolbox, "toolbox://groups") == :error
    end
  end
end
