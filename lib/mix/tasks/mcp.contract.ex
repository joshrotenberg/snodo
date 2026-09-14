defmodule Mix.Tasks.Mcp.Contract do
  use Mix.Task

  @contract_test_modules [
    MCP.Compliance.ProfileAndInspectorTest,
    MCP.Compliance.V2026_07_28VectorsTest,
    MCP.PaginationProtocolAcceptanceTest,
    MCP.SubscriptionProtocolAcceptanceTest,
    MCP.ExtensionAcceptanceTest,
    MCP.MRTR.ProtocolAcceptanceTest,
    MCP.MRTR.ExtensionAcceptanceTest,
    MCP.MRTR.StateTest,
    MCP.Transport.StdioAcceptanceTest,
    MCP.Transport.StreamableHTTP.AdapterAcceptanceTest,
    MCP.Transport.StreamableHTTP.ServerAcceptanceTest
  ]

  @contract_test_paths [
    "test/compliance",
    "test/pagination_protocol_acceptance_test.exs",
    "test/subscription_protocol_acceptance_test.exs",
    "test/extension_acceptance_test.exs",
    "test/mrtr_protocol_acceptance_test.exs",
    "test/mrtr_extension_acceptance_test.exs",
    "test/mrtr_state_test.exs",
    "test/stdio_acceptance_test.exs",
    "test/http_adapter_acceptance_test.exs",
    "test/http_server_acceptance_test.exs"
  ]

  @shortdoc "Runs the internal MCP wire contract and prints its evidence report"

  @moduledoc """
  Runs the literal-wire compliance tests, then prints an evidence report.

      mix mcp.contract
      mix mcp.contract --format json
      mix mcp.contract --format markdown
      mix mcp.contract --format json --output mcp-contract.json

  The report deliberately keeps internal contract evidence separate from the
  frozen official MCP conformance run.
  """

  @impl true
  def run(args) do
    {opts, positional, invalid} =
      OptionParser.parse(args,
        strict: [format: :string, output: :string],
        aliases: [f: :format, o: :output]
      )

    if positional != [] or invalid != [] do
      Mix.raise("usage: mix mcp.contract [--format human|json|markdown] [--output PATH]")
    end

    format = Keyword.get(opts, :format, "human")
    output = Keyword.get(opts, :output)

    unless format in ["human", "json", "markdown"] do
      Mix.raise("--format must be human, json, or markdown")
    end

    verify_requirements_manifest!()
    run_contract_tests(format)
    internal_pass = collect_internal_pass!()

    report =
      MCP.Compliance.report(MCP.Protocol.V2026_07_28.profile(),
        internal_pass: internal_pass
      )

    emit(render(report, format), output)
  end

  defp render(report, "json"), do: JSON.encode!(report)
  defp render(report, "markdown"), do: MCP.Compliance.to_markdown(report)

  defp render(report, "human") do
    evidence = report["evidence"]
    official = report["officialServerConformance"]

    """
    MCP 2026-07-28 internal contract: #{length(evidence["internalPass"])} evidence groups passed
    Official server conformance: #{official["status"]} (#{official["passedScenarios"]}/#{official["requiredScenarios"]} exercised whole scenarios passed; #{official["measuredScenarios"]} attempted)
    Raw runner scenarios without a failure check: #{official["runnerNoFailureScenarios"]}/#{official["requiredScenarios"]} (#{length(official["excludedRunnerNoFailure"])} excluded from the exercised score)
    """
  end

  defp emit(rendered, nil), do: Mix.shell().info(rendered)

  defp emit(rendered, output) when is_binary(output) and output != "" do
    File.write!(output, rendered <> "\n")
    Mix.shell().info("Wrote MCP contract report to #{output}")
  end

  defp emit(_rendered, _output), do: Mix.raise("--output must be a non-empty path")

  defp run_contract_tests(format) do
    args = @contract_test_paths ++ ["--warnings-as-errors", "--seed", "0"]

    if format == "json" do
      previous_shell = Mix.shell()
      Mix.shell(Mix.Shell.Process)

      try do
        Mix.Task.run("test", args ++ ["--formatter", "MCP.Compliance.QuietFormatter"])
      after
        Mix.shell(previous_shell)
      end
    else
      Mix.Task.run("test", args)
    end
  end

  defp collect_internal_pass! do
    observed =
      @contract_test_modules
      |> Enum.flat_map(&module_contract_ids!/1)
      |> Enum.uniq()

    required = MCP.Compliance.internal_contracts()
    missing = required -- observed
    unexpected = observed -- required

    if missing != [] or unexpected != [] do
      Mix.raise(
        "compliance evidence coverage drifted; " <>
          "missing=#{inspect(missing)} unexpected=#{inspect(unexpected)}"
      )
    end

    required
  end

  defp module_contract_ids!(module) do
    unless Code.ensure_loaded?(module) and function_exported?(module, :__ex_unit__, 0) do
      Mix.raise("compliance test module #{inspect(module)} was not loaded")
    end

    module.__ex_unit__().tests
    |> Enum.flat_map(fn test -> Map.get(test.tags, :mcp_contract, []) end)
  end

  defp verify_requirements_manifest! do
    project_root = Mix.Project.project_file() |> Path.expand() |> Path.dirname()
    path = Path.join(project_root, "conformance/requirements/2026-07-28.yaml")
    MCP.Compliance.verify_requirements_manifest!(path)
  end
end
