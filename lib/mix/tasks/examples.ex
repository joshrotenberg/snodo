defmodule Mix.Tasks.Examples do
  use Mix.Task

  @shortdoc "Runs every executable example in an isolated Elixir VM"

  @examples [
    {"examples/01_direct_tools.exs", "01_direct_tools: ok"},
    {"examples/02_structured_schema.exs", "02_structured_schema: ok"},
    {"examples/03_context_and_state.exs", "03_context_and_state: ok"},
    {"examples/04_stdio_concurrency.exs", "04_stdio_concurrency: ok"},
    {"examples/05_http_tools.exs", "05_http_tools: ok"},
    {"examples/06_custom_extension.exs", "06_custom_extension: ok"},
    {"examples/12_resources.exs", "12_resources: ok"},
    {"examples/13_prompts.exs", "13_prompts: ok"},
    {"examples/14_completions.exs", "14_completions: ok"},
    {"examples/15_pagination.exs", "15_pagination: ok"},
    {"examples/16_subscriptions.exs", "16_subscriptions: ok"},
    {"examples/18_subscription_hub.exs", "18_subscription_hub: ok"},
    {"examples/19_instrumentation.exs", "19_instrumentation: ok"},
    {"examples/20_mrtr_elicitation.exs", "20_mrtr_elicitation: ok"}
  ]

  @tasks_examples [
    "07_tasks_memory: ok",
    "08_tasks_durable: ok",
    "09_tasks_retry: ok",
    "17_tasks_subscriptions: ok"
  ]
  @sqlite_example "11_tasks_sqlite: ok"
  @integration_examples [
    {"plug", "example.plug", "21_plug_bandit: ok"},
    {"schema_jsv", "example.jsv", "22_full_schema_validation: ok"}
  ]
  @total_examples length(@examples) + length(@tasks_examples) + 1 + length(@integration_examples)

  @check_expression """
  System.argv(["--check"])
  example = System.fetch_env!("MCP_EX_EXAMPLE_FILE")

  {_loaded, diagnostics} =
    Code.with_diagnostics(fn -> Code.require_file(example) end)

  warnings = Enum.filter(diagnostics, &(&1.severity == :warning))

  if warnings != [] do
    raise "example emitted compiler warnings: " <> inspect(warnings)
  end
  """

  @moduledoc """
  Runs every public-API example in deterministic check mode.

      mix examples

  Each script receives `--check` in a fresh Mix/Elixir VM with compiler warnings
  promoted to errors. The task requires the exact one-line success output and
  stops at the first mismatch or non-zero exit.

  The current stdio subprocess example requires a POSIX host with `sh` and
  `mkfifo`; the gate reports that platform requirement explicitly.
  """

  @impl Mix.Task
  def run([]) do
    Mix.Task.run("compile", ["--warnings-as-errors"])
    validate_platform!()

    root = project_root()
    mix = System.find_executable("mix") || Mix.raise("mix executable was not found")
    build_path = Path.expand(Mix.Project.build_path(), root)

    Enum.each(@examples, &run_example(mix, build_path, root, &1))
    run_tasks_examples(mix, root)
    run_sqlite_example(mix, root)
    Enum.each(@integration_examples, &run_integration_example(mix, root, &1))
    Mix.shell().info("All #{@total_examples} examples passed")
  end

  def run(_args), do: Mix.raise("usage: mix examples")

  defp run_example(mix, build_path, root, {example, expected_output}) do
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
          {"MCP_EX_EXAMPLE_FILE", Path.join(root, example)},
          {"MIX_BUILD_PATH", build_path},
          {"MIX_ENV", Atom.to_string(Mix.env())}
        ],
        stderr_to_stdout: true
      )

    expected_line = expected_output <> "\n"

    case {status, output} do
      {0, ^expected_output} -> Mix.shell().info(expected_output)
      {0, ^expected_line} -> Mix.shell().info(expected_output)
      {0, other} -> Mix.raise("#{example} produced unexpected output:\n#{inspect(other)}")
      {failed, _output} -> Mix.raise("#{example} failed with status #{failed}:\n#{output}")
    end
  end

  defp run_tasks_examples(mix, root) do
    package = Path.join([root, "extensions", "tasks"])
    build_path = Path.join([package, "_build", Atom.to_string(Mix.env())])

    {output, status} =
      System.cmd(mix, ["examples"],
        cd: package,
        env: [
          {"MIX_BUILD_PATH", build_path},
          {"MIX_ENV", Atom.to_string(Mix.env())}
        ],
        stderr_to_stdout: true
      )

    if status == 0 and Enum.all?(@tasks_examples, &String.contains?(output, &1)) do
      Enum.each(@tasks_examples, fn example -> Mix.shell().info(example) end)
    else
      Mix.raise("Tasks examples failed with status #{status}:\n#{output}")
    end
  end

  defp run_sqlite_example(mix, root) do
    package = Path.join([root, "extensions", "tasks_sqlite"])
    build_path = Path.join([package, "_build", Atom.to_string(Mix.env())])

    {output, status} =
      System.cmd(mix, ["example.sqlite"],
        cd: package,
        env: [
          {"MIX_BUILD_PATH", build_path},
          {"MIX_ENV", Atom.to_string(Mix.env())}
        ],
        stderr_to_stdout: true
      )

    if status == 0 and String.contains?(output, @sqlite_example) do
      Mix.shell().info(@sqlite_example)
    else
      Mix.raise("SQLite example failed with status #{status}:\n#{output}")
    end
  end

  defp run_integration_example(mix, root, {name, task, expected}) do
    package = Path.join([root, "integrations", name])

    {output, status} =
      System.cmd(mix, [task],
        cd: package,
        env: [
          {"MIX_BUILD_PATH", Path.join([package, "_build", Atom.to_string(Mix.env())])},
          {"MIX_ENV", Atom.to_string(Mix.env())}
        ],
        stderr_to_stdout: true
      )

    if status == 0 and String.contains?(output, expected) do
      Mix.shell().info(expected)
    else
      Mix.raise("#{name} example failed with status #{status}:\n#{output}")
    end
  end

  defp validate_platform! do
    elixir? = not is_nil(System.find_executable("elixir"))
    sh? = not is_nil(System.find_executable("sh"))
    mkfifo? = not is_nil(System.find_executable("mkfifo"))

    unless match?({:unix, _name}, :os.type()) and elixir? and sh? and mkfifo? do
      Mix.raise("mix examples currently requires a POSIX host with elixir, sh, and mkfifo")
    end
  end

  defp project_root do
    Mix.Project.project_file()
    |> Path.expand()
    |> Path.dirname()
  end
end
