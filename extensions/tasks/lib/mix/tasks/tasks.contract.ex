defmodule Mix.Tasks.Tasks.Contract do
  use Mix.Task

  @shortdoc "Runs the Tasks extension wire contract"

  @contract_ids [
    "tasks-extension-lifecycle",
    "tasks-extension-races",
    "tasks-extension-http-admission",
    "tasks-extension-subscriptions-http",
    "tasks-extension-subscriptions",
    "tasks-store-hardening",
    "tasks-work-descriptor",
    "tasks-durable-store",
    "tasks-recovery-claims",
    "tasks-retry-policy"
  ]

  @contract_test_modules [
    MCP.TasksExtensionAcceptanceTest,
    MCP.TasksOrdinaryMRTRBoundaryTest,
    MCP.TasksLifecycleRaceTest,
    MCP.TasksHTTPAcceptanceTest,
    MCP.TasksSubscriptionAcceptanceTest,
    MCP.TasksStoreHardeningTest,
    MCP.TasksWorkDescriptorTest,
    MCP.TasksDurableStoreTest,
    MCP.TasksRecoveryTest,
    MCP.TasksRetryPolicyTest
  ]

  @contract_test_paths [
    "test/tasks_extension_acceptance_test.exs",
    "test/ordinary_mrtr_boundary_test.exs",
    "test/tasks_lifecycle_race_test.exs",
    "test/tasks_http_acceptance_test.exs",
    "test/tasks_subscription_acceptance_test.exs",
    "test/tasks_store_hardening_test.exs",
    "test/tasks_work_descriptor_test.exs",
    "test/tasks_durable_store_test.exs",
    "test/tasks_recovery_test.exs",
    "test/tasks_retry_policy_test.exs"
  ]

  @moduledoc """
  Runs the package-owned Tasks contract tests and verifies their local evidence
  tags without coupling the extension package to `MCP.Compliance`.

      mix tasks.contract
  """

  @impl Mix.Task
  def run([]) do
    verify_test_paths!()
    Mix.Task.run("test", @contract_test_paths ++ ["--warnings-as-errors", "--seed", "0"])
    verify_contract_ids!()

    Mix.shell().info("Tasks extension contract: #{length(@contract_ids)} evidence groups passed")
  end

  def run(_args), do: Mix.raise("usage: mix tasks.contract")

  defp verify_test_paths! do
    missing = Enum.reject(@contract_test_paths, &File.regular?/1)

    if missing != [] do
      Mix.raise("Tasks contract test files are missing: #{Enum.join(missing, ", ")}")
    end
  end

  defp verify_contract_ids! do
    observed =
      @contract_test_modules
      |> Enum.flat_map(&module_contract_ids!/1)
      |> Enum.uniq()

    unless observed == @contract_ids do
      Mix.raise(
        "Tasks contract evidence drifted; " <>
          "expected=#{inspect(@contract_ids)} observed=#{inspect(observed)}"
      )
    end
  end

  defp module_contract_ids!(module) do
    unless Code.ensure_loaded?(module) and function_exported?(module, :__ex_unit__, 0) do
      Mix.raise("Tasks contract test module #{inspect(module)} was not loaded")
    end

    module.__ex_unit__().tests
    |> Enum.flat_map(fn test -> Map.get(test.tags, :mcp_contract, []) end)
  end
end
