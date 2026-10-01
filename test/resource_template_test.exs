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

  describe "compile/1 names the shapes it refuses" do
    defp refused(template) do
      assert {:error, reason} = Template.compile(template)
      assert is_binary(reason)
      reason
    end

    test "operators other than simple, reserved, path, and query expansion" do
      assert refused("hex://{name}/{#frag}") =~ "fragment expansion"
      assert refused("hex://{name}/x{.ext}") =~ "label expansion"
      assert refused("hex://{name}/{;params}") =~ "path-style parameter"

      for op <- ["=", ",", "!", "@", "|"] do
        assert refused("hex://{name}/{#{op}x}") =~ "reserved operator #{op}"
      end
    end

    test "prefix modifiers and explode outside path segment expansion" do
      assert refused("hex://{name:3}/info") =~ "prefix modifier"
      assert refused("hex://{name}/{version:3}") =~ "prefix modifier"
      assert refused("hex://{name}/{version*}") =~ "exploded simple or reserved"
      assert refused("hex://{name}/{+path*}") =~ "exploded simple or reserved"
      assert refused("hex://{name}{?tags*}") =~ "exploded query variable"
      assert refused("hex://{name*}/info") =~ "authority"
    end

    test "several variables in one simple, reserved, or path expression" do
      assert refused("hex://{name}/{a,b}") =~ "more than one variable"
      assert refused("hex://{name}/{+a,b}") =~ "more than one variable"
      assert refused("hex://{name}{/a,b}") =~ "more than one variable in a path expression"
    end

    test "more than one variable-length path expression" do
      for template <- [
            "hex://{name}{/a}{/b}",
            "hex://{name}/{+a}/{+b}",
            "hex://{name}{/a*}/x/{+b}",
            "hex://{name}{/a}/x{/b*}"
          ] do
        assert refused(template) =~ "more than one variable-length path expression"
      end
    end

    test "an expression that shares a path segment" do
      for template <- [
            "hex://{name}/v{version}",
            "hex://{name}/{version}.json",
            "hex://{name}/{a}{b}",
            "hex://{name}{/version}x",
            "hex://{name}/{+path}.json"
          ] do
        assert refused(template) =~ "path segment that holds"
      end
    end

    test "an authority that is not one literal or one {var}" do
      assert refused("hex://pkg-{name}/info") =~ "authority"
      assert refused("hex://{+host}/info") =~ "reserved expansion ({+var}) in the authority"
      assert refused("hex://{/name}") =~ "empty authority that is not followed by /"
      assert refused("hex://{?q}") =~ "empty authority that is not followed by /"
    end

    test "misplaced query expressions" do
      assert refused("hex://{name}{?q}/info") =~ "after a query expression"
      assert refused("hex://{name}{?q}x") =~ "after a query expression"
      assert refused("hex://{name}{&q}") =~ "without a preceding {?var}"
      assert refused("hex://{name}{?a}{?b}") =~ "more than one {?var}"
      assert refused("hex://{name}{?a,a}") =~ "named more than once"
      assert refused("hex://{name}{?a}{&a}") =~ "named more than once"
    end

    test "a literal query, fragment, port, or userinfo" do
      assert refused("hex://{name}/info?full=1") =~ "literal query"
      assert refused("hex://{name}/search?type=x{&q}") =~ "literal query"
      assert refused("hex://{name}/info#top") =~ "literal fragment"
      assert refused("hex://{name}:8080/info") =~ "port"
      assert refused("hex://host:8080/info") =~ "port"
      assert refused("hex://user@{name}/info") =~ "userinfo"
      assert refused("hex://user@host/{name}") =~ "userinfo"
    end

    test "a templated scheme, or no scheme" do
      for template <- ["{scheme}://host/path", "hex:/{name}", "not a uri"] do
        assert refused(template) =~ "scheme"
      end
    end

    test "an empty segment" do
      for template <- [
            "hex://{name}//info",
            "hex://{name}/info/",
            "hex://{name}/",
            "file:///"
          ] do
        assert refused(template) =~ "empty path segment"
      end

      assert refused("hex://{name}/{/version}") =~ "{/var} expression after a literal /"
      assert refused("hex://h/{/a*}") =~ "{/var} expression after a literal /"
    end

    test "variables that shadow request parameters" do
      assert refused("hex://{uri}/info") =~ "variable named uri"
      assert refused("hex://packages/{_meta}") =~ "variable named _meta"
      assert refused("hex://{name}{?uri}") =~ "variable named uri"
      assert refused("hex://{name}{/_meta*}") =~ "variable named _meta"
    end

    test "malformed expressions" do
      assert refused("hex://{name/info") =~ "unclosed"
      assert refused("hex://{na{me}}/info") =~ "nested"
      assert refused("hex://name}/info") =~ "outside an expression"
      assert refused("hex://{}/info") =~ "invalid variable name"
      assert refused("hex://{a b}/info") =~ "invalid variable name"
      assert refused("hex://{name}/{?}") =~ "invalid variable name"
    end

    test "malformed percent escapes or non-UTF-8 literals" do
      for literal <- ["bad%", "bad%2", "bad%GG", "%FF"] do
        assert refused("hex://packages/#{literal}") =~ "percent escape"
      end

      assert refused(<<"hex://packages/", 0xFF>>) =~ "UTF-8"
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
        assert refused(template) =~ "not valid in a URI"
      end
    end

    test "templates longer than 1,024 bytes or with more than 32 variables" do
      long = "hex://{name}/" <> String.duplicate("a", 1024 - byte_size("hex://{name}/"))
      assert {:ok, _template} = Template.compile(long)
      assert refused(long <> "a") =~ "longer than 1024 bytes"

      path = Enum.map_join(1..31, "/", &"{v#{&1}}")
      assert {:ok, template} = Template.compile("hex://{name}/" <> path)
      assert length(Template.variables(template)) == 32
      assert refused("hex://{name}/" <> path <> "/{v32}") =~ "more than 32 variables"
      assert refused("hex://{name}/" <> path <> "{?q}") =~ "more than 32 variables"
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

  defp compiled(template) do
    assert {:ok, compiled} = Template.compile(template)
    compiled
  end

  describe "reserved expansion {+var}" do
    test "binds one or more whole segments, joined with /" do
      template = compiled("files://{root}/{+path}")
      assert Template.variables(template) == ["root", "path"]

      assert Template.match(template, "files://docs/a") ==
               {:ok, %{"root" => "docs", "path" => "a"}}

      assert Template.match(template, "files://docs/a/b/c.txt") ==
               {:ok, %{"root" => "docs", "path" => "a/b/c.txt"}}

      assert Template.match(template, "files://docs") == :error
      assert Template.match(template, "files://docs/") == :error
    end

    test "keeps reserved characters and decodes escapes" do
      template = compiled("files://{root}/{+path}")

      assert Template.match(template, "files://docs/a,b;c=d!$'()*+") ==
               {:ok, %{"root" => "docs", "path" => "a,b;c=d!$'()*+"}}

      assert Template.match(template, "files://docs/caf%C3%A9/a%20b") ==
               {:ok, %{"root" => "docs", "path" => "café/a b"}}

      # An encoded slash and a literal one bind the same value.
      assert Template.match(template, "files://docs/a%2Fb") ==
               {:ok, %{"root" => "docs", "path" => "a/b"}}
    end

    test "does not remove dot segments" do
      template = compiled("files://{root}/{+path}")

      assert Template.match(template, "files://docs/../../etc/passwd") ==
               {:ok, %{"root" => "docs", "path" => "../../etc/passwd"}}

      assert Template.match(template, "files://docs/%2E%2E/x") ==
               {:ok, %{"root" => "docs", "path" => "../x"}}
    end

    test "matches fixed segments from each end" do
      template = compiled("hex://{name}/files/{+path}/raw")

      assert Template.match(template, "hex://jason/files/lib/jason.ex/raw") ==
               {:ok, %{"name" => "jason", "path" => "lib/jason.ex"}}

      assert Template.match(template, "hex://jason/files/raw/raw") ==
               {:ok, %{"name" => "jason", "path" => "raw"}}

      assert Template.match(template, "hex://jason/files/raw") == :error
      assert Template.match(template, "hex://jason/other/a/raw") == :error
      assert Template.match(template, "hex://jason/files/a/info") == :error
    end

    test "never binds empty segments or crosses into a query" do
      template = compiled("files://{root}/{+path}")

      for uri <- [
            "files://docs/a//b",
            "files://docs/a/",
            "files://docs/a?x=1",
            "files://docs/a#top",
            "files://docs/a%GG",
            "files://docs/%FF"
          ] do
        assert Template.match(template, uri) == :error, uri
      end
    end
  end

  describe "path segment expansion {/var} and {/var*}" do
    test "{/var} binds zero or one segment" do
      template = compiled("hex://{name}{/version}")
      assert Template.variables(template) == ["name", "version"]

      assert Template.match(template, "hex://jason") == {:ok, %{"name" => "jason"}}

      assert Template.match(template, "hex://jason/1.4.0") ==
               {:ok, %{"name" => "jason", "version" => "1.4.0"}}

      assert Template.match(template, "hex://jason/1.4.0/x") == :error
      assert Template.match(template, "hex://jason/") == :error
    end

    test "{/var} between fixed segments" do
      template = compiled("hex://{name}/releases{/version}/info")

      assert Template.match(template, "hex://jason/releases/info") == {:ok, %{"name" => "jason"}}

      assert Template.match(template, "hex://jason/releases/1.0/info") ==
               {:ok, %{"name" => "jason", "version" => "1.0"}}

      assert Template.match(template, "hex://jason/releases/1.0/2.0/info") == :error
      assert Template.match(template, "hex://jason/releases//info") == :error
    end

    test "{/var*} binds zero or more segments, joined with /" do
      template = compiled("hex://{name}/docs{/page*}")

      assert Template.match(template, "hex://jason/docs") == {:ok, %{"name" => "jason"}}

      assert Template.match(template, "hex://jason/docs/a") ==
               {:ok, %{"name" => "jason", "page" => "a"}}

      assert Template.match(template, "hex://jason/docs/a/b%20c/d") ==
               {:ok, %{"name" => "jason", "page" => "a/b c/d"}}

      assert Template.match(template, "hex://jason/docs/") == :error
      assert Template.match(template, "hex://jason/docs/a//b") == :error
      assert Template.match(template, "hex://jason/other/a") == :error
    end

    test "{/var*} with a fixed suffix" do
      template = compiled("hex://{name}{/page*}/raw")

      assert Template.match(template, "hex://jason/raw") == {:ok, %{"name" => "jason"}}

      assert Template.match(template, "hex://jason/a/b/raw") ==
               {:ok, %{"name" => "jason", "page" => "a/b"}}

      assert Template.match(template, "hex://jason") == :error
    end

    test "repeated variables across expressions must agree" do
      template = compiled("hex://{name}{/name}")

      assert Template.match(template, "hex://jason") == {:ok, %{"name" => "jason"}}
      assert Template.match(template, "hex://jason/jason") == {:ok, %{"name" => "jason"}}
      assert Template.match(template, "hex://jason/ecto") == :error
    end
  end

  describe "query expansion {?a,b} and {&c}" do
    test "binds named parameters in any order, each optional" do
      template = compiled("search://{index}{?q,lang}")
      assert Template.variables(template) == ["index", "q", "lang"]

      assert Template.match(template, "search://hex") == {:ok, %{"index" => "hex"}}

      assert Template.match(template, "search://hex?q=json") ==
               {:ok, %{"index" => "hex", "q" => "json"}}

      assert Template.match(template, "search://hex?q=json&lang=en") ==
               {:ok, %{"index" => "hex", "q" => "json", "lang" => "en"}}

      assert Template.match(template, "search://hex?lang=en&q=json") ==
               {:ok, %{"index" => "hex", "q" => "json", "lang" => "en"}}
    end

    test "{&var} continues the query" do
      template = compiled("search://hex/packages{?q}{&sort,page}")
      assert Template.variables(template) == ["q", "sort", "page"]

      assert Template.match(template, "search://hex/packages?sort=name&q=js&page=2") ==
               {:ok, %{"q" => "js", "sort" => "name", "page" => "2"}}
    end

    test "decodes values once without turning + into a space" do
      template = compiled("search://{index}{?q}")

      for {encoded, decoded} <- [
            {"a%20b", "a b"},
            {"a+b", "a+b"},
            {"a%2Bb", "a+b"},
            {"a%26b%3Dc", "a&b=c"},
            {"a%252F", "a%2F"},
            {"a=b", "a=b"},
            {"caf%C3%A9", "café"},
            {"", ""}
          ] do
        assert Template.match(template, "search://hex?q=#{encoded}") ==
                 {:ok, %{"index" => "hex", "q" => decoded}},
               encoded
      end
    end

    test "refuses unknown, repeated, or malformed parameters" do
      template = compiled("search://{index}{?q,lang}")

      for query <- [
            "",
            "x=1",
            "q=1&x=1",
            "q=1&q=2",
            "q",
            "q=1&",
            "&q=1",
            "q=1&&lang=en",
            "Q=1",
            "%71=1",
            "q=%GG",
            "q=%FF",
            "q=1&lang=en&q=1"
          ] do
        assert Template.match(template, "search://hex?#{query}") == :error, query
      end

      assert Template.match(template, "search://hex?q=1#top") == :error
    end

    test "combines with path expressions" do
      template = compiled("files://{root}/{+path}{?rev}")

      assert Template.match(template, "files://docs/a/b?rev=3") ==
               {:ok, %{"root" => "docs", "path" => "a/b", "rev" => "3"}}

      assert Template.match(template, "files://docs/a/b") ==
               {:ok, %{"root" => "docs", "path" => "a/b"}}

      template = compiled("hex://{name}{?q}")

      assert Template.match(template, "hex://jason?q=1") ==
               {:ok, %{"name" => "jason", "q" => "1"}}

      assert Template.match(template, "hex://jason/?q=1") == :error
    end

    test "a query variable that repeats a path variable must agree" do
      template = compiled("hex://{name}{?name}")

      assert Template.match(template, "hex://jason?name=jason") == {:ok, %{"name" => "jason"}}
      assert Template.match(template, "hex://jason?name=ecto") == :error
    end

    test "a template without query expressions still refuses any query" do
      template = compiled("hex://{name}/info")

      assert Template.match(template, "hex://jason/info?q=1") == :error
      assert Template.match(template, "hex://jason/info?") == :error
    end
  end

  describe "matching cost" do
    test "a long query is refused at the first parameter the template does not name" do
      template = compiled("search://{index}{?q}")
      query = "q=1&" <> String.duplicate("x=1&", 200_000) <> "x=1"

      assert Template.match(template, "search://hex?" <> query) == :error
    end

    test "a long path is matched in one pass" do
      template = compiled("files://{root}/{+path}/raw")
      path = Enum.map_join(1..50_000, "/", fn _n -> "a" end)

      assert {:ok, %{"path" => ^path}} = Template.match(template, "files://docs/#{path}/raw")
      assert Template.match(compiled("hex://{name}/{a}/{b}"), "hex://n/" <> path) == :error
    end
  end

  describe "an empty authority" do
    test "file:/// templates match URIs with an empty host" do
      template = compiled("file:///{+path}")
      assert Template.variables(template) == ["path"]

      assert Template.match(template, "file:///etc/hosts") == {:ok, %{"path" => "etc/hosts"}}
      assert Template.match(template, "FILE:///a%20b") == {:ok, %{"path" => "a b"}}

      for uri <- ["file://localhost/etc/hosts", "file:///", "file://", "file:/etc/hosts"] do
        assert Template.match(template, uri) == :error, uri
      end

      template = compiled("file:///{name}")
      assert Template.match(template, "file:///notes.txt") == {:ok, %{"name" => "notes.txt"}}
      assert Template.match(template, "file:///a/b") == :error
      assert Template.match(template, "file://host/notes.txt") == :error

      template = compiled("file:///srv/{+path}{?rev}")

      assert Template.match(template, "file:///srv/a/b?rev=2") ==
               {:ok, %{"path" => "a/b", "rev" => "2"}}

      assert Template.match(template, "file:///other/a") == :error
    end

    test "a template with a host does not match an empty host" do
      assert Template.match(compiled("file://{host}/{+path}"), "file:///a/b") == :error
      assert Template.match(compiled("file://localhost/{+path}"), "file:///a/b") == :error
    end
  end

  test "a URI that is not valid UTF-8 does not match" do
    template = compiled("files://{root}/{+path}")

    for uri <- [<<"files://docs/", 0xFF>>, <<"files://", 0xC3, "/a">>, <<0xFF>>] do
      assert Template.match(template, uri) == :error
    end
  end
end
