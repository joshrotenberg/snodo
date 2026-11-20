defmodule Mix.Tasks.Tasks.Stress do
  use Mix.Task

  alias Snodo.Extensions.Tasks.Stress

  @shortdoc "Runs deterministic Tasks contention and soak workloads"

  @moduledoc """
  Runs deterministic correctness workloads against the Tasks memory store.

      mix tasks.stress
      mix tasks.stress --tasks 100 --writers 16 --rounds 10
      mix tasks.stress --json

  Timings are observations only. Pass/fail comes from exact CAS, lease-fencing,
  terminal-state, instrumentation-balance, and runner-drain invariants. The
  PostgreSQL and SQLite packages run the same harness against their stores
  with `mix tasks.postgres.stress` and `mix tasks.sqlite.stress`.
  """

  @impl Mix.Task
  def run(args) do
    case Stress.parse_args(args) do
      {:ok, opts, [], json} ->
        opts |> Stress.run() |> print_report!(json)

      {:error, :invalid_arguments} ->
        Mix.raise(
          "usage: mix tasks.stress [--tasks N] [--writers N] [--rounds N] " <>
            "[--timeout-ms N] [--json]"
        )
    end
  end

  defp print_report!(report, json) do
    if json do
      Mix.shell().info(JSON.encode!(report))
    else
      shell = Mix.shell()
      Enum.each(Stress.format_report(report), &shell.info/1)
    end

    unless report["ok"], do: Mix.raise("Tasks stress invariants failed")
  end
end
