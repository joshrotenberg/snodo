defmodule Mix.Tasks.Tasks.Sqlite.Contract do
  use Mix.Task

  @shortdoc "Runs the SQLite Tasks adapter's package-owned contract"

  @contract_ids [
    "tasks-sqlite-migration",
    "tasks-sqlite-scope",
    "tasks-sqlite-concurrency",
    "tasks-sqlite-ledger",
    "tasks-sqlite-leases",
    "tasks-sqlite-time",
    "tasks-sqlite-recovery"
  ]

  @contract_test_module Snodo.Extensions.Tasks.SQLite.IntegrationTest
  @contract_test_path "test/sqlite_integration_test.exs"

  @moduledoc """
  Runs the file-backed SQLite adapter contract and verifies its local evidence
  tags without coupling the package to `Snodo.Compliance`.

      mix tasks.sqlite.contract

  The contract uses ordinary pooled Repo connections and temporary database
  files so writer serialization, busy handling, and restart recovery remain
  part of the executable evidence.
  """

  @impl Mix.Task
  def run([]) do
    ensure_contract_test!()

    Mix.Task.run("test", [
      @contract_test_path,
      "--warnings-as-errors",
      "--raise",
      "--seed",
      "0"
    ])

    verify_contract_ids!()

    Mix.shell().info("SQLite Tasks contract: #{length(@contract_ids)} evidence groups passed")
  end

  def run(_args), do: Mix.raise("usage: mix tasks.sqlite.contract")

  defp ensure_contract_test! do
    unless File.regular?(@contract_test_path) do
      Mix.raise("SQLite Tasks contract test is missing: #{@contract_test_path}")
    end
  end

  defp verify_contract_ids! do
    ensure_contract_module!()

    observed =
      @contract_test_module
      |> ex_unit_metadata()
      |> Map.fetch!(:tests)
      |> Enum.flat_map(fn test -> Map.get(test.tags, :mcp_contract, []) end)
      |> Enum.uniq()

    unless Enum.sort(observed) == Enum.sort(@contract_ids) do
      Mix.raise(
        "SQLite Tasks contract evidence drifted; " <>
          "expected=#{inspect(@contract_ids)} observed=#{inspect(observed)}"
      )
    end
  end

  defp ensure_contract_module! do
    unless Code.ensure_loaded?(@contract_test_module) and
             function_exported?(@contract_test_module, :__ex_unit__, 0) do
      Mix.raise(
        "SQLite Tasks contract test module was not loaded: #{inspect(@contract_test_module)}"
      )
    end
  end

  defp ex_unit_metadata(module), do: module.__ex_unit__()
end
