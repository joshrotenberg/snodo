defmodule Mix.Tasks.Tasks.Postgres.Live do
  use Mix.Task

  @shortdoc "Runs the PostgreSQL Tasks adapter's live database contract"

  @contract_ids [
    "tasks-postgres-live-concurrency",
    "tasks-postgres-live-leases",
    "tasks-postgres-live-ledger",
    "tasks-postgres-live-migration",
    "tasks-postgres-live-recovery",
    "tasks-postgres-live-scope",
    "tasks-postgres-live-time"
  ]
  @contract_test_module Snodo.Extensions.Tasks.Postgres.LiveTest
  @contract_test_path "test/postgres_live_test.exs"

  @moduledoc """
  Runs transaction and locking evidence against a real PostgreSQL database.

      SNODO_TASKS_DATABASE_URL=ecto://postgres:postgres@127.0.0.1:55432/snodo_tasks \
        mix tasks.postgres.live

  The suite starts an ordinary application-owned Ecto Repo pool and creates a
  unique PostgreSQL schema. It deliberately does not use SQL Sandbox.
  """

  @impl Mix.Task
  def run([]) do
    require_database_url!()

    unless File.regular?(@contract_test_path) do
      Mix.raise("PostgreSQL live contract test is missing: #{@contract_test_path}")
    end

    Mix.Task.run("test", [
      @contract_test_path,
      "--include",
      "postgres_live",
      "--raise",
      "--warnings-as-errors",
      "--seed",
      "0"
    ])

    verify_contract_ids!()

    Mix.shell().info("PostgreSQL live contract: #{length(@contract_ids)} evidence groups passed")
  end

  def run(_args), do: Mix.raise("usage: mix tasks.postgres.live")

  defp require_database_url! do
    case System.get_env("SNODO_TASKS_DATABASE_URL") do
      url when is_binary(url) and url != "" ->
        :ok

      _missing ->
        Mix.raise(
          "SNODO_TASKS_DATABASE_URL is required for the live PostgreSQL contract; " <>
            "for example: " <>
            "ecto://postgres:postgres@127.0.0.1:55432/snodo_tasks"
        )
    end
  end

  defp verify_contract_ids! do
    unless Code.ensure_loaded?(@contract_test_module) and
             function_exported?(@contract_test_module, :__ex_unit__, 0) do
      Mix.raise("PostgreSQL live contract test module was not loaded")
    end

    observed =
      @contract_test_module
      |> ex_unit_metadata()
      |> Map.fetch!(:tests)
      |> Enum.flat_map(fn test -> Map.get(test.tags, :mcp_contract, []) end)
      |> Enum.uniq()
      |> Enum.sort()

    unless observed == @contract_ids do
      Mix.raise(
        "PostgreSQL live contract evidence drifted; " <>
          "expected=#{inspect(@contract_ids)} observed=#{inspect(observed)}"
      )
    end
  end

  defp ex_unit_metadata(module), do: module.__ex_unit__()
end
