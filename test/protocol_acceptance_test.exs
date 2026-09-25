defmodule Snodo.ProtocolAcceptanceTest do
  use ExUnit.Case, async: true

  alias Snodo.Protocol.Registry
  alias Snodo.Protocol.V2026_07_28
  alias Snodo.Server
  alias Snodo.Test, as: MCPTest
  alias Snodo.Transport.Context, as: TransportContext
  alias SnodoTest.FutureDialect
  alias SnodoTest.RejectingInputValidator
  alias SnodoTest.RequiredKeysValidator
  alias SnodoTest.TestFixtures
  alias SnodoTest.TestTools.ComplexSchema
  alias SnodoTest.TestTools.Echo
  alias SnodoTest.TestTools.InvalidStructuredOutput
  alias SnodoTest.TestTools.InvalidWireResult
  alias SnodoTest.TestTools.NotificationProbe

  test "server/discover follows the final 2026-07-28 shape" do
    runtime =
      TestFixtures.runtime(
        instructions: "Use only when useful",
        discovery_cache: [ttl_ms: 250, scope: "public"]
      )

    assert {:ok, response} =
             MCPTest.dispatch(runtime,
               id: "discover-1",
               protocol: "2026-07-28",
               method: "server/discover"
             )

    assert response == %{
             "jsonrpc" => "2.0",
             "id" => "discover-1",
             "result" => %{
               "resultType" => "complete",
               "supportedVersions" => ["2026-07-28"],
               "capabilities" => %{"tools" => %{}},
               "instructions" => "Use only when useful",
               "ttlMs" => 250,
               "cacheScope" => "public",
               "_meta" => %{
                 "io.modelcontextprotocol/serverInfo" => %{
                   "name" => "snodo-spike",
                   "version" => "0.1.0"
                 }
               }
             }
           }
  end

  test "tools/list is deterministic, cacheable, and preserves arbitrary JSON Schema" do
    runtime = TestFixtures.runtime(tools_cache: [ttl_ms: 10, scope: "private"])

    assert {:ok, %{"result" => result}} =
             MCPTest.dispatch(runtime,
               protocol: "2026-07-28",
               method: "tools/list"
             )

    names = Enum.map(result["tools"], & &1["name"])
    assert names == Enum.sort(names)
    assert result["resultType"] == "complete"
    assert result["ttlMs"] == 10
    assert result["cacheScope"] == "private"

    echo = Enum.find(result["tools"], &(&1["name"] == "echo"))
    assert echo["inputSchema"] == Echo.input_schema()
    refute Map.has_key?(echo, "outputSchema")

    complex = Enum.find(result["tools"], &(&1["name"] == "complex_schema"))
    assert complex["outputSchema"] == ComplexSchema.output_schema()

    assert echo
           |> JSON.encode!()
           |> JSON.decode!()
           |> Map.fetch!("inputSchema") == Echo.input_schema()
  end

  test "text and structured tool calls have exact modern result semantics" do
    runtime = TestFixtures.runtime()

    assert {:ok, %{"id" => 0, "result" => text_result}} =
             MCPTest.dispatch(runtime,
               id: 0,
               protocol: "2026-07-28",
               method: "tools/call",
               params: %{"name" => "echo", "arguments" => %{"text" => "hello"}}
             )

    assert text_result["resultType"] == "complete"
    assert text_result["content"] == [%{"type" => "text", "text" => "hello"}]
    assert text_result["isError"] == false

    value = [%{"id" => "a"}, %{"id" => "b"}]

    assert {:ok, %{"result" => structured_result}} =
             MCPTest.dispatch(runtime,
               protocol: "2026-07-28",
               method: "tools/call",
               params: %{"name" => "structured", "arguments" => %{"value" => value}}
             )

    assert structured_result["structuredContent"] == value

    assert structured_result["content"] == [
             %{"type" => "text", "text" => JSON.encode!(value)}
           ]
  end

  test "tool failures are results, while unknown tools and crashes are protocol errors" do
    runtime = TestFixtures.runtime()

    assert {:ok, %{"result" => failure}} =
             MCPTest.dispatch(runtime,
               protocol: "2026-07-28",
               method: "tools/call",
               params: %{"name" => "failing"}
             )

    assert failure["isError"] == true

    assert failure["content"] == [
             %{"type" => "text", "text" => "Actionable domain failure"}
           ]

    assert {:ok, %{"error" => %{"code" => -32_602}}} =
             MCPTest.dispatch(runtime,
               protocol: "2026-07-28",
               method: "tools/call",
               params: %{"name" => "missing"}
             )

    assert {:ok, %{"error" => crash}} =
             MCPTest.dispatch(runtime,
               protocol: "2026-07-28",
               method: "tools/call",
               params: %{"name" => "raising"}
             )

    assert crash == %{"code" => -32_603, "message" => "Tool raised an exception"}
    refute inspect(crash) =~ "secret implementation detail"
  end

  test "request metadata reaches the handler unchanged and no session is invented" do
    runtime = TestFixtures.runtime()

    metadata =
      TestFixtures.metadata("2026-07-28", %{
        "io.modelcontextprotocol/clientInfo" => %{"name" => "test", "version" => "1"},
        "com.example/trace" => %{"nested" => [1, true, nil]},
        "traceparent" => "00-0af7651916cd43dd8448eb211c80319c-00f067aa0ba902b7-01"
      })

    assert {:ok, %{"result" => result}} =
             MCPTest.dispatch(runtime,
               protocol: "2026-07-28",
               method: "tools/call",
               params: %{
                 "name" => "context_echo",
                 "arguments" => %{},
                 "_meta" => metadata
               }
             )

    assert result["structuredContent"]["metadata"] == metadata
    assert result["structuredContent"]["session"] == nil
    assert result["structuredContent"]["protocolVersion"] == "2026-07-28"
  end

  test "modern admission rejects missing fields and unsupported versions precisely" do
    runtime = TestFixtures.runtime()
    transport = %TransportContext{transport: :direct}

    missing_all = %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "tools/list",
      "params" => %{}
    }

    assert {:ok, %{"error" => %{"code" => -32_602}}} =
             Server.dispatch(runtime, missing_all, transport)

    missing_capabilities =
      put_in(missing_all, ["params", "_meta"], %{
        V2026_07_28.protocol_version_key() => "2026-07-28"
      })

    assert {:ok, %{"error" => %{"code" => -32_602}}} =
             Server.dispatch(runtime, missing_capabilities, transport)

    unsupported =
      put_in(missing_capabilities, ["params", "_meta"], %{
        V2026_07_28.protocol_version_key() => "1900-01-01",
        V2026_07_28.client_capabilities_key() => %{}
      })

    assert {:ok, %{"error" => unsupported_error}} =
             Server.dispatch(runtime, unsupported, transport)

    assert unsupported_error == %{
             "code" => -32_022,
             "message" => "Unsupported protocol version",
             "data" => %{
               "requested" => "1900-01-01",
               "supported" => ["2026-07-28"]
             }
           }
  end

  test "request metadata validates known fields while preserving open extension data" do
    runtime = TestFixtures.runtime()
    transport = %TransportContext{transport: :direct}
    version_key = V2026_07_28.protocol_version_key()
    capabilities_key = V2026_07_28.client_capabilities_key()
    client_info_key = V2026_07_28.client_info_key()
    base = TestFixtures.request(7, "tools/list")

    invalid_metadata = [
      Map.put(TestFixtures.metadata(), "progressToken", %{}),
      Map.put(TestFixtures.metadata(), "progressToken", 1.5),
      Map.put(TestFixtures.metadata(), "io.modelcontextprotocol/logLevel", "verbose"),
      Map.put(TestFixtures.metadata(), client_info_key, %{
        "name" => "client",
        "version" => "1",
        "title" => 7
      }),
      Map.put(TestFixtures.metadata(), client_info_key, %{
        "name" => "client",
        "version" => "1",
        "websiteUrl" => "not a uri"
      }),
      Map.put(TestFixtures.metadata(), capabilities_key, %{"sampling" => %{"tools" => true}}),
      Map.put(TestFixtures.metadata(), capabilities_key, %{"elicitation" => %{"form" => 1}}),
      Map.put(TestFixtures.metadata(), capabilities_key, %{"extensions" => %{"unprefixed" => %{}}}),
      Map.put(TestFixtures.metadata(), "bad/key/again", true),
      Map.put(TestFixtures.metadata(), "com.example/not-json", self())
    ]

    Enum.each(invalid_metadata, fn metadata ->
      raw = put_in(base, ["params", "_meta"], metadata)

      assert {:ok, %{"error" => %{"code" => -32_602}}} =
               Server.dispatch(runtime, raw, transport)
    end)

    capabilities = %{
      "experimental" => %{"free form name" => %{"enabled" => true}},
      "sampling" => %{"context" => %{}, "futureNestedField" => [1, nil]},
      "elicitation" => %{},
      "extensions" => %{"com.example/feature" => %{"mode" => "fast"}},
      "futureCapability" => 7
    }

    metadata = %{
      version_key => "2026-07-28",
      capabilities_key => capabilities,
      client_info_key => %{
        "name" => "",
        "version" => "",
        "websiteUrl" => "https://example.test/client",
        "icons" => [%{"src" => "data:image/png;base64,AA==", "theme" => "dark"}],
        "futureField" => %{"kept" => true}
      },
      "progressToken" => 1,
      "io.modelcontextprotocol/logLevel" => "debug",
      "io.modelcontextprotocol/futureField" => [1, true, nil],
      "com.example/trace" => %{"id" => "trace-1"}
    }

    assert {:ok, %{"result" => result}} =
             MCPTest.dispatch(runtime,
               protocol: "2026-07-28",
               method: "tools/call",
               params: %{
                 "name" => "context_echo",
                 "arguments" => %{},
                 "_meta" => metadata
               }
             )

    assert result["structuredContent"]["metadata"] == metadata
    assert result["structuredContent"]["clientCapabilities"] == capabilities
  end

  test "malformed pagination cursors fail instead of replaying the first page" do
    runtime = TestFixtures.runtime()

    assert {:ok, %{"error" => error}} =
             MCPTest.dispatch(runtime,
               protocol: "2026-07-28",
               method: "tools/list",
               params: %{"cursor" => "next-page"}
             )

    assert error["code"] == -32_602
    assert error["message"] == "Invalid pagination cursor"
  end

  test "applications can plug input and output JSON Schema validation" do
    input_runtime = TestFixtures.runtime(schema_validator: RejectingInputValidator)

    assert {:ok, %{"error" => input_error}} =
             MCPTest.dispatch(input_runtime,
               protocol: "2026-07-28",
               method: "tools/call",
               params: %{"name" => "echo", "arguments" => %{"text" => "hello"}}
             )

    assert input_error == %{
             "code" => -32_602,
             "message" => "Tool arguments failed schema validation"
           }

    output_runtime =
      TestFixtures.runtime(
        tools: [InvalidStructuredOutput],
        schema_validator: RequiredKeysValidator
      )

    assert {:ok, %{"error" => output_error}} =
             MCPTest.dispatch(output_runtime,
               protocol: "2026-07-28",
               method: "tools/call",
               params: %{"name" => "invalid_structured_output", "arguments" => %{}}
             )

    assert output_error == %{
             "code" => -32_603,
             "message" => "Tool output failed schema validation"
           }
  end

  test "a missing required tool argument is rejected without a schema validator" do
    # The advertised inputSchema is the contract. Enforcing it in the router
    # means the pass-through default cannot turn a client's omission into an
    # internal fault raised by the handler's own pattern match.
    runtime = TestFixtures.runtime()

    assert {:ok, %{"error" => error}} =
             MCPTest.dispatch(runtime,
               protocol: "2026-07-28",
               method: "tools/call",
               params: %{"name" => "echo", "arguments" => %{}}
             )

    assert error == %{
             "code" => -32_602,
             "message" => "Missing required tool arguments",
             "data" => %{"missing" => ["text"]}
           }
  end

  test "a plugged validator still sees arguments that satisfy the required list" do
    runtime = TestFixtures.runtime(schema_validator: RequiredKeysValidator)

    assert {:ok, %{"result" => result}} =
             MCPTest.dispatch(runtime,
               protocol: "2026-07-28",
               method: "tools/call",
               params: %{"name" => "echo", "arguments" => %{"text" => "hello"}}
             )

    assert result["isError"] == false
  end

  test "non-JSON handler escape-hatch data becomes a safe internal error" do
    runtime = TestFixtures.runtime(tools: [InvalidWireResult])

    assert {:ok, response} =
             MCPTest.dispatch(runtime,
               protocol: "2026-07-28",
               method: "tools/call",
               params: %{"name" => "invalid_wire_result", "arguments" => %{}}
             )

    assert response["error"] == %{
             "code" => -32_603,
             "message" => "Server produced an invalid result"
           }

    assert is_binary(JSON.encode!(response))
  end

  test "unknown methods, IDs, and notifications obey base JSON-RPC rules" do
    runtime = TestFixtures.runtime()
    transport = %TransportContext{transport: :direct}

    assert {:ok, %{"error" => %{"code" => -32_601}}} =
             MCPTest.dispatch(runtime,
               protocol: "2026-07-28",
               method: "acme/missing"
             )

    null_id = TestFixtures.request(1, "tools/list") |> Map.put("id", nil)

    assert {:ok, %{"error" => %{"code" => -32_600}} = null_error} =
             Server.dispatch(runtime, null_id, transport)

    assert Map.has_key?(null_error, "id")
    assert null_error["id"] == nil

    notification = TestFixtures.request(1, "tools/list") |> Map.delete("id")
    assert {:ok, nil} = Server.dispatch(runtime, notification, transport)

    floating_id = TestFixtures.request(1.5, "tools/list")

    assert {:ok, %{"id" => nil, "error" => %{"code" => -32_600}}} =
             Server.dispatch(runtime, floating_id, transport)
  end

  test "request-only tool methods cannot execute as notifications" do
    runtime = TestFixtures.runtime(tools: [NotificationProbe])
    transport = %TransportContext{transport: :direct}

    notification =
      TestFixtures.request(42, "tools/call", %{
        "name" => "notification_probe",
        "arguments" => %{"owner" => self()}
      })
      |> Map.delete("id")

    assert {:ok, nil} = Server.dispatch(runtime, notification, transport)
    refute_receive :notification_probe_called, 50
  end

  test "methods gated by an unadvertised server capability return method not found" do
    runtime = TestFixtures.runtime(tools: [])

    assert {:ok, %{"error" => %{"code" => -32_601}}} =
             MCPTest.dispatch(runtime,
               protocol: "2026-07-28",
               method: "tools/list"
             )
  end

  test "an application-supplied dialect works without core edits and only when enabled" do
    future_runtime =
      TestFixtures.runtime(
        protocols: [V2026_07_28, FutureDialect],
        tools: [Echo]
      )

    assert Registry.versions(future_runtime.protocol_registry) == ["2026-07-28", "2099-01-01"]

    params = %{
      "name" => "echo",
      "arguments" => %{"text" => "from the future"},
      "_meta" => FutureDialect.request_metadata(%{})
    }

    raw = %{"jsonrpc" => "2.0", "id" => 99, "method" => "acme/echo", "params" => params}
    transport = %TransportContext{transport: :direct}

    assert {:ok,
            %{
              "id" => 99,
              "result" => %{
                "resultType" => "complete",
                "futureValue" => "from the future"
              }
            }} = Server.dispatch(future_runtime, raw, transport)

    modern_runtime = TestFixtures.runtime(tools: [Echo])

    unsupported_metadata =
      V2026_07_28.request_metadata(%{})
      |> Map.put(V2026_07_28.protocol_version_key(), "2099-01-01")

    unsupported_raw = put_in(raw, ["params", "_meta"], unsupported_metadata)

    assert {:ok, %{"error" => %{"code" => -32_022}}} =
             Server.dispatch(modern_runtime, unsupported_raw, transport)
  end
end
