defmodule Mix.Tasks.Snodo.Contract do
  use Mix.Task

  @contract_test_modules [
    Snodo.Compliance.ProfileAndInspectorTest,
    Snodo.Compliance.V2026_07_28VectorsTest,
    Snodo.PaginationProtocolAcceptanceTest,
    Snodo.SubscriptionProtocolAcceptanceTest,
    Snodo.ExtensionAcceptanceTest,
    Snodo.MRTR.ProtocolAcceptanceTest,
    Snodo.MRTR.ExtensionAcceptanceTest,
    Snodo.MRTR.StateTest,
    Snodo.ProgressTest,
    Snodo.ProgressTransportAcceptanceTest,
    Snodo.HTTPRequestDeadlineTest,
    Snodo.Transport.StdioWriteTimeoutTest,
    Snodo.Transport.StdioAcceptanceTest,
    Snodo.Transport.StreamableHTTP.AdapterAcceptanceTest,
    Snodo.Transport.StreamableHTTP.ServerAcceptanceTest
  ]

  @contract_test_paths [
    "test/compliance",
    "test/pagination_protocol_acceptance_test.exs",
    "test/subscription_protocol_acceptance_test.exs",
    "test/extension_acceptance_test.exs",
    "test/mrtr_protocol_acceptance_test.exs",
    "test/mrtr_extension_acceptance_test.exs",
    "test/mrtr_state_test.exs",
    "test/progress_test.exs",
    "test/progress_transport_acceptance_test.exs",
    "test/http_request_deadline_test.exs",
    "test/stdio_write_timeout_test.exs",
    "test/stdio_acceptance_test.exs",
    "test/http_adapter_acceptance_test.exs",
    "test/http_server_acceptance_test.exs"
  ]

  @shortdoc "Runs the internal MCP wire contract and prints its evidence report"

  @moduledoc """
  Runs the literal-wire compliance tests, then prints an evidence report.

      mix snodo.contract
      mix snodo.contract --format json
      mix snodo.contract --format markdown
      mix snodo.contract --format json --output mcp-contract.json

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
      Mix.raise("usage: mix snodo.contract [--format human|json|markdown] [--output PATH]")
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
      Snodo.Compliance.report(Snodo.Protocol.V2026_07_28.profile(),
        internal_pass: internal_pass
      )

    emit(render(report, format), output)
  end

  defp render(report, "json"), do: JSON.encode!(report)
  defp render(report, "markdown"), do: Snodo.Compliance.to_markdown(report)

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
        Mix.Task.run("test", args ++ ["--formatter", "Snodo.Compliance.QuietFormatter"])
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

    required = Snodo.Compliance.internal_contracts()
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
    Snodo.Compliance.verify_requirements_manifest!(path)
  end
end
