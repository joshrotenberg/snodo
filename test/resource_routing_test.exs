defmodule Snodo.ResourceRoutingTest do
  @moduledoc """
  Generated template matchers, and the variables they hand to `read/2`.
  """

  use ExUnit.Case, async: true

  alias Snodo.Test, as: MCPTest
  alias SnodoTest.TestFixtures

  defmodule PackageInfo do
    @moduledoc false

    use Snodo.Resource,
      uri_template: "hex://{name}/info",
      name: "package_info",
      mime_type: "application/json"

    # No matches?/1: the template is inside the supported subset, so one is
    # generated and its bound variables arrive here.
    @impl true
    def read(%{"uri" => uri, "name" => name}, _context) do
      {:ok, Snodo.Result.resource_read(Snodo.Resource.json(uri, %{"name" => name}))}
    end
  end

  defmodule CategoryProjects do
    @moduledoc false

    use Snodo.Resource,
      uri_template: "toolbox://{group}/{category}",
      name: "toolbox_category",
      mime_type: "application/json"

    @impl true
    def read(%{"uri" => uri, "group" => group, "category" => category}, _context) do
      content = Snodo.Resource.json(uri, %{"group" => group, "category" => category})
      {:ok, Snodo.Result.resource_read(content)}
    end
  end

  defmodule Groups do
    @moduledoc false

    use Snodo.Resource, uri: "toolbox://groups", name: "toolbox_groups"

    @impl true
    def read(%{"uri" => uri}, _context) do
      {:ok, Snodo.Result.resource_read(Snodo.Resource.json(uri, %{"groups" => []}))}
    end
  end

  defmodule Custom do
    @moduledoc false

    # Reserved expansion in the authority is outside the supported shapes, so
    # no matcher is generated and the module supplies its own. A boolean
    # answer still routes.
    use Snodo.Resource, uri_template: "hex://{+path}/raw", name: "raw"

    @impl true
    def matches?(uri), do: String.starts_with?(uri, "hex://") and String.ends_with?(uri, "/raw")

    @impl true
    def read(%{"uri" => uri}, _context) do
      {:ok, Snodo.Result.resource_read(Snodo.Resource.text(uri, "raw", mime_type: "text/plain"))}
    end
  end

  defmodule PackageFile do
    @moduledoc false

    use Snodo.Resource.Simple,
      uri_template: "hex://{name}/files/{+path}{?rev}",
      name: "package_file",
      completion_arguments: ["name", "rev"]

    @impl true
    def read(params, _context), do: {:ok, Map.drop(params, ["uri", "_meta"])}

    @impl true
    def complete(%Snodo.Completion{argument: "rev", value: value}, _context) do
      values = Enum.filter(["1", "2", "10"], &String.starts_with?(&1, value))
      {:ok, Snodo.Result.completion(values, total: length(values))}
    end

    def complete(%Snodo.Completion{argument: "name"}, _context),
      do: {:ok, Snodo.Result.completion(["jason"])}
  end

  defmodule PackageDocs do
    @moduledoc false

    use Snodo.Resource.Simple, uri_template: "hex://{name}/docs{/page*}", name: "package_docs"

    @impl true
    def read(params, _context), do: {:ok, Map.drop(params, ["uri", "_meta"])}
  end

  defp read(uri, resources) do
    runtime = TestFixtures.runtime(resources: resources)

    {:ok, response} =
      MCPTest.dispatch(runtime,
        protocol: "2026-07-28",
        method: "resources/read",
        params: %{"uri" => uri}
      )

    response
  end

  defp contents(uri, resources) do
    read(uri, resources)["result"]["contents"] |> hd() |> Map.fetch!("text") |> JSON.decode!()
  end

  describe "generated matchers" do
    test "a template in the subset needs no matches?/1" do
      assert PackageInfo.matches?("hex://jason/info") == {:ok, %{"name" => "jason"}}
      assert PackageInfo.matches?("hex://jason/readme") == false
    end

    test "a template outside the subset keeps the module's own matcher" do
      assert Custom.matches?("hex://anything/raw") == true
      assert Custom.matches?("hex://anything/info") == false
    end

    test "an exact resource matches only itself" do
      assert Groups.matches?("toolbox://groups") == true
      assert Groups.matches?("toolbox://web/frameworks") == false
    end
  end

  describe "bound variables reach read/2" do
    test "one variable" do
      assert contents("hex://jason/info", [PackageInfo]) == %{"name" => "jason"}
    end

    test "several variables" do
      assert contents("toolbox://web/frameworks", [CategoryProjects]) ==
               %{"group" => "web", "category" => "frameworks"}
    end

    test "the request uri is still present alongside them" do
      result = read("hex://jason/info", [PackageInfo])["result"]

      assert hd(result["contents"])["uri"] == "hex://jason/info"
    end

    test "a boolean matcher binds nothing and read/2 still gets the uri" do
      result = read("hex://a/b/raw", [Custom])["result"]

      assert hd(result["contents"])["text"] == "raw"
    end
  end

  describe "RFC 6570 operators" do
    test "reserved and query expansion bind through the generated matcher" do
      assert contents("hex://jason/files/lib/jason.ex?rev=2", [PackageFile]) ==
               %{"name" => "jason", "path" => "lib/jason.ex", "rev" => "2"}

      assert contents("hex://jason/files/mix.exs", [PackageFile]) ==
               %{"name" => "jason", "path" => "mix.exs"}
    end

    test "exploded path segments bind through the generated matcher" do
      assert contents("hex://jason/docs", [PackageDocs]) == %{"name" => "jason"}

      assert contents("hex://jason/docs/guides/intro", [PackageDocs]) ==
               %{"name" => "jason", "page" => "guides/intro"}
    end

    test "URIs outside the template are not found" do
      for uri <- [
            "hex://jason/files",
            "hex://jason/files/a?other=1",
            "hex://jason/files/a?rev=1&rev=2",
            "hex://jason/docs/"
          ] do
        error = read(uri, [PackageFile, PackageDocs])["error"]

        assert error["code"] == -32_602, uri
        assert error["message"] == "Resource not found"
      end
    end

    test "completion reaches query variables of a template in the new shapes" do
      runtime = TestFixtures.runtime(resources: [PackageFile])

      {:ok, response} =
        MCPTest.dispatch(runtime,
          protocol: "2026-07-28",
          method: "completion/complete",
          params: %{
            "ref" => %{"type" => "ref/resource", "uri" => "hex://{name}/files/{+path}{?rev}"},
            "argument" => %{"name" => "rev", "value" => "1"},
            "context" => %{"arguments" => %{"name" => "jason", "path" => "mix.exs"}}
          }
        )

      assert response["result"]["completion"]["values"] == ["1", "10"]
    end
  end

  describe "overlapping templates" do
    defmodule AnyPath do
      @moduledoc false
      use Snodo.Resource.Simple, uri_template: "x://h/{+p}", name: "any_path"

      @impl true
      def read(_params, _context), do: {:ok, "any"}
    end

    defmodule DocsPage do
      @moduledoc false
      use Snodo.Resource.Simple, uri_template: "x://h/docs{/page*}", name: "docs_page"

      @impl true
      def read(_params, _context), do: {:ok, "docs"}
    end

    test "register without error, and a URI both match fails to read" do
      error = read("x://h/docs/intro", [AnyPath, DocsPage])["error"]

      assert error["code"] == -32_603
      assert error["message"] == "Multiple resource routes matched the requested URI"

      assert hd(read("x://h/other/intro", [AnyPath, DocsPage])["result"]["contents"])["text"] ==
               "any"
    end
  end

  describe "unsupported templates" do
    test "are a compile error naming the shape when the module has no matches?/1" do
      source = """
      defmodule SnodoTest.UnsupportedTemplate#{System.unique_integer([:positive])} do
        use Snodo.Resource, uri_template: "hex://{name}/{#section}", name: "unsupported"

        @impl true
        def read(_params, _context), do: {:error, :unreachable}
      end
      """

      error = assert_raise CompileError, fn -> Code.compile_string(source) end

      assert Exception.message(error) =~ ~s(resource template "hex://{name}/{#section}")
      assert Exception.message(error) =~ "fragment expansion ({#var})"
      assert Exception.message(error) =~ "Implement matches?/1"
    end

    test "a module's own matches?/1 without @impl compiles without warnings" do
      source = """
      defmodule SnodoTest.UnsupportedTemplateNoImpl#{System.unique_integer([:positive])} do
        use Snodo.Resource, uri_template: "hex://{name}/{#section}", name: "no_impl"

        def matches?(uri), do: String.starts_with?(uri, "hex://")

        @impl true
        def read(_params, _context), do: {:error, :unreachable}
      end
      """

      {result, diagnostics} = Code.with_diagnostics(fn -> Code.compile_string(source) end)

      assert [{module, _binary}] = result
      assert diagnostics == []
      assert module.matches?("hex://jason/x") == true
    end

    test "compile when the module implements matches?/1" do
      source = """
      defmodule SnodoTest.UnsupportedTemplateWithMatcher#{System.unique_integer([:positive])} do
        use Snodo.Resource.Simple, uri_template: "hex://{name}/{#section}", name: "custom"

        @impl true
        def matches?(uri), do: String.starts_with?(uri, "hex://")

        @impl true
        def read(_params, _context), do: {:ok, "custom"}
      end
      """

      assert [{module, _binary}] = Code.compile_string(source)
      assert module.matches?("hex://jason/x") == true
    end
  end

  describe "routing between overlapping registrations" do
    test "an exact resource and a two-segment template do not collide" do
      assert contents("toolbox://web/frameworks", [Groups, CategoryProjects]) ==
               %{"group" => "web", "category" => "frameworks"}

      assert contents("toolbox://groups", [Groups, CategoryProjects]) == %{"groups" => []}
    end

    test "an unmatched uri is a parameter error" do
      error = read("hex://jason/unknown", [PackageInfo])["error"]

      assert error["code"] == -32_602
      assert error["message"] == "Resource not found"
    end

    test "malformed or extra separators never route to the resource handler" do
      for uri <- ["hex://jason//info", "hex://jason/info/", "hex://bad%GG/info"] do
        error = read(uri, [PackageInfo])["error"]

        assert error["code"] == -32_602
        assert error["message"] == "Resource not found"
      end
    end
  end

  describe "matcher contract" do
    test "a matcher binding a reserved request key is rejected at registration" do
      defmodule Shadowing do
        @moduledoc false

        use Snodo.Resource, uri_template: "hex://{name}/shadow", name: "shadow"

        @impl true
        def matches?(_uri), do: {:ok, %{"uri" => "hijacked"}}

        @impl true
        def read(_params, _context), do: {:error, :unreachable}
      end

      assert_raise ArgumentError, ~r/reserved request keys: uri/, fn ->
        Snodo.Router.register_resource(Snodo.Router.new(), Shadowing)
      end
    end

    test "a matcher binding non-string values is rejected at registration" do
      defmodule NonString do
        @moduledoc false

        use Snodo.Resource, uri_template: "hex://{name}/bad", name: "bad"

        @impl true
        def matches?(_uri), do: {:ok, %{"name" => :atom}}

        @impl true
        def read(_params, _context), do: {:error, :unreachable}
      end

      assert_raise ArgumentError, ~r/must bind string variables to strings/, fn ->
        Snodo.Router.register_resource(Snodo.Router.new(), NonString)
      end
    end
  end
end
