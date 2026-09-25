defmodule Mix.Tasks.Snodo.Example do
  use Mix.Task

  @shortdoc "Checks one example in an isolated VM using the active Mix project"

  @moduledoc """
  Runs one repository example in deterministic check mode in a fresh VM.

      mix snodo.example ../../examples/11_tasks_sqlite.exs

  The child uses the active project's directory, resolved build path, and Mix
  environment. This also preserves environments selected by `preferred_envs`,
  which do not necessarily appear in the inherited `MIX_ENV` variable.

  The script receives exactly `--check`; compiler warnings and a non-zero child
  exit fail the task. Optional packages can use this task from their aliases
  without loading the example's application processes into the quality runner.
  """

  @check_expression """
  System.argv(["--check"])
  example = System.fetch_env!("SNODO_EXAMPLE_FILE")

  {_loaded, diagnostics} =
    Code.with_diagnostics(fn -> Code.require_file(example) end)

  warnings = Enum.filter(diagnostics, &(&1.severity == :warning))

  if warnings != [] do
    raise "example emitted compiler warnings: " <> inspect(warnings)
  end
  """

  @impl Mix.Task
  def run([example]) do
    Mix.Task.reenable("snodo.example")
    root = Mix.Project.project_file() |> Path.expand() |> Path.dirname()
    example = Path.expand(example, root)

    unless File.regular?(example), do: Mix.raise("example file was not found: #{example}")

    Mix.Task.run("compile", ["--warnings-as-errors"])
    mix = System.find_executable("mix") || Mix.raise("mix executable was not found")

    {output, status} =
      System.cmd(
        mix,
        [
          "run",
          "--no-compile",
          "--no-deps-check",
          "--no-archives-check",
          "-e",
          @check_expression
        ],
        cd: root,
        env: [
          {"SNODO_EXAMPLE_FILE", example},
          {"MIX_BUILD_PATH", Path.expand(Mix.Project.build_path(), root)},
          {"MIX_ENV", Atom.to_string(Mix.env())}
        ],
        stderr_to_stdout: true
      )

    if status == 0 do
      Mix.shell().info(String.trim_trailing(output, "\n"))
    else
      Mix.raise("#{example} failed with status #{status}:\n#{output}")
    end
  end

  def run(_args), do: Mix.raise("usage: mix snodo.example PATH")
end
