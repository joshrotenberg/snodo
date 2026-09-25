defmodule Examples.Prompts.AnalyzePackage do
  @moduledoc false

  use Snodo.Prompt,
    name: "analyze_package",
    title: "Analyze a Hex package",
    description: "Analyze package quality, maintenance, popularity, and alternatives",
    arguments: [
      %{
        "name" => "name",
        "title" => "Package",
        "description" => "Package name on hex.pm",
        "required" => true
      }
    ]

  @impl true
  def render(%{"name" => name}, _context) do
    text = """
    Analyze the hex.pm package "#{name}". Use package information, health,
    downloads, dependencies, alternatives, and vulnerability tools. Report its
    health, quality, popularity, security, alternatives, and a recommendation.
    """

    {:ok, Snodo.Result.prompt_get(Snodo.Prompt.message(:user, Snodo.Prompt.text(text)))}
  end
end

defmodule Examples.Prompts.ComparePackages do
  @moduledoc false

  use Snodo.Prompt,
    name: "compare_packages",
    description: "Compare multiple hex.pm packages side by side",
    arguments: [
      %{
        "name" => "names",
        "description" => "Comma-separated package names (2-5)",
        "required" => true
      }
    ]

  @impl true
  def render(%{"names" => names}, _context) do
    text =
      "Compare these hex.pm packages: #{names}. Cover stats, strengths, weaknesses, use cases, and a recommendation."

    {:ok, Snodo.Result.prompt_get(Snodo.Prompt.message(:user, Snodo.Prompt.text(text)))}
  end
end

defmodule Examples.Prompts.EvaluateDependencies do
  @moduledoc false

  use Snodo.Prompt,
    name: "evaluate_dependencies",
    description: "Evaluate hex.pm dependencies for health and security",
    arguments: [
      %{
        "name" => "deps",
        "description" => "Comma-separated package names",
        "required" => true
      }
    ]

  @impl true
  def render(%{"deps" => deps}, _context) do
    text =
      "Evaluate these dependencies: #{deps}. Assess maintenance, security, bus factor, staleness, and recommended actions."

    {:ok, Snodo.Result.prompt_get(Snodo.Prompt.message(:user, Snodo.Prompt.text(text)))}
  end
end

defmodule Examples.Prompts.MigrationGuide do
  @moduledoc false

  use Snodo.Prompt,
    name: "migration_guide",
    description: "Guide a migration from one hex.pm package to another",
    arguments: [
      %{"name" => "from", "description" => "Package to migrate from", "required" => true},
      %{"name" => "to", "description" => "Package to migrate to", "required" => true}
    ]

  @impl true
  def render(%{"from" => from, "to" => to}, _context) do
    messages = [
      Snodo.Prompt.message(
        :user,
        Snodo.Prompt.text(
          "Plan a migration from #{from} to #{to}. Map APIs, breaking changes, ordered steps, and tests."
        )
      ),
      Snodo.Prompt.message(
        :assistant,
        Snodo.Prompt.text(
          "I will compare both packages and build an evidence-backed migration plan."
        )
      )
    ]

    {:ok, Snodo.Result.prompt_get(messages, description: "Migration from #{from} to #{to}")}
  end
end

defmodule Examples.Prompts.RecommendPackages do
  @moduledoc false

  use Snodo.Prompt,
    name: "recommend_packages",
    description: "Find and evaluate packages for a use case",
    arguments: [
      %{
        "name" => "use_case",
        "description" => "What you need a package for",
        "required" => true
      }
    ]

  @impl true
  def render(%{"use_case" => use_case}, _context) do
    text =
      "Find hex.pm packages for #{use_case}. Compare the top candidates and recommend the best fit with alternatives."

    {:ok, Snodo.Result.prompt_get(Snodo.Prompt.message(:user, Snodo.Prompt.text(text)))}
  end
end

defmodule Examples.Prompts.Server do
  @moduledoc false

  use Snodo.Server,
    name: "hexpm-prompts-example",
    version: "0.1.0",
    protocols: [Snodo.Protocol.V2026_07_28],
    prompts_cache: [ttl_ms: 60_000, scope: "public"]

  prompt(Examples.Prompts.AnalyzePackage)
  prompt(Examples.Prompts.ComparePackages)
  prompt(Examples.Prompts.EvaluateDependencies)
  prompt(Examples.Prompts.MigrationGuide)
  prompt(Examples.Prompts.RecommendPackages)
end

defmodule Examples.Prompts.Runner do
  @moduledoc false

  alias Examples.Prompts.Server

  @protocol "2026-07-28"

  def run(mode) do
    runtime = Server.runtime()
    listed = dispatch(runtime, "list", "prompts/list")

    migration =
      dispatch(runtime, "migration", "prompts/get", %{
        "name" => "migration_guide",
        "arguments" => %{"from" => "httpoison", "to" => "req"}
      })

    missing =
      dispatch(runtime, "missing", "prompts/get", %{
        "name" => "analyze_package"
      })

    ensure(
      listed |> get_in(["result", "prompts"]) |> Enum.map(& &1["name"]) == [
        "analyze_package",
        "compare_packages",
        "evaluate_dependencies",
        "migration_guide",
        "recommend_packages"
      ],
      "target-shaped prompt definitions were not listed deterministically"
    )

    ensure(get_in(listed, ["result", "ttlMs"]) == 60_000, "prompt list cache TTL was lost")
    ensure(get_in(listed, ["result", "cacheScope"]) == "public", "cache scope was lost")

    ensure(
      get_in(migration, ["result", "description"]) == "Migration from httpoison to req",
      "prompt arguments were not rendered"
    )

    ensure(
      migration |> get_in(["result", "messages"]) |> Enum.map(& &1["role"]) == [
        "user",
        "assistant"
      ],
      "multi-turn prompt messages were not preserved"
    )

    ensure(get_in(missing, ["error", "code"]) == -32_602, "required arguments did not fail")
    ensure(get_in(missing, ["error", "data", "missing"]) == ["name"], "missing key was lost")

    print_summary(mode)
  end

  defp dispatch(runtime, id, method, params \\ %{}) do
    {:ok, response} =
      Snodo.Test.dispatch(runtime,
        id: id,
        protocol: @protocol,
        method: method,
        params: params
      )

    response
  end

  defp ensure(true, _message), do: :ok
  defp ensure(false, message), do: raise(message)

  defp print_summary(:check), do: IO.puts("13_prompts: ok")

  defp print_summary(:walkthrough) do
    IO.puts("Listed five hexpm-mcp-shaped prompts with public cache hints.")
    IO.puts("Rendered a multi-turn migration guide and rejected a missing required argument.")
  end
end

case System.argv() do
  ["--check"] -> Examples.Prompts.Runner.run(:check)
  [] -> Examples.Prompts.Runner.run(:walkthrough)
  _arguments -> raise "usage: mix run examples/13_prompts.exs [--check]"
end
