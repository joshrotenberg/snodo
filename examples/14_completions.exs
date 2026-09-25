defmodule Examples.Completions.PackageSearch do
  @moduledoc false

  use Snodo.Prompt,
    name: "package_search",
    description: "Search for Hex packages within an optional category",
    arguments: [
      %{"name" => "category", "description" => "Package category"},
      %{"name" => "package", "description" => "Hex package name", "required" => true}
    ],
    completion_arguments: ["category", "package"]

  @packages %{
    "database" => ["ecto", "ecto_sql", "postgrex"],
    "http" => ["bandit", "finch", "plug", "req"],
    "json" => ["jason"]
  }

  @impl true
  def render(%{"package" => package}, _context) do
    {:ok,
     Snodo.Result.prompt_get(
       Snodo.Prompt.message(:user, Snodo.Prompt.text("Evaluate the Hex package #{package}."))
     )}
  end

  @impl true
  def complete(%Snodo.Completion{argument: "category", value: value}, _context) do
    values = @packages |> Map.keys() |> matching(value)
    {:ok, Snodo.Result.completion(values, total: length(values), has_more: false)}
  end

  def complete(
        %Snodo.Completion{
          argument: "package",
          value: value,
          arguments: arguments
        },
        _context
      ) do
    candidates =
      case Map.get(arguments, "category") do
        nil -> @packages |> Map.values() |> List.flatten()
        category -> Map.get(@packages, category, [])
      end

    values = matching(candidates, value)
    {:ok, Snodo.Result.completion(values, total: length(values), has_more: false)}
  end

  defp matching(values, prefix) do
    values
    |> Enum.filter(&String.starts_with?(&1, prefix))
    |> Enum.sort()
    |> Enum.take(100)
  end
end

defmodule Examples.Completions.PackageRelease do
  @moduledoc false

  use Snodo.Resource,
    uri_template: "hex://{package}/releases/{version}",
    name: "package_release",
    description: "Release information for one Hex package version",
    mime_type: "application/json",
    completion_arguments: ["package", "version"]

  @versions %{
    "ecto" => ["3.13.3", "3.13.2", "3.12.6"],
    "jason" => ["1.4.4", "1.4.3"],
    "plug" => ["1.18.1", "1.18.0"]
  }

  @impl true
  def matches?(uri) when is_binary(uri), do: String.starts_with?(uri, "hex://")

  @impl true
  def read(%{"uri" => uri}, _context) do
    {:ok, Snodo.Result.resource_read(Snodo.Resource.json(uri, %{"uri" => uri}))}
  end

  @impl true
  def complete(%Snodo.Completion{argument: "package", value: value}, _context) do
    values = @versions |> Map.keys() |> matching(value)
    {:ok, Snodo.Result.completion(values, total: length(values))}
  end

  def complete(
        %Snodo.Completion{
          argument: "version",
          value: value,
          arguments: %{"package" => package}
        },
        _context
      ) do
    values = @versions |> Map.get(package, []) |> matching(value)
    {:ok, Snodo.Result.completion(values, total: length(values), has_more: false)}
  end

  def complete(%Snodo.Completion{argument: "version"}, _context) do
    {:ok, Snodo.Result.completion([])}
  end

  defp matching(values, prefix) do
    Enum.filter(values, &String.starts_with?(&1, prefix))
  end
end

defmodule Examples.Completions.Server do
  @moduledoc false

  use Snodo.Server,
    name: "hexpm-completions-example",
    version: "0.1.0",
    protocols: [Snodo.Protocol.V2026_07_28]

  prompt(Examples.Completions.PackageSearch)
  resource(Examples.Completions.PackageRelease)
end

defmodule Examples.Completions.Runner do
  @moduledoc false

  alias Examples.Completions.Server

  @protocol "2026-07-28"

  def run(mode) do
    runtime = Server.runtime()

    discover = dispatch(runtime, "discover", "server/discover")

    packages =
      dispatch(runtime, "packages", "completion/complete", %{
        "ref" => %{"type" => "ref/prompt", "name" => "package_search"},
        "argument" => %{"name" => "package", "value" => "ec"},
        "context" => %{"arguments" => %{"category" => "database"}}
      })

    versions =
      dispatch(runtime, "versions", "completion/complete", %{
        "ref" => %{
          "type" => "ref/resource",
          "uri" => "hex://{package}/releases/{version}"
        },
        "argument" => %{"name" => "version", "value" => "3.13"},
        "context" => %{"arguments" => %{"package" => "ecto"}}
      })

    unsupported =
      dispatch(runtime, "unsupported", "completion/complete", %{
        "ref" => %{"type" => "ref/prompt", "name" => "package_search"},
        "argument" => %{"name" => "unknown", "value" => ""}
      })

    ensure(
      get_in(discover, ["result", "capabilities", "completions"]) == %{},
      "completion capability was not advertised"
    )

    ensure(
      get_in(packages, ["result", "completion", "values"]) == ["ecto", "ecto_sql"],
      "prompt completion lost its category context"
    )

    ensure(
      get_in(versions, ["result", "completion", "values"]) == ["3.13.3", "3.13.2"],
      "resource-template completion lost its package context"
    )

    ensure(
      get_in(unsupported, ["error", "code"]) == -32_602,
      "an undeclared completion argument was accepted"
    )

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

  defp print_summary(:check), do: IO.puts("14_completions: ok")

  defp print_summary(:walkthrough) do
    IO.puts("Advertised completion only because registered definitions opt in.")
    IO.puts("Completed prompt and resource-template arguments with contextual filtering.")
  end
end

case System.argv() do
  ["--check"] -> Examples.Completions.Runner.run(:check)
  [] -> Examples.Completions.Runner.run(:walkthrough)
  _arguments -> raise "usage: mix run examples/14_completions.exs [--check]"
end
