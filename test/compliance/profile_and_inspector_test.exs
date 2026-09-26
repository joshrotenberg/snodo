defmodule Snodo.Compliance.ProfileAndInspectorTest do
  use ExUnit.Case, async: true

  alias Snodo.Compliance
  alias Snodo.Envelope
  alias Snodo.Protocol
  alias Snodo.Protocol.Inspector
  alias Snodo.Protocol.Profile
  alias Snodo.Protocol.Registry
  alias Snodo.Protocol.V2026_07_28
  alias Snodo.Router
  alias Snodo.Server
  alias Snodo.Server.Runtime
  alias Snodo.Transport.Context, as: TransportContext
  alias SnodoTest.ProfileDriftDialect
  alias SnodoTest.TestTools.Echo

  @literal_meta %{
    "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
    "io.modelcontextprotocol/clientCapabilities" => %{}
  }

  @expected_core_catalog [
    {"completion/complete", :request, :client_to_server, :required, "completions", :implemented,
     :top_level, :active},
    {"prompts/get", :request, :client_to_server, :required, "prompts", :implemented, :top_level,
     :active},
    {"prompts/list", :request, :client_to_server, :required, "prompts", :implemented, :top_level,
     :active},
    {"resources/list", :request, :client_to_server, :required, "resources", :implemented,
     :top_level, :active},
    {"resources/read", :request, :client_to_server, :required, "resources", :implemented,
     :top_level, :active},
    {"resources/templates/list", :request, :client_to_server, :required, "resources",
     :implemented, :top_level, :active},
    {"server/discover", :request, :client_to_server, :required, nil, :implemented, :top_level,
     :active},
    {"subscriptions/listen", :request, :client_to_server, :required, nil, :implemented,
     :top_level, :active},
    {"tools/call", :request, :client_to_server, :required, "tools", :implemented, :top_level,
     :active},
    {"tools/list", :request, :client_to_server, :required, "tools", :implemented, :top_level,
     :active},
    {"notifications/cancelled", :notification, :client_to_server, :required, nil, :implemented,
     :top_level, :active},
    {"notifications/cancelled", :notification, :server_to_client, :required, nil, :unsupported,
     :top_level, :active},
    {"notifications/message", :notification, :server_to_client, :required, "logging",
     :unsupported, :top_level, :deprecated},
    {"notifications/progress", :notification, :server_to_client, :required, nil, :implemented,
     :top_level, :active},
    {"notifications/prompts/list_changed", :notification, :server_to_client, :optional, "prompts",
     :implemented, :top_level, :active},
    {"notifications/resources/list_changed", :notification, :server_to_client, :optional,
     "resources", :implemented, :top_level, :active},
    {"notifications/resources/updated", :notification, :server_to_client, :required, "resources",
     :implemented, :top_level, :active},
    {"notifications/subscriptions/acknowledged", :notification, :server_to_client, :required, nil,
     :implemented, :top_level, :active},
    {"notifications/tools/list_changed", :notification, :server_to_client, :optional, "tools",
     :implemented, :top_level, :active},
    {"elicitation/create", :request, :server_to_client, :required, nil, :implemented,
     :mrtr_embedded, :active},
    {"roots/list", :request, :server_to_client, :optional, nil, :unsupported, :mrtr_embedded,
     :deprecated},
    {"sampling/createMessage", :request, :server_to_client, :required, nil, :unsupported,
     :mrtr_embedded, :deprecated}
  ]

  @tag mcp_contract: [
         "profile-manifest",
         "prompts-routing-wire",
         "resources-routing-wire",
         "completion-routing-wire"
       ]
  test "the exact profile is a machine-readable implemented-slice contract" do
    profile = V2026_07_28.profile()

    assert %Profile{
             version: "2026-07-28",
             status: :released,
             scope: :implemented_slice,
             era: :stateless,
             batching: :forbidden,
             capabilities: ["completions", "tools", "prompts", "resources"]
           } = profile

    assert Profile.method_names(profile,
             direction: :client_to_server,
             status: :implemented
           ) == [
             "server/discover",
             "completion/complete",
             "tools/list",
             "tools/call",
             "prompts/list",
             "prompts/get",
             "resources/list",
             "resources/templates/list",
             "resources/read",
             "subscriptions/listen",
             "notifications/cancelled"
           ]

    assert Profile.method_names(profile,
             direction: :client_to_server,
             status: :unsupported
           ) == []

    assert length(profile.methods) == 22
    assert profile.methods |> Enum.map(& &1.name) |> Enum.uniq() |> length() == 21

    actual_catalog =
      for method <- profile.methods, direction <- method.directions do
        {
          method.name,
          method.kind,
          direction,
          method.params,
          method.capability,
          method.status,
          method.placement,
          method.lifecycle
        }
      end

    assert MapSet.new(actual_catalog) == MapSet.new(@expected_core_catalog)

    for extension_method <- [
          "tasks/get",
          "tasks/update",
          "tasks/cancel",
          "notifications/tasks"
        ] do
      assert :error = Profile.fetch_method(profile, extension_method)
    end

    assert {:ok, %{status: :implemented}} =
             Profile.fetch_method(profile, "notifications/cancelled", :client_to_server)

    assert {:ok, %{status: :unsupported}} =
             Profile.fetch_method(profile, "notifications/cancelled", :server_to_client)

    assert {:ok, %{placement: :mrtr_embedded, lifecycle: :deprecated}} =
             Profile.fetch_method(profile, "sampling/createMessage", :server_to_client)

    assert {:ok, %{placement: :mrtr_embedded, params: :optional, lifecycle: :deprecated}} =
             Profile.fetch_method(profile, "roots/list", :server_to_client)

    assert %{
             "protocolVersion" => "2026-07-28",
             "scope" => "implemented_slice",
             "transports" => %{
               "direct" => "tested",
               "stdio" => "tested",
               "streamable_http" => "tested"
             },
             "limitations" => %{
               "official_server_conformance" => "partial"
             }
           } = Profile.to_map(profile)

    registry = Registry.new([V2026_07_28])
    assert Registry.profiles(registry) == [profile]
    assert Registry.versions(registry) == ["2026-07-28"]

    assert Protocol.builtin_profiles() == [
             profile,
             Snodo.Protocol.V2025_11_25.profile(),
             Snodo.Protocol.V2025_06_18.profile()
           ]

    assert Protocol.builtin_versions() == ["2026-07-28", "2025-11-25", "2025-06-18"]
  end

  @tag mcp_contract: [
         "runtime-capability-advertisement",
         "prompts-routing-wire",
         "resources-routing-wire"
       ]
  test "runtime rejects capabilities that no enabled profile implements" do
    router = Router.new() |> Router.register_tool(Echo)

    build_runtime = fn capabilities ->
      Runtime.new(
        router: router,
        protocols: [V2026_07_28],
        server_info: %{"name" => "invalid", "version" => "1.0.0"},
        capabilities: capabilities
      )
    end

    assert build_runtime.(%{"tools" => %{}, "resources" => %{}}).capabilities == %{
             "tools" => %{},
             "resources" => %{}
           }

    assert_raise ArgumentError, ~r/configured subscription_source/, fn ->
      build_runtime.(%{"tools" => %{}, "resources" => %{"subscribe" => true}})
    end

    assert_raise ArgumentError, ~r/configured subscription_source/, fn ->
      build_runtime.(%{"tools" => %{}, "resources" => %{"listChanged" => true}})
    end

    assert_raise ArgumentError, ~r/tasks for 2026-07-28/, fn ->
      build_runtime.(%{"tools" => %{}, "tasks" => %{}})
    end

    assert_raise ArgumentError, ~r/com.example\/custom for 2026-07-28/, fn ->
      build_runtime.(%{"tools" => %{}, "com.example/custom" => %{}})
    end

    assert_raise ArgumentError, ~r/server advertises unregistered extension/, fn ->
      build_runtime.(%{
        "tools" => %{},
        "extensions" => %{"com.example/feature" => %{}}
      })
    end

    assert_raise ArgumentError, ~r/configured subscription_source/, fn ->
      build_runtime.(%{"tools" => %{"listChanged" => true}})
    end

    assert build_runtime.(%{"tools" => %{"listChanged" => false}}).capabilities == %{
             "tools" => %{"listChanged" => false}
           }
  end

  @tag mcp_contract: ["profile-capability-projection"]
  test "profile capability projection preserves implemented and open registries" do
    capabilities = %{
      "tools" => %{"listChanged" => false},
      "resources" => %{},
      "tasks" => %{},
      "experimental" => %{"vendor" => %{}},
      "extensions" => %{"com.example/feature" => %{}},
      "com.example/custom" => %{}
    }

    assert Profile.project_capabilities(V2026_07_28.profile(), capabilities) == %{
             "tools" => %{"listChanged" => false},
             "resources" => %{},
             "experimental" => %{"vendor" => %{}},
             "extensions" => %{"com.example/feature" => %{}}
           }
  end

  @tag mcp_contract: ["exact-profile-admission"]
  test "inspector applies exact method kind, direction, params, and metadata rules" do
    transport = %TransportContext{transport: :direct}

    valid = %{
      "jsonrpc" => "2.0",
      "id" => "call-1",
      "method" => "tools/call",
      "params" => %{
        "name" => "echo",
        "arguments" => %{"text" => "hello"},
        "_meta" => @literal_meta
      }
    }

    assert {:ok, envelope} = Envelope.decode(valid, transport)

    assert {:ok, inspection} =
             Inspector.inspect(V2026_07_28.profile(), envelope, :client_to_server)

    assert inspection.classification == :implemented
    assert inspection.method.name == "tools/call"

    assert {:error, direction_error} =
             Inspector.inspect(V2026_07_28.profile(), envelope, :server_to_client)

    assert direction_error.code == -32_600

    notification_shape = Map.delete(valid, "id")
    assert {:ok, notification} = Envelope.decode(notification_shape, transport)

    assert {:error, kind_error} =
             Inspector.inspect(V2026_07_28.profile(), notification, :client_to_server)

    assert kind_error.code == -32_600

    missing_params = valid |> Map.delete("params")
    assert {:ok, no_params} = Envelope.decode(missing_params, transport)

    assert {:error, params_error} =
             Inspector.inspect(V2026_07_28.profile(), no_params, :client_to_server)

    assert params_error.code == -32_602
  end

  @tag mcp_contract: ["extension-classification"]
  test "unknown vendor methods remain classifiable for a future extension registry" do
    raw = %{
      "jsonrpc" => "2.0",
      "id" => 8,
      "method" => "com.example/custom",
      "params" => %{"_meta" => @literal_meta}
    }

    assert {:ok, envelope} = Envelope.decode(raw, %TransportContext{transport: :direct})

    assert {:ok, inspection} =
             Inspector.inspect(V2026_07_28.profile(), envelope, :client_to_server)

    assert inspection.classification == :extension
    assert inspection.method == nil
  end

  @tag mcp_contract: [
         "exact-profile-admission",
         "extension-classification",
         "resources-routing-wire"
       ]
  test "known core methods remain distinct from unknown extension methods" do
    raw = %{
      "jsonrpc" => "2.0",
      "id" => 9,
      "method" => "resources/list",
      "params" => %{"_meta" => @literal_meta}
    }

    transport = %TransportContext{transport: :direct}
    assert {:ok, envelope} = Envelope.decode(raw, transport)

    assert {:ok, inspection} =
             Inspector.inspect(V2026_07_28.profile(), envelope, :client_to_server)

    assert inspection.classification == :implemented
    assert inspection.method.name == "resources/list"

    runtime =
      Runtime.new(
        router: Router.new() |> Router.register_tool(Echo),
        protocols: [V2026_07_28],
        server_info: %{"name" => "catalog", "version" => "1.0.0"}
      )

    assert {:ok, %{"error" => %{"code" => -32_601}}} =
             Server.dispatch(runtime, raw, transport)
  end

  @tag mcp_contract: [
         "exact-profile-admission",
         "streamable-http-admission",
         "resources-routing-wire"
       ]
  test "resource inspection and HTTP name policy retain the exact URI" do
    transport = %TransportContext{transport: :direct}

    raw = %{
      "jsonrpc" => "2.0",
      "id" => "resource-policy",
      "method" => "resources/read",
      "params" => %{
        "uri" => "test://packages/ecto?version=3.13.0",
        "_meta" => @literal_meta
      }
    }

    assert {:ok, envelope} = Envelope.decode(raw, transport)

    assert {:ok, inspection} =
             Inspector.inspect(V2026_07_28.profile(), envelope, :client_to_server)

    assert inspection.classification == :implemented
    assert inspection.method.name == "resources/read"

    policy = V2026_07_28.transport_policy(envelope)
    assert "mcp-name" in policy.required_headers

    assert policy.mirrored_headers["mcp-name"] == %{
             path: ["params", "uri"],
             encoding: :base64_sentinel
           }

    invalid = put_in(raw, ["params", "uri"], "relative/resource")
    assert {:ok, invalid_envelope} = Envelope.decode(invalid, transport)

    assert {:error, invalid_error} =
             Inspector.inspect(V2026_07_28.profile(), invalid_envelope, :client_to_server)

    assert invalid_error.code == -32_602
  end

  @tag mcp_contract: ["exact-profile-admission", "extension-classification"]
  test "server admits only implemented profile methods when a resolver drifts" do
    runtime =
      Runtime.new(
        router: Router.new() |> Router.register_tool(Echo),
        protocols: [ProfileDriftDialect],
        server_info: %{"name" => "drift", "version" => "1.0.0"}
      )

    for {id, method} <- [{91, "acme/echo"}, {92, "acme/hidden"}] do
      raw = %{
        "jsonrpc" => "2.0",
        "id" => id,
        "method" => method,
        "params" => %{
          "name" => "echo",
          "arguments" => %{"text" => "must not run"},
          "_meta" => %{
            "com.acme/protocolVersion" => "2099-01-01",
            "com.acme/clientCapabilities" => %{}
          }
        }
      }

      assert {:ok, response} =
               Server.dispatch(runtime, raw, %TransportContext{transport: :direct})

      assert response["id"] == id
      assert get_in(response, ["error", "code"]) == -32_601
    end
  end

  test "compliance report separates internal evidence from the measured official score" do
    summary =
      Compliance.latest_official_summary!(Path.expand("../../conformance/results", __DIR__))

    report =
      Compliance.report(V2026_07_28.profile(),
        internal_pass: Compliance.internal_contracts(),
        official_summary: summary
      )

    assert length(report["evidence"]["internalPass"]) == 31
    assert report["evidence"]["officialPass"] == summary["score"]["passedScenarioIds"]
    official = report["officialServerConformance"]

    assert %{
             "status" => "partial",
             "measuredScenarios" => 37,
             "passedScenarios" => 32,
             "requiredScenarios" => 37
           } = official

    assert length(official["requirements"]) == 37
    assert official["runDate"] == summary["runDate"]
    assert official["currentRunner"] == summary["runner"]
    assert official["requiredCheckCounts"] == summary["requiredCheckCounts"]
    assert official["runnerNoFailureScenarioIds"] == summary["rawRunnerNoFailure"]["scenarioIds"]

    assert official["excludedRunnerNoFailure"] ==
             summary["rawRunnerNoFailure"]["excludedFromScore"]

    passing_unscored =
      for %{"checks" => checks} = entry <- summary["notScored"],
          checks["success"] > 0,
          checks["failure"] + checks["warning"] + checks["skipped"] == 0,
          do: entry["scenario"]

    assert Enum.map(official["notScoredPass"], & &1["scenario"]) == passing_unscored
    assert "json-schema-2020-12" in passing_unscored

    assert official["requirementsCommit"] == "c321dd32035556e6769d3724a8ee97d87c3faaac"

    assert official["requirementsSha256"] ==
             "ae2f4f6210fd729e2e318edd5bbfa31a43cee0bc608e48052fa26dbf1d939b57"

    manifest = Path.expand("../../conformance/requirements/2026-07-28.yaml", __DIR__)
    assert :ok = Compliance.verify_requirements_manifest!(manifest)

    # The newest retained run is the one the report uses: the latest date wins.
    results = Path.expand("../../conformance/results", __DIR__)

    newest =
      results
      |> File.ls!()
      |> Enum.filter(&Regex.match?(~r/\A\d{4}-\d{2}-\d{2}-alpha\.11-summary\.json\z/, &1))
      |> Enum.max()

    assert String.starts_with?(newest, summary["runDate"])

    assert is_binary(JSON.encode!(report))
  end
end
