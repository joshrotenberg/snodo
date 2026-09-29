Code.require_file("../conformance/support/mrtr.ex", __DIR__)
Code.require_file("../conformance/support/stateless.ex", __DIR__)

defmodule SnodoTest.Conformance.MRTRFixtureTest do
  use ExUnit.Case, async: false

  alias Snodo.Router
  alias Snodo.Server
  alias Snodo.Server.Runtime
  alias Snodo.Transport.Context, as: TransportContext
  alias SnodoTest.Conformance.MRTR
  alias SnodoTest.Conformance.Stateless

  @basic "test_input_required_result_elicitation"
  @state "test_input_required_result_request_state"
  @tampered "test_input_required_result_tampered_state"
  @multi "test_input_required_result_multi_round"
  @parallel "test_input_required_result_parallel_forms"
  @url "test_input_required_result_url_consent"
  @sampling "test_input_required_result_sampling"
  @roots "test_input_required_result_list_roots"
  @multiple "test_input_required_result_multiple_inputs"
  @capabilities "test_input_required_result_capabilities"
  @missing "test_missing_capability"
  @form_caps %{"elicitation" => %{"form" => %{}}}
  @all_caps %{"elicitation" => %{"form" => %{}}, "sampling" => %{}, "roots" => %{}}
  @capital_question %{
    "method" => "sampling/createMessage",
    "params" => %{
      "messages" => [
        %{
          "role" => "user",
          "content" => %{"type" => "text", "text" => "What is the capital of France?"}
        }
      ],
      "maxTokens" => 100
    }
  }
  @test_root %{"roots" => [%{"uri" => "file:///test/root", "name" => "Test Root"}]}
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

  test "every alpha.11 input-required fixture is registered with a description" do
    result = dispatch("tools/list", %{})["result"]
    names = Enum.map(result["tools"], & &1["name"])

    for name <- [
          @basic,
          @state,
          @tampered,
          @multi,
          @parallel,
          @url,
          @sampling,
          @roots,
          @multiple,
          @capabilities,
          @missing
        ],
        do: assert(name in names)

    for tool <- result["tools"] do
      assert is_binary(tool["description"])
      assert tool["description"] != ""
    end

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

  test "the sampling fixture reports the sampled text and refuses undeclared sampling" do
    caps = %{"sampling" => %{}}
    first = tool(@sampling, %{}, caps)["result"]
    assert first["resultType"] == "input_required"
    assert first["inputRequests"] == %{"capital_question" => @capital_question}
    refute Map.has_key?(first, "requestState")

    responses = %{"capital_question" => sampled("The capital of France is Paris.")}
    final = tool(@sampling, %{"inputResponses" => responses}, caps)["result"]
    assert final["resultType"] == "complete"

    assert final["content"] == [
             %{
               "type" => "text",
               "text" => "Sampled by test-model: The capital of France is Paris."
             }
           ]

    for responses <- [%{}, %{"wrong_key" => sampled("Paris")}] do
      again = tool(@sampling, %{"inputResponses" => responses}, caps)["result"]
      assert again["resultType"] == "input_required"
      assert Map.keys(again["inputRequests"]) == ["capital_question"]
    end

    for response <- [
          %{},
          %{"action" => "accept", "content" => %{"answer" => "Paris"}},
          Map.delete(sampled("Paris"), "model"),
          Map.put(sampled("Paris"), "role", "system"),
          %{"result" => sampled("Paris")}
        ] do
      params = %{"inputResponses" => %{"capital_question" => response}}
      assert tool(@sampling, params, caps)["error"]["code"] == -32_602
    end

    for capabilities <- [%{}, @form_caps, %{"roots" => %{}}] do
      error = tool(@sampling, %{}, capabilities)["error"]
      assert error["code"] == -32_021
      assert error["data"] == %{"requiredCapabilities" => %{"sampling" => %{}}}
    end
  end

  test "the roots fixture reports client roots and refuses undeclared roots" do
    caps = %{"roots" => %{}}
    first = tool(@roots, %{}, caps)["result"]
    assert first["resultType"] == "input_required"

    assert first["inputRequests"] == %{
             "client_roots" => %{"method" => "roots/list", "params" => %{}}
           }

    final = tool(@roots, %{"inputResponses" => %{"client_roots" => @test_root}}, caps)["result"]
    assert final["resultType"] == "complete"

    assert final["content"] == [
             %{"type" => "text", "text" => "Client roots: Test Root (file:///test/root)"}
           ]

    unnamed = %{"roots" => [%{"uri" => "file:///a"}, %{"uri" => "file:///b"}]}
    final = tool(@roots, %{"inputResponses" => %{"client_roots" => unnamed}}, caps)["result"]

    assert final["content"] == [
             %{"type" => "text", "text" => "Client roots: file:///a, file:///b"}
           ]

    for response <- [
          %{},
          %{"roots" => [%{"uri" => "https://example.test/"}]},
          %{"roots" => [%{"name" => "missing uri"}]},
          %{"action" => "accept"}
        ] do
      params = %{"inputResponses" => %{"client_roots" => response}}
      assert tool(@roots, params, caps)["error"]["code"] == -32_602
    end

    for capabilities <- [%{}, @form_caps, %{"sampling" => %{}}] do
      error = tool(@roots, %{}, capabilities)["error"]
      assert error["code"] == -32_021
      assert error["data"] == %{"requiredCapabilities" => %{"roots" => %{}}}
    end
  end

  test "the multiple-inputs fixture carries all three kinds with signed partial progress" do
    first = tool(@multiple, %{}, @all_caps)["result"]
    assert first["resultType"] == "input_required"
    assert is_binary(first["requestState"])

    assert Enum.sort(Map.keys(first["inputRequests"])) == [
             "client_roots",
             "greeting",
             "user_name"
           ]

    assert get_in(first, ["inputRequests", "user_name", "method"]) == "elicitation/create"
    assert get_in(first, ["inputRequests", "greeting", "method"]) == "sampling/createMessage"
    assert get_in(first, ["inputRequests", "client_roots", "method"]) == "roots/list"

    second =
      tool(@multiple, retry(first, %{"user_name" => accept(%{"name" => "Alice"})}), @all_caps)[
        "result"
      ]

    assert second["resultType"] == "input_required"
    assert Enum.sort(Map.keys(second["inputRequests"])) == ["client_roots", "greeting"]
    refute second["requestState"] == first["requestState"]

    final =
      tool(
        @multiple,
        retry(second, %{
          "user_name" => accept(%{"name" => "Mallory"}),
          "greeting" => sampled("Hello there!"),
          "client_roots" => @test_root
        }),
        @all_caps
      )["result"]

    assert final["resultType"] == "complete"

    assert final["content"] |> hd() |> Map.fetch!("text") |> JSON.decode!() == %{
             "user_name" => "Alice",
             "greeting" => "Hello there!",
             "client_roots" => ["file:///test/root"]
           }

    all_at_once =
      retry(first, %{
        "user_name" => accept(%{"name" => "Alice"}),
        "greeting" => sampled("Hello there!"),
        "client_roots" => @test_root
      })

    assert tool(@multiple, all_at_once, @all_caps)["result"]["resultType"] == "complete"

    declined = retry(first, %{"user_name" => %{"action" => "decline"}})
    declined_result = tool(@multiple, declined, @all_caps)["result"]
    assert declined_result["resultType"] == "complete"
    assert declined_result["content"] |> hd() |> Map.fetch!("text") =~ "decline"

    malformed = retry(first, %{"greeting" => %{"role" => "assistant", "model" => "m"}})
    assert tool(@multiple, malformed, @all_caps)["error"]["code"] == -32_602

    assert tool(@multiple, Map.delete(all_at_once, "requestState"), @all_caps)["error"]["code"] ==
             -32_602

    error = tool(@multiple, %{}, %{})["error"]
    assert error["code"] == -32_021

    assert error["data"] == %{
             "requiredCapabilities" => %{
               "elicitation" => %{"form" => %{}},
               "sampling" => %{},
               "roots" => %{}
             }
           }

    assert tool(@multiple, %{}, @form_caps)["error"]["data"] == %{
             "requiredCapabilities" => %{"sampling" => %{}, "roots" => %{}}
           }
  end

  test "the capability fixture requests only the kinds the client declared" do
    sampling_only = tool(@capabilities, %{}, %{"sampling" => %{}})["result"]
    assert sampling_only["resultType"] == "input_required"
    assert Map.keys(sampling_only["inputRequests"]) == ["greeting"]

    assert get_in(sampling_only, ["inputRequests", "greeting", "method"]) ==
             "sampling/createMessage"

    form_only = tool(@capabilities, %{}, @form_caps)["result"]
    assert Map.keys(form_only["inputRequests"]) == ["user_name"]

    all = tool(@capabilities, %{}, @all_caps)["result"]
    assert Enum.sort(Map.keys(all["inputRequests"])) == ["client_roots", "greeting", "user_name"]

    nothing = tool(@capabilities, %{}, %{})["result"]
    assert nothing["resultType"] == "complete"

    assert nothing["content"] |> hd() |> Map.fetch!("text") |> JSON.decode!() == %{
             "declared" => [],
             "answered" => %{}
           }

    responses = %{
      "user_name" => accept(%{"name" => "Alice"}),
      "greeting" => sampled("Hello there!"),
      "client_roots" => @test_root
    }

    final = tool(@capabilities, %{"inputResponses" => responses}, @all_caps)["result"]
    assert final["resultType"] == "complete"

    assert final["content"] |> hd() |> Map.fetch!("text") |> JSON.decode!() == %{
             "declared" => ["elicitation", "roots", "sampling"],
             "answered" => %{
               "user_name" => "elicitation/create",
               "greeting" => "sampling/createMessage",
               "client_roots" => "roots/list"
             }
           }

    partial =
      tool(@capabilities, %{"inputResponses" => responses}, %{"sampling" => %{}})["result"]

    assert partial["resultType"] == "complete"

    assert partial["content"] |> hd() |> Map.fetch!("text") |> JSON.decode!() == %{
             "declared" => ["sampling"],
             "answered" => %{"greeting" => "sampling/createMessage"}
           }
  end

  test "the server-stateless diagnostic is refused with -32021 naming sampling" do
    error = tool(@missing, %{}, %{})["error"]
    assert error["code"] == -32_021
    assert error["data"] == %{"requiredCapabilities" => %{"sampling" => %{}}}

    result = tool(@missing, %{}, %{"sampling" => %{}})["result"]
    assert result["resultType"] == "input_required"
    assert result["inputRequests"] == %{"capital_question" => @capital_question}
  end

  defp accept(content), do: %{"action" => "accept", "content" => content}

  defp sampled(text) do
    %{
      "role" => "assistant",
      "content" => %{"type" => "text", "text" => text},
      "model" => "test-model",
      "stopReason" => "endTurn"
    }
  end

  defp retry(result, responses),
    do: %{"requestState" => result["requestState"], "inputResponses" => responses}

  defp tool(name, extra \\ %{}, capabilities \\ @form_caps) do
    dispatch("tools/call", Map.merge(%{"name" => name, "arguments" => %{}}, extra), capabilities)
  end

  # Every dispatch builds a fresh router/runtime and request ID. Only the signed
  # token carries progress; the fixture has no in-memory request continuation.
  defp dispatch(method, params, capabilities \\ @form_caps) do
    tools = MRTR.tools() ++ [Stateless.MissingCapability]
    router = Enum.reduce(tools, Router.new(), &Router.register_tool(&2, &1))
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
