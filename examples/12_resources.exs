defmodule Examples.Resources.ToolboxGroups do
  @moduledoc false

  use MCP.Resource,
    uri: "toolbox://groups",
    name: "Elixir Toolbox groups",
    title: "Toolbox Groups",
    description: "Locally available package-discovery groups",
    mime_type: "application/json",
    annotations: %{"audience" => ["assistant"], "priority" => 0.7}

  @groups [%{"id" => "web", "title" => "Web"}, %{"id" => "data", "title" => "Data"}]

  @impl true
  def read(%{"uri" => uri}, _context) do
    {:ok, MCP.Result.resource_read(MCP.Resource.json(uri, @groups))}
  end
end

defmodule Examples.Resources.PackageInfo do
  @moduledoc false

  use MCP.Resource,
    uri_template: "hex://{name}/info",
    name: "Hex package information",
    description: "Metadata for a package in the local example catalog",
    mime_type: "application/json"

  @packages %{
    "jason" => %{"name" => "jason", "latest" => "1.4.4", "downloads" => 412_000_000},
    "ecto" => %{"name" => "ecto", "latest" => "3.13.2", "downloads" => 285_000_000}
  }

  @impl true
  def matches?(uri) do
    case URI.new(uri) do
      {:ok, %URI{scheme: "hex", host: package, path: "/info"}}
      when is_binary(package) and package != "" ->
        true

      _invalid ->
        false
    end
  end

  @impl true
  def read(%{"uri" => uri}, _context) do
    package = URI.parse(uri).host

    case Map.fetch(@packages, package) do
      {:ok, info} ->
        content = MCP.Resource.json(uri, info)

        {:ok,
         MCP.Result.resource_read(content,
           metadata: %{ttl_ms: 5_000, cache_scope: "private"}
         )}

      :error ->
        {:error, MCP.Error.invalid_params("Resource not found", %{"uri" => uri})}
    end
  end
end

defmodule Examples.Resources.Server do
  @moduledoc false

  use MCP.Server,
    name: "resources-example",
    version: "0.1.0",
    protocols: [MCP.Protocol.V2026_07_28],
    resources_cache: [ttl_ms: 60_000, scope: "public"]

  resource(Examples.Resources.PackageInfo)
  resource(Examples.Resources.ToolboxGroups)
end

defmodule Examples.Resources.Runner do
  @moduledoc false

  alias Examples.Resources.Server

  @protocol "2026-07-28"

  def run(mode) do
    runtime = Server.runtime()

    direct = dispatch(runtime, "list", "resources/list")
    templates = dispatch(runtime, "templates", "resources/templates/list")
    groups = dispatch(runtime, "groups", "resources/read", %{"uri" => "toolbox://groups"})
    package = dispatch(runtime, "package", "resources/read", %{"uri" => "hex://jason/info"})
    missing = dispatch(runtime, "missing", "resources/read", %{"uri" => "hex://missing/info"})

    ensure(
      get_in(direct, ["result", "resources", Access.at(0), "uri"]) == "toolbox://groups",
      "static resource was not listed"
    )

    ensure(
      get_in(templates, ["result", "resourceTemplates", Access.at(0), "uriTemplate"]) ==
        "hex://{name}/info",
      "resource template was not listed"
    )

    ensure(is_list(decode(groups)), "static JSON content was not readable")
    ensure(decode(package)["name"] == "jason", "templated resource routed incorrectly")
    ensure(get_in(package, ["result", "ttlMs"]) == 5_000, "read cache override was lost")
    ensure(get_in(package, ["result", "cacheScope"]) == "private", "cache scope was lost")
    ensure(get_in(missing, ["error", "code"]) == -32_602, "missing resource was not -32602")

    print_summary(mode)
  end

  defp dispatch(runtime, id, method, params \\ %{}) do
    {:ok, response} =
      MCP.Test.dispatch(runtime,
        id: id,
        protocol: @protocol,
        method: method,
        params: params
      )

    response
  end

  defp decode(response) do
    response
    |> get_in(["result", "contents", Access.at(0), "text"])
    |> JSON.decode!()
  end

  defp ensure(true, _message), do: :ok
  defp ensure(false, message), do: raise(message)

  defp print_summary(:check), do: IO.puts("12_resources: ok")

  defp print_summary(:walkthrough) do
    IO.puts("Listed and read one static resource and one explicit URI-template route.")
    IO.puts("The templated read retained private cache hints and missing data returned -32602.")
  end
end

case System.argv() do
  ["--check"] -> Examples.Resources.Runner.run(:check)
  [] -> Examples.Resources.Runner.run(:walkthrough)
  _arguments -> raise "usage: mix run examples/12_resources.exs [--check]"
end
