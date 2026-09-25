defmodule Mix.Tasks.Tasks.Stress do
  use Mix.Task

  alias Snodo.Extensions.Tasks.Stress

  @shortdoc "Runs deterministic Tasks contention and soak workloads"

  @switches [
    tasks: :integer,
    writers: :integer,
    rounds: :integer,
    timeout_ms: :integer,
    json: :boolean
  ]

  @moduledoc """
  Runs deterministic correctness workloads against the Tasks memory adapter.

      mix tasks.stress
      mix tasks.stress --tasks 100 --writers 16 --rounds 10
      mix tasks.stress --json

  Timings are observations only. Pass/fail comes from exact CAS, terminal-state,
  instrumentation-balance, and runner-drain invariants.
  """

  @impl Mix.Task
  def run(args) do
    {opts, positional, invalid} = OptionParser.parse(args, strict: @switches)

    if positional != [] or invalid != [] do
      Mix.raise(
        "usage: mix tasks.stress [--tasks N] [--writers N] [--rounds N] " <>
          "[--timeout-ms N] [--json]"
      )
    end

    report = opts |> Keyword.drop([:json]) |> Stress.run()

    if Keyword.get(opts, :json, false) do
      Mix.shell().info(JSON.encode!(report))
    else
      print_report(report)
    end

    unless report["ok"], do: Mix.raise("Tasks stress invariants failed")
  end

  defp print_report(report) do
    config = report["config"]
    cas = report["scenarios"]["casContention"]
    runner = report["scenarios"]["runnerSoak"]

    Mix.shell().info(
      "Tasks stress: #{config["tasks"]} tasks, #{config["writersPerTask"]} writers, " <>
        "#{config["rounds"]} runner rounds"
    )

    Mix.shell().info(
      "CAS: #{cas["applied"]} applied, #{cas["conflicts"]} conflicts, " <>
        "#{cas["committedEvents"]} committed events in #{cas["durationUs"]}µs"
    )

    Mix.shell().info(
      "Runner: #{runner["completed"]}/#{runner["expectedJobs"]} completed, " <>
        "peak #{runner["peakJobs"]}, final #{runner["finalJobs"]} jobs in " <>
        "#{runner["durationUs"]}µs"
    )

    Mix.shell().info("Invariants: #{if(report["ok"], do: "passed", else: "failed")}")
  end
end
