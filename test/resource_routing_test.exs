defmodule MCP.ResourceRoutingTest do
  @moduledoc """
  Generated template matchers, and the variables they hand to `read/2`.
  """

  use ExUnit.Case, async: true

  alias MCP.Test, as: MCPTest
  alias MCPEx.TestFixtures

  defmodule PackageInfo do
    @moduledoc false

    use MCP.Resource,
      uri_template: "hex://{name}/info",
      name: "package_info",
      mime_type: "application/json"

    # No matches?/1: the template is inside the supported subset, so one is
    # generated and its bound variables arrive here.
    @impl true
    def read(%{"uri" => uri, "name" => name}, _context) do
      {:ok, MCP.Result.resource_read(MCP.Resource.json(uri, %{"name" => name}))}
    end
  end

  defmodule CategoryProjects do
    @moduledoc false

    use MCP.Resource,
      uri_template: "toolbox://{group}/{category}",
      name: "toolbox_category",
      mime_type: "application/json"

    @impl true
    def read(%{"uri" => uri, "group" => group, "category" => category}, _context) do
      content = MCP.Resource.json(uri, %{"group" => group, "category" => category})
      {:ok, MCP.Result.resource_read(content)}
    end
  end

  defmodule Groups do
    @moduledoc false

    use MCP.Resource, uri: "toolbox://groups", name: "toolbox_groups"

    @impl true
    def read(%{"uri" => uri}, _context) do
      {:ok, MCP.Result.resource_read(MCP.Resource.json(uri, %{"groups" => []}))}
    end
  end

  defmodule Custom do
    @moduledoc false

    # An operator puts this outside the subset, so no matcher is generated and
    # the module supplies its own. A boolean answer still routes.
    use MCP.Resource, uri_template: "hex://{+path}/raw", name: "raw"

    @impl true
    def matches?(uri), do: String.starts_with?(uri, "hex://") and String.ends_with?(uri, "/raw")

    @impl true
    def read(%{"uri" => uri}, _context) do
      {:ok, MCP.Result.resource_read(MCP.Resource.text(uri, "raw", mime_type: "text/plain"))}
    end
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

        use MCP.Resource, uri_template: "hex://{name}/shadow", name: "shadow"

        @impl true
        def matches?(_uri), do: {:ok, %{"uri" => "hijacked"}}

        @impl true
        def read(_params, _context), do: {:error, :unreachable}
      end

      assert_raise ArgumentError, ~r/reserved request keys: uri/, fn ->
        MCP.Router.register_resource(MCP.Router.new(), Shadowing)
      end
    end

    test "a matcher binding non-string values is rejected at registration" do
      defmodule NonString do
        @moduledoc false

        use MCP.Resource, uri_template: "hex://{name}/bad", name: "bad"

        @impl true
        def matches?(_uri), do: {:ok, %{"name" => :atom}}

        @impl true
        def read(_params, _context), do: {:error, :unreachable}
      end

      assert_raise ArgumentError, ~r/must bind string variables to strings/, fn ->
        MCP.Router.register_resource(MCP.Router.new(), NonString)
      end
    end
  end
end
