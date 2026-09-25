defmodule Examples.Pagination.AlphaTool do
  @moduledoc false
  use Snodo.Tool, name: "alpha"

  @impl true
  def call(_arguments, _context), do: {:ok, Snodo.Result.text("alpha")}
end

defmodule Examples.Pagination.ZuluTool do
  @moduledoc false
  use Snodo.Tool, name: "zulu"

  @impl true
  def call(_arguments, _context), do: {:ok, Snodo.Result.text("zulu")}
end

defmodule Examples.Pagination.AuditPrompt do
  @moduledoc false
  use Snodo.Prompt, name: "audit"

  @impl true
  def render(_arguments, _context) do
    {:ok, Snodo.Result.prompt_get(Snodo.Prompt.message(:user, Snodo.Prompt.text("Audit it.")))}
  end
end

defmodule Examples.Pagination.ReviewPrompt do
  @moduledoc false
  use Snodo.Prompt, name: "review"

  @impl true
  def render(_arguments, _context) do
    {:ok, Snodo.Result.prompt_get(Snodo.Prompt.message(:user, Snodo.Prompt.text("Review it.")))}
  end
end

defmodule Examples.Pagination.GuideResource do
  @moduledoc false
  use Snodo.Resource, uri: "demo://guide", name: "guide"

  @impl true
  def read(%{"uri" => uri}, _context) do
    {:ok, Snodo.Result.resource_read(Snodo.Resource.text(uri, "guide"))}
  end
end

defmodule Examples.Pagination.StatusResource do
  @moduledoc false
  use Snodo.Resource, uri: "demo://status", name: "status"

  @impl true
  def read(%{"uri" => uri}, _context) do
    {:ok, Snodo.Result.resource_read(Snodo.Resource.text(uri, "ready"))}
  end
end

defmodule Examples.Pagination.PackageTemplate do
  @moduledoc false
  use Snodo.Resource, uri_template: "hex://{name}", name: "package"

  @impl true
  def matches?(uri), do: String.starts_with?(uri, "hex://")

  @impl true
  def read(%{"uri" => uri}, _context) do
    {:ok, Snodo.Result.resource_read(Snodo.Resource.text(uri, "package"))}
  end
end

defmodule Examples.Pagination.ReleaseTemplate do
  @moduledoc false
  use Snodo.Resource, uri_template: "hex://{name}/releases/{version}", name: "release"

  @impl true
  def matches?(uri), do: String.contains?(uri, "/releases/")

  @impl true
  def read(%{"uri" => uri}, _context) do
    {:ok, Snodo.Result.resource_read(Snodo.Resource.text(uri, "release"))}
  end
end

defmodule Examples.Pagination.Server do
  @moduledoc false

  use Snodo.Server,
    name: "pagination-example",
    version: "1.0.0",
    protocols: [Snodo.Protocol.V2026_07_28],
    pagination: [page_size: 1],
    tools_cache: [ttl_ms: 10, scope: "public"],
    prompts_cache: [ttl_ms: 20, scope: "public"],
    resources_cache: [ttl_ms: 30, scope: "private"]

  tool(Examples.Pagination.ZuluTool)
  tool(Examples.Pagination.AlphaTool)
  prompt(Examples.Pagination.ReviewPrompt)
  prompt(Examples.Pagination.AuditPrompt)
  resource(Examples.Pagination.StatusResource)
  resource(Examples.Pagination.ReleaseTemplate)
  resource(Examples.Pagination.GuideResource)
  resource(Examples.Pagination.PackageTemplate)
end

defmodule Examples.Pagination.Runner do
  @moduledoc false

  @protocol "2026-07-28"

  def run(mode) do
    runtime = Examples.Pagination.Server.runtime()

    cases = [
      {"tools/list", "tools", "name", ["alpha", "zulu"], 10, "public"},
      {"prompts/list", "prompts", "name", ["audit", "review"], 20, "public"},
      {"resources/list", "resources", "uri", ["demo://guide", "demo://status"], 30, "private"},
      {"resources/templates/list", "resourceTemplates", "uriTemplate",
       ["hex://{name}", "hex://{name}/releases/{version}"], 30, "private"}
    ]

    Enum.each(cases, fn {method, field, key, expected, ttl_ms, cache_scope} ->
      {values, pages} = collect(runtime, method, field, key)

      ensure(values == expected, "#{method} lost stable ordering across pages")
      ensure(length(pages) == 2, "#{method} did not use the shared page size")
      ensure(is_binary(hd(pages)["nextCursor"]), "#{method} omitted its next cursor")
      ensure(not Map.has_key?(List.last(pages), "nextCursor"), "#{method} paged past the end")
      ensure(Enum.all?(pages, &(&1["ttlMs"] == ttl_ms)), "#{method} lost its TTL hint")

      ensure(
        Enum.all?(pages, &(&1["cacheScope"] == cache_scope)),
        "#{method} lost its cache scope"
      )
    end)

    tool_cursor = dispatch(runtime, "tools/list")["result"]["nextCursor"]
    cross_method = dispatch(runtime, "prompts/list", %{"cursor" => tool_cursor})

    ensure(
      get_in(cross_method, ["error", "message"]) == "Invalid pagination cursor",
      "a tool cursor crossed into prompts/list"
    )

    print_summary(mode)
  end

  defp collect(runtime, method, field, key) do
    first = dispatch(runtime, method)["result"]
    second = dispatch(runtime, method, %{"cursor" => first["nextCursor"]})["result"]
    values = Enum.map(first[field] ++ second[field], &Map.fetch!(&1, key))
    {values, [first, second]}
  end

  defp dispatch(runtime, method, params \\ %{}) do
    {:ok, response} =
      Snodo.Test.dispatch(runtime,
        protocol: @protocol,
        method: method,
        params: params
      )

    response
  end

  defp ensure(true, _message), do: :ok
  defp ensure(false, message), do: raise(message)

  defp print_summary(:check), do: IO.puts("15_pagination: ok")

  defp print_summary(:walkthrough) do
    IO.puts("Traversed tools, prompts, resources, and templates with one cursor policy.")
    IO.puts("Preserved ordering and cache hints; rejected a cross-method cursor.")
  end
end

case System.argv() do
  ["--check"] -> Examples.Pagination.Runner.run(:check)
  [] -> Examples.Pagination.Runner.run(:walkthrough)
  _arguments -> raise "usage: mix run examples/15_pagination.exs [--check]"
end
