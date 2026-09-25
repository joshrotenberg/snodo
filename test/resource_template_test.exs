defmodule Snodo.ResourceTemplateTest do
  use ExUnit.Case, async: true

  alias Snodo.Resource.Template

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

    test "percent-encoded literal characters remain supported" do
      assert {:ok, template} = Template.compile("hex://packages/hello%20world/{name}")

      assert Template.match(template, "hex://packages/hello%20world/ecto") ==
               {:ok, %{"name" => "ecto"}}
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
      assert Template.compile("hex://{name}/info/") == :unsupported
      assert Template.compile("hex://{name}/") == :unsupported
    end

    test "variables that shadow request parameters" do
      assert Template.compile("hex://{uri}/info") == :unsupported
      assert Template.compile("hex://packages/{_meta}") == :unsupported
    end

    test "malformed percent escapes or non-UTF-8 literals" do
      for literal <- ["bad%", "bad%2", "bad%GG", "%FF"] do
        assert Template.compile("hex://packages/#{literal}") == :unsupported
      end
    end

    test "literal URI forms that cannot pass concrete URI validation" do
      for template <- [
            "hex://bad authority/{name}",
            "hex://packages/hello world",
            "hex://packages/<literal>",
            "hex://packages/back\\slash",
            "hex://[invalid]/{name}",
            "hex://packages/café"
          ] do
        assert Template.compile(template) == :unsupported
      end
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

    test "scheme case is normalized without changing literal or variable case" do
      for template_scheme <- ["hex", "HEX", "HeX"], uri_scheme <- ["hex", "HEX", "hEx"] do
        assert {:ok, template} = Template.compile("#{template_scheme}://Packages/{name}/Info")

        assert Template.match(template, "#{uri_scheme}://Packages/Ecto/Info") ==
                 {:ok, %{"name" => "Ecto"}}

        assert Template.match(template, "#{uri_scheme}://packages/Ecto/Info") == :error
        assert Template.match(template, "#{uri_scheme}://Packages/Ecto/info") == :error
      end

      assert {:ok, template} = Template.compile("HeX://{name}/info")
      assert Template.match(template, "HEX://Ecto/info") == {:ok, %{"name" => "Ecto"}}
    end

    test "requires the segment count to match", %{hex: hex, bare: bare} do
      assert Template.match(hex, "hex://jason") == :error
      assert Template.match(hex, "hex://jason/info/extra") == :error
      assert Template.match(bare, "hex://jason/info") == :error
    end

    test "never binds an empty segment", %{hex: hex} do
      assert Template.match(hex, "hex:///info") == :error
    end

    test "preserves doubled and trailing slashes", %{hex: hex, toolbox: toolbox, bare: bare} do
      assert Template.match(hex, "hex://jason//info") == :error
      assert Template.match(hex, "hex://jason/info/") == :error
      assert Template.match(toolbox, "toolbox://web//frameworks") == :error
      assert Template.match(toolbox, "toolbox://web/") == :error
      assert Template.match(bare, "hex://jason/") == :error
    end

    test "rejects a URI carrying a query, fragment, or port", %{hex: hex} do
      assert Template.match(hex, "hex://jason/info?full=1") == :error
      assert Template.match(hex, "hex://jason/info#top") == :error
      assert Template.match(hex, "hex://jason:8080/info") == :error
      assert Template.match(hex, "hex://user@jason/info") == :error
    end

    test "rejects explicit default ports as well as non-default ports" do
      for {scheme, default_port} <- [{"http", 80}, {"https", 443}] do
        assert {:ok, template} = Template.compile("#{scheme}://{host}/info")

        assert Template.match(template, "#{scheme}://example.com/info") ==
                 {:ok, %{"host" => "example.com"}}

        assert Template.match(template, "#{scheme}://example.com:#{default_port}/info") == :error
        assert Template.match(template, "#{scheme}://example.com:8080/info") == :error
        assert Template.match(template, "#{scheme}://example.com:/info") == :error
      end
    end

    test "percent-decodes bound values", %{toolbox: toolbox} do
      assert Template.match(toolbox, "toolbox://web/web%20frameworks") ==
               {:ok, %{"group" => "web", "category" => "web frameworks"}}
    end

    test "decodes once, preserving encoded separators and literal plus signs", %{toolbox: toolbox} do
      for {encoded, decoded} <- [
            {"a%2Fb", "a/b"},
            {"a%252Fb", "a%2Fb"},
            {"a+b", "a+b"},
            {"caf%C3%A9", "café"}
          ] do
        assert Template.match(toolbox, "toolbox://web/#{encoded}") ==
                 {:ok, %{"group" => "web", "category" => decoded}}
      end
    end

    test "rejects malformed percent escapes and decoded invalid UTF-8", %{toolbox: toolbox} do
      for invalid <- ["%", "%2", "%GG", "%FF", "%C3%28"] do
        assert Template.match(toolbox, "toolbox://web/#{invalid}") == :error
        assert Template.match(toolbox, "toolbox://#{invalid}/frameworks") == :error
      end
    end

    test "repeated variables must bind identical decoded values" do
      assert {:ok, template} = Template.compile("hex://{name}/{name}")

      assert Template.match(template, "hex://jason/jason") == {:ok, %{"name" => "jason"}}
      assert Template.match(template, "hex://jason/%6Aason") == {:ok, %{"name" => "jason"}}
      assert Template.match(template, "hex://jason/ecto") == :error

      assert {:ok, template} = Template.compile("hex://packages/{name}/{name}")
      assert Template.match(template, "hex://packages/jason/jason") == {:ok, %{"name" => "jason"}}
      assert Template.match(template, "hex://packages/jason/ecto") == :error
    end

    test "literal matching does not decode or normalize escapes" do
      assert {:ok, template} = Template.compile("hex://{name}/a%2Fb")
      assert Template.match(template, "hex://jason/a%2Fb") == {:ok, %{"name" => "jason"}}
      assert Template.match(template, "hex://jason/a%2fb") == :error
      assert Template.match(template, "hex://jason/a/b") == :error
    end

    test "does not match the template string itself", %{hex: hex} do
      assert Template.match(hex, "hex://{name}/info") == :error
    end

    test "a single-segment URI does not reach a two-segment template", %{toolbox: toolbox} do
      assert Template.match(toolbox, "toolbox://groups") == :error
    end
  end
end
