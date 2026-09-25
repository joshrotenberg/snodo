Code.require_file("../conformance/support/mrtr.ex", __DIR__)

defmodule SnodoTest.Conformance.MRTRFixtureTest do
  use ExUnit.Case, async: false

  alias Snodo.Router
  alias Snodo.Server
  alias Snodo.Server.Runtime
  alias Snodo.Transport.Context, as: TransportContext
  alias SnodoTest.Conformance.MRTR

  @basic "test_input_required_result_elicitation"
  @state "test_input_required_result_request_state"
  @tampered "test_input_required_result_tampered_state"
  @multi "test_input_required_result_multi_round"
  @parallel "test_input_required_result_parallel_forms"
  @url "test_input_required_result_url_consent"
  @form_caps %{"elicitation" => %{"form" => %{}}}
  @targets [
    {"tools/call", %{"name" => @basic, "arguments" => %{}}, "user_name", "name"},
    {"prompts/get", %{"name" => "test_input_required_result_prompt"}, "user_context", "context"},
    {"resources/read", %{"uri" => "z-mrtr://input-required-preview"}, "user_context", "context"}
  ]

  setup_all do
    previous = Application.fetch_env(:snodo, :conformance_mrtr_secret)
    MRTR.Workflow.configure()

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:snodo, :conformance_mrtr_secret, value)
        :error -> Application.delete_env(:snodo, :conformance_mrtr_secret)
      end
    end)

    :ok
  end

  test "registered fixtures distinguish elicitation-only coverage from unsupported scenarios" do
    result = dispatch("tools/list", %{})["result"]
    names = Enum.map(result["tools"], & &1["name"])

    for name <- [@basic, @state, @tampered, @multi, @parallel, @url], do: assert(name in names)

    for tool <- result["tools"] do
      assert is_binary(tool["description"])
      assert tool["description"] != ""
    end

    for name <- [
          "test_input_required_result_sampling",
          "test_input_required_result_list_roots",
          "test_input_required_result_multiple_inputs",
          "test_input_required_result_capabilities"
        ],
        do: refute(name in names)

    assert result["resultType"] == "complete"
    prompts = dispatch("prompts/list", %{})["result"]
    assert prompts["resultType"] == "complete"
    assert prompts["prompts"] |> hd() |> Map.fetch!("description") != ""

    [resource] = dispatch("resources/list", %{})["result"]["resources"]
    assert resource["uri"] > "test://static-text"
  end

  test "tools, prompts, and resources need a valid named answer before producing content" do
    for {method, params, id, field} <- @targets do
      first = dispatch(method, params)["result"]

      assert first["resultType"] == "input_required"

      assert first["inputRequests"] == %{
               id => %{
                 "method" => "elicitation/create",
                 "params" => %{
                   "mode" => "form",
                   "message" => "Please provide #{field}",
                   "requestedSchema" => %{
                     "type" => "object",
                     "properties" => %{field => %{"type" => "string"}},
                     "required" => [field]
                   }
                 }
               }
             }

      for key <- ["content", "contents", "messages", "ttlMs", "cacheScope"],
          do: refute(Map.has_key?(first, key))

      retry = Map.put(params, "inputResponses", %{id => accept(%{field => "Alice"})})
      final = dispatch(method, retry)["result"]
      assert final["resultType"] == "complete"
      assert JSON.encode!(final) =~ "Alice"
      refute Map.has_key?(final, "inputRequests")

      case method do
        "tools/call" ->
          assert final["content"] == [%{"type" => "text", "text" => "Hello, Alice!"}]

        "prompts/get" ->
          assert get_in(final, ["messages", Access.at(0), "content", "text"]) == "Alice"

        "resources/read" ->
          assert get_in(final, ["contents", Access.at(0), "text"]) == "Alice"
      end
    end
  end

  test "absent, empty, and wrong-key answers re-request input, but extra keys are ignored" do
    for {method, params, id, field} <- @targets do
      for responses <- [%{}, %{"wrong_key" => accept(%{"data" => "wrong"})}] do
        result = dispatch(method, Map.put(params, "inputResponses", responses))["result"]
        assert result["resultType"] == "input_required"
        assert Map.keys(result["inputRequests"]) == [id]
      end

      responses = %{
        id => accept(%{field => "correct"}),
        "unknown_extra_key" => %{"ignored" => [1, false]}
      }

      final = dispatch(method, Map.put(params, "inputResponses", responses))["result"]
      assert final["resultType"] == "complete"
      assert JSON.encode!(final) =~ "correct"
    end
  end

  test "invalid protocol envelopes and consumed form answers preserve JSON-RPC errors" do
    for {method, params, id, field} <- @targets do
      for responses <- [
            nil,
            [],
            %{id => 12_345},
            %{id => %{"action" => "unknown"}},
            %{id => %{"action" => "accept"}},
            %{id => accept(%{})},
            %{id => accept(%{field => 123})},
            %{id => %{"result" => accept(%{field => "wrapped"})}}
          ] do
        response = dispatch(method, Map.put(params, "inputResponses", responses))
        assert response["error"]["code"] == -32_602
        refute Map.has_key?(response, "result")
      end
    end
  end

  test "decline and cancel produce explicit no-operation outcomes" do
    for {method, params, id, _field} <- @targets, action <- ["decline", "cancel"] do
      retry = Map.put(params, "inputResponses", %{id => %{"action" => action}})
      result = dispatch(method, retry)["result"]
      assert result["resultType"] == "complete"
      assert JSON.encode!(result) =~ action
      refute JSON.encode!(result) =~ "Hello"
    end
  end

  test "signed state is required, checked, and scoped to the original operation" do
    for name <- [@state, @tampered] do
      first = tool(name)["result"]
      assert first["resultType"] == "input_required"
      assert Map.keys(first["inputRequests"]) == ["confirm"]
      assert is_binary(first["requestState"])
      responses = %{"confirm" => accept(%{"ok" => true})}
      retry = %{"inputResponses" => responses, "requestState" => first["requestState"]}

      final = tool(name, retry)["result"]
      assert final["resultType"] == "complete"
      assert get_in(final, ["content", Access.at(0), "text"]) =~ "state-ok"
      refute Map.has_key?(final, "requestState")

      for invalid <- [
            Map.delete(retry, "requestState"),
            Map.put(retry, "requestState", first["requestState"] <> "-TAMPERED"),
            Map.put(retry, "arguments", %{"changed" => true})
          ],
          do: assert(tool(name, invalid)["error"]["code"] == -32_602)

      other = if name == @state, do: @tampered, else: @state
      assert tool(other, retry)["error"]["code"] == -32_602
    end
  end

  test "valid state without an answer cannot falsely complete" do
    first = tool(@state)["result"]

    for responses <- [%{}, %{"wrong_key" => accept(%{"ok" => true})}] do
      second =
        tool(@state, %{"requestState" => first["requestState"], "inputResponses" => responses})[
          "result"
        ]

      assert second["resultType"] == "input_required"
      assert Map.keys(second["inputRequests"]) == ["confirm"]
    end

    invalid = %{
      "requestState" => first["requestState"],
      "inputResponses" => %{"confirm" => accept(%{"ok" => "true"})}
    }

    assert tool(@state, invalid)["error"]["code"] == -32_602
  end

  test "multiple rounds replace state and consume only the current round's answer" do
    first = tool(@multi)["result"]
    assert Map.keys(first["inputRequests"]) == ["step1"]
    second = tool(@multi, retry(first, %{"step1" => accept(%{"name" => "Alice"})}))["result"]
    assert second["resultType"] == "input_required"
    assert Map.keys(second["inputRequests"]) == ["step2"]
    refute second["requestState"] == first["requestState"]

    unanswered =
      tool(@multi, retry(second, %{"step1" => accept(%{"name" => "Mallory"})}))["result"]

    assert unanswered["resultType"] == "input_required"
    assert Map.keys(unanswered["inputRequests"]) == ["step2"]

    final =
      tool(
        @multi,
        retry(second, %{
          "step1" => accept(%{"name" => "Mallory"}),
          "step2" => accept(%{"color" => "blue"})
        })
      )["result"]

    assert final["resultType"] == "complete"

    assert get_in(final, ["content", Access.at(0), "text"]) ==
             "Hello, Alice; your favorite color is blue."
  end

  test "multiround workflows cannot skip a required step" do
    first = tool(@multi)["result"]
    no_name = tool(@multi, retry(first, %{"step2" => accept(%{"color" => "blue"})}))["result"]
    assert no_name["resultType"] == "input_required"
    assert Map.keys(no_name["inputRequests"]) == ["step1"]

    malformed = retry(first, %{"step1" => accept(%{"name" => false})})
    assert tool(@multi, malformed)["error"]["code"] == -32_602
  end

  test "partial parallel form answers survive a fresh runtime and retain only pending requests" do
    first = tool(@parallel)["result"]
    assert Enum.sort(Map.keys(first["inputRequests"])) == ["color", "name"]
    second = tool(@parallel, retry(first, %{"name" => accept(%{"name" => "Alice"})}))["result"]
    assert second["resultType"] == "input_required"
    assert Map.keys(second["inputRequests"]) == ["color"]
    refute second["requestState"] == first["requestState"]

    wrong =
      tool(@parallel, retry(second, %{"wrong_key" => accept(%{"color" => "blue"})}))["result"]

    assert Map.keys(wrong["inputRequests"]) == ["color"]

    final =
      tool(
        @parallel,
        retry(second, %{
          "name" => accept(%{"name" => "Mallory"}),
          "color" => accept(%{"color" => "blue"})
        })
      )["result"]

    assert final["resultType"] == "complete"

    assert final["content"] |> hd() |> Map.fetch!("text") |> JSON.decode!() ==
             %{"name" => "Alice", "color" => "blue"}
  end

  test "parallel forms validate both answers before completing" do
    first = tool(@parallel)["result"]
    invalid = retry(first, %{"name" => accept(%{"name" => "Alice"}), "color" => accept(%{})})
    assert tool(@parallel, invalid)["error"]["code"] == -32_602

    complete =
      retry(first, %{
        "name" => accept(%{"name" => "Alice"}),
        "color" => accept(%{"color" => "blue"})
      })

    assert tool(@parallel, complete)["result"]["resultType"] == "complete"
  end

  test "capability admission is enforced for every family and separately for URL consent" do
    for {method, params, _id, _field} <- @targets do
      for capabilities <- [%{}, %{"sampling" => %{}}, %{"elicitation" => %{"url" => %{}}}] do
        error = dispatch(method, params, capabilities)["error"]
        assert error["code"] == -32_021
        assert error["data"] == %{"requiredCapabilities" => @form_caps}
      end

      assert dispatch(method, params, %{"elicitation" => %{}})["result"]["resultType"] ==
               "input_required"
    end

    assert tool(@url)["error"]["code"] == -32_021
    url_caps = %{"elicitation" => %{"url" => %{}}}
    first = dispatch("tools/call", %{"name" => @url}, url_caps)["result"]

    assert first["inputRequests"]["visit"]["params"] == %{
             "mode" => "url",
             "message" =>
               "Preview consent only; the fixture does not navigate or perform an external operation",
             "url" => "https://example.invalid/conformance-preview"
           }

    for action <- ["accept", "decline", "cancel"] do
      params = %{"name" => @url, "inputResponses" => %{"visit" => %{"action" => action}}}
      final = dispatch("tools/call", params, url_caps)["result"]
      assert final["resultType"] == "complete"

      assert final["content"] |> hd() |> Map.fetch!("text") |> JSON.decode!() ==
               %{"consent" => action, "externalStatus" => "pending"}
    end
  end

  test "URL consent cannot complete on missing, wrong-key, or malformed responses" do
    capabilities = %{"elicitation" => %{"url" => %{}}}

    for responses <- [%{}, %{"wrong_key" => %{"action" => "accept"}}] do
      params = %{"name" => @url, "inputResponses" => responses}
      result = dispatch("tools/call", params, capabilities)["result"]
      assert result["resultType"] == "input_required"
      assert Map.keys(result["inputRequests"]) == ["visit"]
    end

    for response <- [%{}, %{"action" => "completed"}, %{"action" => "accept", "content" => []}] do
      params = %{"name" => @url, "inputResponses" => %{"visit" => response}}
      assert dispatch("tools/call", params, capabilities)["error"]["code"] == -32_602
    end
  end

  defp accept(content), do: %{"action" => "accept", "content" => content}

  defp retry(result, responses),
    do: %{"requestState" => result["requestState"], "inputResponses" => responses}

  defp tool(name, extra \\ %{}) do
    dispatch("tools/call", Map.merge(%{"name" => name, "arguments" => %{}}, extra))
  end

  # Every dispatch builds a fresh router/runtime and request ID. Only the signed
  # token carries progress; the fixture has no in-memory request continuation.
  defp dispatch(method, params, capabilities \\ @form_caps) do
    router = Enum.reduce(MRTR.tools(), Router.new(), &Router.register_tool(&2, &1))
    router = Enum.reduce(MRTR.prompts(), router, &Router.register_prompt(&2, &1))
    router = Enum.reduce(MRTR.resources(), router, &Router.register_resource(&2, &1))

    runtime =
      Runtime.new(
        router: router,
        protocols: [Snodo.Protocol.V2026_07_28],
        server_info: %{"name" => "conformance-mrtr-test", "version" => "1"}
      )

    request = %{
      "jsonrpc" => "2.0",
      "id" => System.unique_integer([:positive]),
      "method" => method,
      "params" =>
        Map.put(params, "_meta", %{
          "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
          "io.modelcontextprotocol/clientCapabilities" => capabilities
        })
    }

    assert {:ok, response} =
             Server.dispatch(runtime, request, %TransportContext{transport: :direct})

    assert response["id"] == request["id"]
    response
  end
end
