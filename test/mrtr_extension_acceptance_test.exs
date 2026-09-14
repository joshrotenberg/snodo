defmodule MCP.MRTR.ExtensionAcceptanceTest do
  use ExUnit.Case, async: true

  alias MCP.Protocol.V2026_07_28
  alias MCP.Router
  alias MCP.Server
  alias MCP.Server.Runtime
  alias MCP.Transport.Context, as: TransportContext
  alias MCPEx.MRTR.AroundExtension
  alias MCPEx.MRTR.ObservedTool
  alias MCPEx.MRTR.Server, as: ChoiceServer

  @form_caps %{"elicitation" => %{"form" => %{}}}
  @tool_params %{"name" => "observed_choice", "arguments" => %{}}

  @tag mcp_contract: ["mrtr-extension-composition"]
  test "advertised middleware runs anew on each retry and derived context reaches the handler" do
    runtime = runtime(:observe)

    assert dispatch(runtime, request(1, "tools/call", @tool_params))["result"]["resultType"] ==
             "input_required"

    assert_receive {:mrtr_around, 1, {:tools_call, "observed_choice"}, initial_params,
                    initial_context}

    assert initial_params["name"] == "observed_choice"
    assert initial_context.input_responses == %{}
    assert initial_context.request_state == nil
    assert initial_context.request_method == "tools/call"
    assert initial_context.request_params == initial_params

    assert_receive {:mrtr_tool, 1, %{}, first_tool_context}
    assert first_tool_context.metadata["mrtrMark"] == "seen-1"
    assert first_tool_context.request_params == initial_params
    assert_receive {:mrtr_around_returned, 1, {:ok, %MCP.Result{kind: :input_required}}}

    responses = %{"choice" => %{"action" => "accept", "content" => %{"label" => "chosen"}}}

    retry_params =
      Map.merge(@tool_params, %{"requestState" => "opaque-state", "inputResponses" => responses})

    client_caps = Map.put(@form_caps, "extensions", %{AroundExtension.id() => %{}})
    retry = dispatch(runtime, request(2, "tools/call", retry_params, client_caps))

    assert retry["result"]["resultType"] == "complete"

    assert retry["result"]["structuredContent"] == %{
             "label" => "chosen",
             "middlewareMark" => "seen-2"
           }

    assert_receive {:mrtr_around, 2, {:tools_call, "observed_choice"}, observed_retry_params,
                    retry_context}

    assert retry_context.request_state == "opaque-state"
    assert retry_context.input_responses == responses
    assert retry_context.request_params == observed_retry_params
    assert Map.has_key?(retry_context.extensions, AroundExtension.id())
    assert_receive {:mrtr_tool, 2, %{}, second_tool_context}
    assert second_tool_context.request_state == "opaque-state"
    assert second_tool_context.input_responses == responses
    assert second_tool_context.metadata["mrtrMark"] == "seen-2"
    assert_receive {:mrtr_around_returned, 2, {:ok, %MCP.Result{kind: :structured}}}
  end

  test "extension guard protocol errors are preserved on initial calls and retries" do
    runtime = runtime(:guard)

    for id <- [1, 2] do
      params = Map.put(@tool_params, "requestState", "attempt-#{id}")
      response = dispatch(runtime, request(id, "tools/call", params))

      assert response["error"] == %{
               "code" => -32_602,
               "message" => "MRTR extension guard rejected the retry",
               "data" => %{"guard" => true}
             }

      refute Map.has_key?(response, "result")
      assert_receive {:mrtr_around, ^id, {:tools_call, "observed_choice"}, _params, _context}
      assert_receive {:mrtr_around_returned, ^id, {:error, %MCP.Error{code: -32_602}}}
      refute_receive {:mrtr_tool, ^id, _arguments, _context}
    end
  end

  @tag mcp_contract: ["mrtr-extension-composition"]
  test "forging stronger next-context capabilities cannot bypass the original peer admission" do
    response = dispatch(runtime(:forge), request(1, "tools/call", @tool_params, %{}))
    assert_missing_capability(response)
    assert_receive {:mrtr_tool, 1, %{}, context}
    assert context.client_capabilities == @form_caps
    assert_receive {:mrtr_around_returned, 1, {:ok, %MCP.Result{kind: :input_required}}}
  end

  @tag mcp_contract: ["mrtr-extension-composition"]
  test "wire escape results also use original peer capabilities after middleware returns" do
    response = dispatch(runtime(:forge_wire), request(1, "tools/call", @tool_params, %{}))
    assert_missing_capability(response)
    assert_receive {:mrtr_tool, 1, %{}, context}
    assert context.client_capabilities == @form_caps
    assert_receive {:mrtr_around_returned, 1, {:ok, %MCP.Result{kind: :wire}}}
  end

  @tag mcp_contract: ["mrtr-extension-composition"]
  test "middleware cannot return input-required for list or discovery operations at actual dispatch" do
    assert_unsupported_placements(:replace)
  end

  @tag mcp_contract: ["mrtr-extension-composition"]
  test "wire escape results cannot bypass actual dispatch placement checks" do
    assert_unsupported_placements(:replace_wire)
  end

  test "custom extension routes retain negotiation and do not become embedded input request methods" do
    runtime = runtime(:custom_input)
    method = AroundExtension.id()

    assert dispatch(runtime, request(1, method, %{}))["error"]["code"] == -32_601
    client_caps = Map.put(@form_caps, "extensions", %{method => %{}})

    assert %{"result" => %{"value" => %{"operation" => ":test_extension_operation"}}} =
             dispatch(runtime, request(2, method, %{}, client_caps))

    refute_receive {:mrtr_around, _id, _operation, _params, _context}

    response = dispatch(runtime, request(3, "tools/call", @tool_params, client_caps))
    assert response["error"]["code"] == -32_603
    refute Map.has_key?(response, "result")
    assert_receive {:mrtr_around, 3, {:tools_call, "observed_choice"}, _params, _context}
  end

  defp assert_unsupported_placements(mode) do
    runtime = runtime(mode)

    for {method, index} <-
          Enum.with_index(
            ~w(tools/list resources/list resources/templates/list prompts/list server/discover),
            1
          ) do
      response = dispatch(runtime, request(index, method, %{}))
      assert response["error"]["code"] == -32_603
      refute Map.has_key?(response, "result")
      assert_receive {:mrtr_around, ^index, _operation, _params, _context}
      assert_receive {:mrtr_around_returned, ^index, {:ok, %MCP.Result{}}}
    end
  end

  defp assert_missing_capability(response) do
    assert response["error"] == %{
             "code" => -32_021,
             "message" => "Missing required client capability",
             "data" => %{"requiredCapabilities" => @form_caps}
           }

    refute Map.has_key?(response, "result")
  end

  defp runtime(mode) do
    original = ChoiceServer.runtime()

    Runtime.new(
      router: Router.register_tool(original.router, ObservedTool),
      protocols: [V2026_07_28],
      server_info: %{"name" => "mrtr-extension-acceptance", "version" => "1"},
      extensions: [{AroundExtension, owner: self(), mode: mode}],
      capabilities: Map.put(original.capabilities, "extensions", %{AroundExtension.id() => %{}})
    )
  end

  defp request(id, method, params, capabilities \\ @form_caps) do
    %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => method,
      "params" =>
        Map.put(params, "_meta", %{
          "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
          "io.modelcontextprotocol/clientCapabilities" => capabilities
        })
    }
  end

  defp dispatch(runtime, raw) do
    assert {:ok, response} = Server.dispatch(runtime, raw, %TransportContext{transport: :direct})
    response
  end
end
