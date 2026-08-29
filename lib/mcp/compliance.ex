defmodule MCP.Compliance do
  @moduledoc """
  Honest, machine-readable evidence inventory for the implemented MCP slice.

  Internal contract checks, unsupported surfaces, unmeasured surfaces, and
  official conformance results remain separate buckets. Passing the internal
  contract never becomes an official conformance score.
  """

  alias MCP.Protocol.Profile

  @official_runner "@modelcontextprotocol/conformance@0.2.0-alpha.11"
  @requirements_commit "c321dd32035556e6769d3724a8ee97d87c3faaac"
  @requirements_anchor "@modelcontextprotocol/conformance@0.2.0-alpha.10"
  @requirements_sha256 "ae2f4f6210fd729e2e318edd5bbfa31a43cee0bc608e48052fa26dbf1d939b57"
  @requirements_source "https://github.com/modelcontextprotocol/conformance/blob/#{@requirements_commit}/requirements/2026-07-28.yaml"

  @official_server_requirements [
    "server-stateless",
    "completion-complete",
    "tools-list",
    "tools-call-simple-text",
    "tools-call-image",
    "tools-call-audio",
    "tools-call-embedded-resource",
    "tools-call-mixed-content",
    "tools-call-error",
    "tools-call-with-progress",
    "server-sse-multiple-streams",
    "resources-list",
    "resources-read-text",
    "resources-read-binary",
    "resources-templates-read",
    "sep-2164-resource-not-found",
    "prompts-list",
    "prompts-get-simple",
    "prompts-get-with-args",
    "prompts-get-embedded-resource",
    "prompts-get-with-image",
    "dns-rebinding-protection",
    "caching",
    "input-required-result-basic-elicitation",
    "input-required-result-basic-sampling",
    "input-required-result-basic-list-roots",
    "input-required-result-request-state",
    "input-required-result-multiple-input-requests",
    "input-required-result-multi-round",
    "input-required-result-missing-input-response",
    "input-required-result-non-tool-request",
    "input-required-result-result-type",
    "input-required-result-unsupported-methods",
    "input-required-result-tampered-state",
    "input-required-result-capability-check",
    "input-required-result-ignore-extra-params",
    "input-required-result-validate-input"
  ]

  @official_exercised_pass [
    "completion-complete",
    "tools-list",
    "tools-call-simple-text",
    "tools-call-image",
    "tools-call-audio",
    "tools-call-embedded-resource",
    "tools-call-mixed-content",
    "tools-call-error",
    "server-sse-multiple-streams",
    "resources-list",
    "resources-read-text",
    "resources-read-binary",
    "resources-templates-read",
    "sep-2164-resource-not-found",
    "prompts-list",
    "prompts-get-simple",
    "prompts-get-with-args",
    "prompts-get-embedded-resource",
    "prompts-get-with-image",
    "dns-rebinding-protection",
    "caching",
    "input-required-result-unsupported-methods"
  ]

  @official_runner_no_failure @official_exercised_pass ++
                                [
                                  "input-required-result-missing-input-response",
                                  "input-required-result-ignore-extra-params",
                                  "input-required-result-validate-input"
                                ]

  @excluded_runner_no_failure [
    %{
      "scenario" => "input-required-result-missing-input-response",
      "reason" => "required fixture absent; runner emitted a warning with no failure check"
    },
    %{
      "scenario" => "input-required-result-ignore-extra-params",
      "reason" => "required fixture absent; runner emitted a warning with no failure check"
    },
    %{
      "scenario" => "input-required-result-validate-input",
      "reason" =>
        "required fixture absent; method-not-found produced a false-positive no-failure result"
    }
  ]

  @required_check_counts %{
    "success" => 89,
    "failure" => 15,
    "skipped" => 5,
    "warning" => 2,
    "info" => 1
  }

  @not_scored_pass [
    %{
      "scenario" => "json-schema-2020-12",
      "status" => "pending",
      "passedChecks" => 8,
      "totalChecks" => 8
    },
    %{
      "scenario" => "http-header-validation",
      "status" => "pending",
      "passedChecks" => 14,
      "totalChecks" => 14
    }
  ]

  @internal_contracts [
    "profile-manifest",
    "runtime-capability-advertisement",
    "profile-capability-projection",
    "exact-profile-admission",
    "resources-routing-wire",
    "prompts-routing-wire",
    "completion-routing-wire",
    "list-pagination-wire",
    "extension-classification",
    "direct-stdio-success-vectors",
    "direct-stdio-negative-vectors",
    "response-free-cancellation",
    "header-body-version-mismatch",
    "stdio-error-id-correlation",
    "streamable-http-admission",
    "streamable-http-listener",
    "subscriptions-listen-wire",
    "subscriptions-source-lifecycle",
    "subscriptions-stdio",
    "subscriptions-cancellation",
    "subscriptions-http-adapter",
    "subscriptions-http-sse",
    "subscriptions-disconnect",
    "extension-registration",
    "extension-negotiation-dispatch"
  ]

  if length(@official_server_requirements) != 37 do
    raise "the frozen 2026-07-28 server requirement inventory must contain 37 scenarios"
  end

  @spec report(Profile.t(), keyword()) :: map()
  def report(%Profile{version: "2026-07-28"} = profile, opts \\ []) do
    internal_pass = validate_internal_pass!(Keyword.get(opts, :internal_pass, []))

    limitations = Profile.to_map(profile)["limitations"]
    transports = Profile.to_map(profile)["transports"]

    %{
      "protocolProfile" => Profile.to_map(profile),
      "evidence" => %{
        "internalPass" => internal_pass,
        "unsupported" => evidence_names(limitations, transports, "unsupported"),
        "unmeasured" => evidence_names(limitations, transports, "unmeasured"),
        "officialPass" => @official_exercised_pass
      },
      "officialServerConformance" => %{
        "status" => "partial",
        "measuredScenarios" => length(@official_server_requirements),
        "passedScenarios" => length(@official_exercised_pass),
        "requiredScenarios" => length(@official_server_requirements),
        "requirements" => @official_server_requirements,
        "requirementsSource" => @requirements_source,
        "requirementsAnchor" => @requirements_anchor,
        "requirementsCommit" => @requirements_commit,
        "requirementsSha256" => @requirements_sha256,
        "currentRunner" => @official_runner,
        "scoreBasis" => "whole required scenarios with exercised fixtures and no FAILURE checks",
        "requiredCheckCounts" => @required_check_counts,
        "runnerNoFailureScenarios" => length(@official_runner_no_failure),
        "runnerNoFailureScenarioIds" => @official_runner_no_failure,
        "excludedRunnerNoFailure" => @excluded_runner_no_failure,
        "notScoredPass" => @not_scored_pass
      }
    }
  end

  @doc "Returns the canonical IDs that the internal contract suite must evidence."
  @spec internal_contracts() :: [String.t()]
  def internal_contracts, do: @internal_contracts

  @doc "Verifies the pinned frozen requirement artifact and its server inventory."
  @spec verify_requirements_manifest!(Path.t()) :: :ok
  def verify_requirements_manifest!(path) when is_binary(path) do
    manifest = File.read!(path)

    digest =
      :crypto.hash(:sha256, manifest)
      |> Base.encode16(case: :lower)

    unless digest == @requirements_sha256 do
      raise ArgumentError,
            "frozen requirements checksum mismatch: expected #{@requirements_sha256}, got #{digest}"
    end

    unless server_requirements(manifest) == @official_server_requirements do
      raise ArgumentError, "frozen requirements server inventory drifted from the report"
    end

    :ok
  end

  @spec to_markdown(map()) :: String.t()
  def to_markdown(report) when is_map(report) do
    profile = report["protocolProfile"]
    evidence = report["evidence"]
    official = report["officialServerConformance"]

    """
    # MCP contract report

    - Protocol: `#{profile["protocolVersion"]}`
    - Claim scope: `#{profile["scope"]}`
    - Internal contract: #{length(evidence["internalPass"])} passing evidence groups
    - Unsupported surfaces: #{join_or_none(evidence["unsupported"])}
    - Unmeasured surfaces: #{join_or_none(evidence["unmeasured"])}
    - Official server conformance: `#{official["status"]}` (#{official["passedScenarios"]}/#{official["requiredScenarios"]} exercised whole scenarios passed; #{official["measuredScenarios"]} attempted)
    - Raw runner scenarios without a failure check: #{official["runnerNoFailureScenarios"]}/#{official["requiredScenarios"]} (#{length(official["excludedRunnerNoFailure"])} excluded from the exercised score)

    Internal checks are implementation evidence, not an official conformance score.
    """
  end

  defp limitation_names(limitations, status) do
    limitations
    |> Enum.filter(fn {_name, value} -> value == status end)
    |> Enum.map(fn {name, _status} -> name end)
    |> Enum.sort()
  end

  defp evidence_names(limitations, transports, status) do
    transport_names =
      transports
      |> Enum.filter(fn {_name, value} -> value == status end)
      |> Enum.map(fn {name, _status} -> "transport:#{name}" end)

    (limitation_names(limitations, status) ++ transport_names)
    |> Enum.sort()
  end

  defp validate_internal_pass!(internal_pass) when is_list(internal_pass) do
    valid? =
      Enum.uniq(internal_pass) == internal_pass and
        Enum.all?(internal_pass, &(&1 in @internal_contracts))

    unless valid? do
      raise ArgumentError,
            "internal_pass must contain unique IDs from MCP.Compliance.internal_contracts/0"
    end

    Enum.filter(@internal_contracts, &(&1 in internal_pass))
  end

  defp validate_internal_pass!(_internal_pass) do
    raise ArgumentError, "internal_pass must be a list"
  end

  defp server_requirements(manifest) do
    manifest
    |> String.split("\n")
    |> Enum.drop_while(&(&1 != "server:"))
    |> Enum.drop(1)
    |> Enum.take_while(&String.starts_with?(&1, "  - "))
    |> Enum.map(&String.replace_prefix(&1, "  - ", ""))
  end

  defp join_or_none([]), do: "none"
  defp join_or_none(values), do: Enum.join(values, ", ")
end
