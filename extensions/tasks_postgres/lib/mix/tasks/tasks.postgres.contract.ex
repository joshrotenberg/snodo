defmodule Mix.Tasks.Tasks.Postgres.Contract do
  use Mix.Task

  @shortdoc "Runs the PostgreSQL Tasks adapter's package-owned contract"

  @contract_ids ["tasks-postgres-adapter"]

  @contract_test_modules [
    MCP.Extensions.Tasks.Postgres.AdapterTest,
    MCP.Extensions.Tasks.Postgres.PersistenceTest
  ]

  @contract_test_paths [
    "test/postgres_adapter_test.exs",
    "test/postgres_persistence_test.exs"
  ]

  @moduledoc """
  Runs the database-independent PostgreSQL adapter contract.

      mix tasks.postgres.contract

  The separately configured live-PostgreSQL lane owns lock and transaction
  integration evidence; this task remains runnable without a database service.
  """

  @impl Mix.Task
  def run([]) do
    Enum.each(@contract_test_paths, &ensure_contract_test!/1)

    Mix.Task.run("test", @contract_test_paths ++ ["--warnings-as-errors", "--seed", "0"])
    verify_contract_ids!()
    Mix.shell().info("PostgreSQL Tasks contract: 1 evidence group passed")
  end

  def run(_args), do: Mix.raise("usage: mix tasks.postgres.contract")

  defp verify_contract_ids! do
    Enum.each(@contract_test_modules, &ensure_contract_module!/1)

    observed =
      @contract_test_modules
      |> Enum.flat_map(fn module ->
        module
        |> ex_unit_metadata()
        |> Map.fetch!(:tests)
      end)
      |> Enum.flat_map(fn test -> Map.get(test.tags, :mcp_contract, []) end)
      |> Enum.uniq()

    unless observed == @contract_ids do
      Mix.raise(
        "PostgreSQL Tasks contract evidence drifted; " <>
          "expected=#{inspect(@contract_ids)} observed=#{inspect(observed)}"
      )
    end
  end

  defp ensure_contract_test!(path) do
    unless File.regular?(path) do
      Mix.raise("PostgreSQL Tasks contract test is missing: #{path}")
    end
  end

  defp ensure_contract_module!(module) do
    unless Code.ensure_loaded?(module) and function_exported?(module, :__ex_unit__, 0) do
      Mix.raise("PostgreSQL Tasks contract test module was not loaded: #{inspect(module)}")
    end
  end

  defp ex_unit_metadata(module), do: module.__ex_unit__()
end
