defmodule Snodo.LegacyProtocolAcceptanceTest do
  use ExUnit.Case, async: true

  alias Snodo.Protocol.{V2025_06_18, V2025_11_25, V2026_07_28}
  alias Snodo.{Result, Router, Server}
  alias Snodo.Server.Runtime
  alias Snodo.Transport.Context, as: TransportContext
  alias Snodo.Transport.StreamableHTTP
  alias SnodoTest.TestPrompts.PackageAnalysis
  alias SnodoTest.TestResources.{PackageTemplate, StaticText}
  alias SnodoTest.TestTools.{ComplexSchema, ContextEcho, Echo, Failing, Structured}

  @protocols [V2026_07_28, V2025_11_25, V2025_06_18]

  defp runtime(opts \\ []) do
    router =
      Router.new()
      |> Router.register_tool(Echo)
      |> Router.register_tool(ContextEcho)
      |> Router.register_tool(Structured)
      |> Router.register_tool(Failing)
      |> Router.register_prompt(PackageAnalysis)
      |> Router.register_resource(StaticText)
      |> Router.register_resource(PackageTemplate)

    Runtime.new(
      Keyword.merge(
        [
          router: router,
          protocols: @protocols,
          server_info: %{"name" => "legacy-fixture", "version" => "1", "icons" => []},
          instructions: "Use the fixture."
        ],
        opts
      )
    )
  end

  defp request(method, params \\ %{}),
    do: %{"jsonrpc" => "2.0", "id" => 1, "method" => method, "params" => params}

  defp initialization(version),
    do:
      request("initialize", %{
        "protocolVersion" => version,
        "capabilities" => %{},
        "clientInfo" => %{"name" => "native", "version" => "1"}
      })

  defp dispatch(runtime, version, method, params \\ %{}),
    do: Server.dispatch(runtime, request(method, params), transport(version))

  defp transport(version),
    do: %TransportContext{
      transport: :direct,
      request_headers: %{"mcp-protocol-version" => version}
    }

  test "legacy JSON-RPC errors travel over HTTP with 200 while modern ones keep their status" do
    runtime = runtime()

    http = fn version, body ->
      headers = [
        {"content-type", "application/json"},
        {"accept", "application/json, text/event-stream"},
        {"mcp-protocol-version", version}
      ]

      headers =
        if version == "2026-07-28",
          do: headers ++ [{"mcp-method", body["method"]}, {"mcp-name", body["params"]["name"]}],
          else: headers

      response =
        StreamableHTTP.handle(runtime, %StreamableHTTP.Request{
          method: "POST",
          path: "/mcp",
          headers: headers,
          body: JSON.encode!(body),
          peer: {{127, 0, 0, 1}, 50_000},
          connection_ref: make_ref()
        })

      {response.status, JSON.decode!(response.body)}
    end

    unknown_tool = request("tools/call", %{"name" => "missing", "arguments" => %{}})
    unknown_method = request("logging/setLevel", %{"level" => "info"})

    for version <- ["2025-11-25", "2025-06-18"] do
      assert {200, %{"error" => %{"code" => -32_602}}} = http.(version, unknown_tool)
      assert {200, %{"error" => %{"code" => -32_601}}} = http.(version, unknown_method)
    end

    modern =
      put_in(unknown_tool, ["params", "_meta"], %{
        "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
        "io.modelcontextprotocol/clientCapabilities" => %{}
      })

    assert {400, %{"error" => %{"code" => -32_602}}} = http.("2026-07-28", modern)
  end

  test "legacy is opt in and unsupported initialize proposals negotiate a configured legacy version" do
    default = runtime(protocols: [V2026_07_28])

    assert {:ok, %{"error" => _}} =
             Server.dispatch(default, initialization("2025-11-25"), %TransportContext{})

    for version <- ["2025-06-18", "2025-11-25", "2024-11-05"] do
      negotiated = if version == "2024-11-05", do: "2025-11-25", else: version

      assert {:ok, %{"result" => result}} =
               Server.dispatch(runtime(), initialization(version), %TransportContext{})

      assert result["protocolVersion"] == negotiated
      assert result["capabilities"] == %{"tools" => %{}, "prompts" => %{}, "resources" => %{}}
      assert result["instructions"] == "Use the fixture."
      refute Map.has_key?(result, "resultType")
      assert Map.has_key?(result["serverInfo"], "icons") == (negotiated == "2025-11-25")
    end
  end

  test "malformed initialize and version conflicts fail without creating session state" do
    for params <- [%{}, %{"protocolVersion" => "2025-11-25"}, %{"protocolVersion" => 1}] do
      assert {:ok, %{"error" => %{"code" => -32_602}}} =
               Server.dispatch(runtime(), request("initialize", params), %TransportContext{})
    end

    assert {:ok, %{"error" => _}} =
             Server.dispatch(runtime(), initialization("2025-11-25"), transport("2025-06-18"))

    assert {:ok, %{"error" => _}} =
             dispatch(runtime(), "2025-11-25", "tools/list", %{
               "_meta" => %{
                 "io.modelcontextprotocol/protocolVersion" => "2026-07-28"
               }
             })

    assert {:ok, %{"error" => _}} =
             Server.dispatch(runtime(), request("tools/list"), %TransportContext{})
  end

  for version <- ["2025-06-18", "2025-11-25"] do
    @version version

    test "#{version} lists and calls tools without 2026-only result fields" do
      assert {:ok, %{"result" => %{"tools" => tools} = listed}} =
               dispatch(runtime(), @version, "tools/list")

      assert Enum.any?(tools, &(&1["name"] == "echo"))
      refute Map.has_key?(listed, "resultType")
      refute Map.has_key?(listed, "ttlMs")
      refute Map.has_key?(listed, "_meta")

      assert {:ok, %{"result" => %{"content" => [%{"text" => "hello"}], "isError" => false}}} =
               dispatch(runtime(), @version, "tools/call", %{
                 "name" => "echo",
                 "arguments" => %{"text" => "hello"}
               })

      assert {:ok, %{"result" => %{"structuredContent" => %{"ok" => true}}}} =
               dispatch(runtime(), @version, "tools/call", %{
                 "name" => "structured",
                 "arguments" => %{"value" => %{"ok" => true}}
               })

      assert {:ok, %{"result" => %{"isError" => true, "content" => [%{"text" => message}]}}} =
               dispatch(runtime(), @version, "tools/call", %{"name" => "failing"})

      assert message == "Actionable domain failure"

      assert {:ok, %{"error" => %{"code" => -32_602}}} =
               dispatch(runtime(), @version, "tools/call", %{"name" => "missing"})
    end

    test "#{version} reads resources, templates and prompts with legacy shapes" do
      assert {:ok, %{"result" => %{"resources" => [resource]}}} =
               dispatch(runtime(), @version, "resources/list")

      assert resource["uri"] == "test://static/readme"
      assert Map.has_key?(resource, "icons") == (@version == "2025-11-25")

      assert {:ok, %{"result" => %{"resourceTemplates" => [template]}}} =
               dispatch(runtime(), @version, "resources/templates/list")

      assert template["uriTemplate"] == "test://packages/{name}"

      assert {:ok, %{"result" => %{"contents" => [%{"text" => "# Static resource\n"}]}}} =
               dispatch(runtime(), @version, "resources/read", %{"uri" => resource["uri"]})

      assert {:ok, %{"result" => %{"prompts" => [prompt]}}} =
               dispatch(runtime(), @version, "prompts/list")

      assert prompt["name"] == "package_analysis"
      assert Map.has_key?(prompt, "icons") == (@version == "2025-11-25")

      assert {:ok, %{"result" => %{"messages" => messages}}} =
               dispatch(runtime(), @version, "prompts/get", %{
                 "name" => prompt["name"],
                 "arguments" => %{"name" => "ecto"}
               })

      assert hd(messages)["content"]["text"] =~ "ecto"
    end

    test "#{version} rejects unsupported results and malformed metadata" do
      assert {:ok, %{"error" => %{"code" => -32_603}}} =
               dispatch(runtime(), @version, "tools/call", %{
                 "name" => "structured",
                 "arguments" => %{"value" => []}
               })

      router = Router.new() |> Router.register_tool(ComplexSchema)

      assert {:ok, %{"error" => %{"code" => -32_603}}} =
               dispatch(runtime(router: router), @version, "tools/list")

      for meta <- [[], %{"progressToken" => []}] do
        assert {:ok, %{"error" => %{"code" => -32_602}}} =
                 dispatch(runtime(), @version, "tools/list", %{"_meta" => meta})
      end

      for method <- ["tasks/get", "subscriptions/listen", "resources/subscribe"] do
        assert {:ok, %{"error" => %{"code" => -32_601}}} = dispatch(runtime(), @version, method)
      end

      assert {:ok, %{"result" => %{}}} = dispatch(runtime(), @version, "ping")
      initialized = request("notifications/initialized") |> Map.delete("id")
      assert {:ok, nil} = Server.dispatch(runtime(), initialized, transport(@version))
    end

    test "#{version} list cursors preserve paging and reject cross-dialect reuse" do
      runtime = runtime(pagination: [page_size: 2])
      assert {:ok, %{"result" => first}} = dispatch(runtime, @version, "tools/list")
      assert length(first["tools"]) == 2
      assert is_binary(first["nextCursor"])

      assert {:ok, %{"result" => second}} =
               dispatch(runtime, @version, "tools/list", %{"cursor" => first["nextCursor"]})

      assert length(second["tools"]) == 2
      refute Map.has_key?(second, "nextCursor")
      refute hd(first["tools"])["name"] == hd(second["tools"])["name"]
      other = if @version == "2025-06-18", do: "2025-11-25", else: "2025-06-18"

      assert {:ok, %{"error" => %{"code" => -32_602}}} =
               dispatch(runtime, other, "tools/list", %{"cursor" => first["nextCursor"]})
    end

    test "#{version} context is request scoped with no retained client capabilities or session" do
      assert {:ok, %{"result" => %{"structuredContent" => result}}} =
               dispatch(runtime(), @version, "tools/call", %{"name" => "context_echo"})

      assert result["protocolVersion"] == @version
      assert result["session"] == nil
      assert result["clientCapabilities"] == %{}

      assert {:ok, %{"result" => _}} =
               Snodo.Test.dispatch(runtime(), protocol: @version, method: "tools/list")
    end
  end

  test "input-required results stay unavailable without legacy server request support" do
    for protocol <- [V2025_06_18, V2025_11_25] do
      assert {:error, %Snodo.Error{code: -32_603}} =
               protocol.validate_result(
                 {:tools_call, "fixture"},
                 Result.input_required(request_state: "state"),
                 nil
               )
    end
  end

  test "legacy refuses unsupported continuation requests and result payloads" do
    for key <- ["task", "inputResponses", "requestState"] do
      params = %{"name" => "structured", "arguments" => %{"value" => %{}}, key => %{}}

      assert {:ok, %{"error" => %{"code" => -32_602}}} =
               dispatch(runtime(), "2025-11-25", "tools/call", params)
    end

    for value <- [
          %{"structuredContent" => []},
          %{"isError" => 1},
          %{"content" => %{}},
          %{"inputRequests" => %{}},
          %{"task" => %{}}
        ] do
      assert {:error, %Snodo.Error{code: -32_603}} =
               V2025_11_25.validate_result({:tools_call, "fixture"}, Result.raw(value), nil)
    end
  end

  test "mixed runtime retains latest stateless discovery and result contract" do
    assert {:ok, %{"result" => result}} =
             Snodo.Test.dispatch(runtime(), protocol: "2026-07-28", method: "tools/list")

    assert result["resultType"] == "complete"

    assert {:ok, %{"result" => discovery}} =
             Snodo.Test.dispatch(runtime(), protocol: "2026-07-28", method: "server/discover")

    assert "2026-07-28" in discovery["supportedVersions"]
  end
end
