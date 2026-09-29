defmodule Snodo.SamplingTest do
  use ExUnit.Case, async: true

  alias Snodo.Error
  alias Snodo.Prompt
  alias Snodo.Sampling

  @message %{"role" => "user", "content" => %{"type" => "text", "text" => "Capital of France?"}}
  @tool %{"name" => "lookup", "inputSchema" => %{"type" => "object"}}

  test "the builder returns a bare embedded request with only the given options" do
    assert Sampling.create_message([Prompt.message(:user, Prompt.text("Capital of France?"))],
             max_tokens: 100
           ) == %{
             "method" => "sampling/createMessage",
             "params" => %{"messages" => [@message], "maxTokens" => 100}
           }

    request =
      Sampling.create_message([@message],
        max_tokens: 50,
        system_prompt: "Answer briefly",
        model_preferences: %{"hints" => [%{"name" => "sonnet"}], "speedPriority" => 0.5},
        temperature: 0.2,
        stop_sequences: ["\n\n"],
        include_context: "none",
        metadata: %{"provider" => %{"trace" => true}},
        tools: [@tool],
        tool_choice: %{"mode" => "required"}
      )

    assert request["params"] == %{
             "messages" => [@message],
             "maxTokens" => 50,
             "systemPrompt" => "Answer briefly",
             "modelPreferences" => %{"hints" => [%{"name" => "sonnet"}], "speedPriority" => 0.5},
             "temperature" => 0.2,
             "stopSequences" => ["\n\n"],
             "includeContext" => "none",
             "metadata" => %{"provider" => %{"trace" => true}},
             "tools" => [@tool],
             "toolChoice" => %{"mode" => "required"}
           }

    assert Sampling.validate_request(request) == :ok
  end

  test "the builder rejects missing or invalid options with a reason" do
    assert_raise ArgumentError, ~r/maxTokens/, fn -> Sampling.create_message([@message], []) end

    for {option, value} <- [
          {:max_tokens, 0},
          {:max_tokens, 1.5},
          {:system_prompt, 1},
          {:model_preferences, %{"costPriority" => 2}},
          {:model_preferences, %{"hints" => [%{"name" => 1}]}},
          {:model_preferences, %{"unknown" => 1}},
          {:temperature, "hot"},
          {:stop_sequences, ["a", 1]},
          {:include_context, "everything"},
          {:metadata, []},
          {:tools, [%{"name" => "lookup"}]},
          {:tools, [%{"name" => "", "inputSchema" => %{"type" => "object"}}]},
          {:tools, [%{"name" => "x", "inputSchema" => %{"type" => "string"}}]},
          {:tool_choice, %{"mode" => "sometimes"}},
          {:tool_choice, %{"mode" => "auto", "extra" => 1}}
        ] do
      assert_raise ArgumentError, fn ->
        Sampling.create_message([@message], Keyword.put([max_tokens: 10], option, value))
      end
    end
  end

  test "messages need a role and one or more sampling content blocks" do
    text = %{"type" => "text", "text" => "hi"}
    image = %{"type" => "image", "data" => "AA==", "mimeType" => "image/png"}
    audio = %{"type" => "audio", "data" => "AA==", "mimeType" => "audio/wav"}
    use = %{"type" => "tool_use", "id" => "call-1", "name" => "lookup", "input" => %{"q" => "x"}}

    result = %{
      "type" => "tool_result",
      "toolUseId" => "call-1",
      "content" => [
        text,
        %{"type" => "resource_link", "uri" => "file:///a", "name" => "a", "size" => 1},
        %{"type" => "resource", "resource" => %{"uri" => "file:///a", "text" => "a"}},
        %{"type" => "resource", "resource" => %{"uri" => "file:///b", "blob" => "AA=="}}
      ],
      "isError" => false,
      "structuredContent" => %{"answer" => 1}
    }

    annotated = Map.put(text, "annotations", %{"audience" => ["user"], "priority" => 0.5})

    for content <- [text, image, audio, use, result, annotated, [text, image, use, result]] do
      for role <- ["user", "assistant"] do
        assert :ok = validate([%{"role" => role, "content" => content}])
      end
    end

    assert :ok = validate([Map.put(@message, "_meta", %{"com.example/trace" => "t"})])

    for message <- [
          %{},
          %{"role" => "system", "content" => text},
          %{"role" => "user"},
          %{"role" => "user", "content" => []},
          %{"role" => "user", "content" => "plain"},
          %{"role" => "user", "content" => %{"type" => "text"}},
          %{"role" => "user", "content" => %{"type" => "text", "text" => 1}},
          %{"role" => "user", "content" => %{"type" => "image", "data" => "AA=="}},
          %{
            "role" => "user",
            "content" => %{"type" => "resource_link", "uri" => "a", "name" => "a"}
          },
          %{
            "role" => "user",
            "content" => %{"type" => "resource", "resource" => %{"uri" => "a"}}
          },
          %{"role" => "user", "content" => Map.delete(use, "input")},
          %{"role" => "user", "content" => Map.put(result, "content", [use])},
          %{"role" => "user", "content" => Map.put(result, "isError", "no")},
          %{"role" => "user", "content" => Map.put(text, "annotations", %{"priority" => 2})},
          %{
            "role" => "user",
            "content" => Map.put(text, "annotations", %{"audience" => ["bot"]})
          },
          %{"role" => "user", "content" => Map.put(text, "extra", true)},
          %{"role" => "user", "content" => text, "id" => 1},
          %{"role" => "user", "content" => text, "_meta" => "bad"}
        ] do
      assert {:error, _reason} = validate([message])
    end

    assert {:error, _reason} = validate([])
    assert {:error, _reason} = validate(%{})
  end

  test "requests must be bare, use the exact method, and carry only JSON values" do
    request = Sampling.create_message([@message], max_tokens: 10)

    for key <- ["jsonrpc", "id"] do
      assert {:error, _message} = Sampling.validate_request(Map.put(request, key, 1))
    end

    assert {:error, _message} = Sampling.validate_request(%{"method" => "sampling/createMessage"})
    assert {:error, _message} = Sampling.validate_request(put_in(request, ["params", "foo"], 1))

    assert {:error, _message} =
             Sampling.validate_request(put_in(request, ["params", "metadata"], %{"a" => :atom}))

    assert {:error, _message} =
             Sampling.validate_request(Map.put(request, "method", "roots/list"))

    assert {:error, _message} = Sampling.validate_request(nil)
  end

  test "capability checks require sampling and its tools and context settings" do
    plain = Sampling.create_message([@message], max_tokens: 10)
    tools = Sampling.create_message([@message], max_tokens: 10, tools: [@tool])
    choice = Sampling.create_message([@message], max_tokens: 10, tool_choice: %{})
    context = Sampling.create_message([@message], max_tokens: 10, include_context: "allServers")
    none = Sampling.create_message([@message], max_tokens: 10, include_context: "none")

    for capabilities <- [%{}, %{"sampling" => nil}, %{"sampling" => true}, %{"roots" => %{}}] do
      refute Sampling.supported?(plain, capabilities)
    end

    assert Sampling.supported?(plain, %{"sampling" => %{}})
    assert Sampling.supported?(none, %{"sampling" => %{}})
    refute Sampling.supported?(tools, %{"sampling" => %{}})
    refute Sampling.supported?(choice, %{"sampling" => %{}})
    refute Sampling.supported?(tools, %{"sampling" => %{"tools" => false}})
    assert Sampling.supported?(tools, %{"sampling" => %{"tools" => %{}}})
    assert Sampling.supported?(choice, %{"sampling" => %{"tools" => %{}}})
    refute Sampling.supported?(context, %{"sampling" => %{"tools" => %{}}})
    assert Sampling.supported?(context, %{"sampling" => %{"context" => %{}}})
    refute Sampling.supported?(%{}, %{"sampling" => %{}})

    assert Sampling.required_capability(plain) == {"sampling", %{}}
    assert Sampling.required_capability(tools) == {"sampling", %{"tools" => %{}}}
    assert Sampling.required_capability(none) == {"sampling", %{}}

    assert Sampling.required_capability(
             Sampling.create_message([@message],
               max_tokens: 10,
               tool_choice: %{"mode" => "none"},
               include_context: "thisServer"
             )
           ) == {"sampling", %{"tools" => %{}, "context" => %{}}}
  end

  test "responses are read by ID and unrelated responses are ignored" do
    context = %{input_responses: %{"unrelated" => %{"bogus" => "not a sampling response"}}}
    assert Sampling.response(context, "summary", request()) == :missing
    assert Sampling.response(%{}, "summary", request()) == :missing

    context = put_in(context, [:input_responses, "summary"], sampled("Paris"))
    assert Sampling.response(context, "summary", request()) == {:ok, sampled("Paris")}
  end

  test "valid responses carry a role, sampling content, and a model, keeping unknown fields" do
    use = %{"type" => "tool_use", "id" => "call-1", "name" => "lookup", "input" => %{}}

    for content <- [
          %{"type" => "text", "text" => "Paris"},
          %{"type" => "image", "data" => "AA==", "mimeType" => "image/png"},
          use,
          [%{"type" => "text", "text" => "Looking up"}, use]
        ] do
      result = %{"role" => "assistant", "content" => content, "model" => "m"}
      assert reply(result) == {:ok, result}
    end

    result = Map.merge(sampled("Paris"), %{"_meta" => %{"com.example/x" => 1}, "future" => true})
    assert reply(result) == {:ok, result}

    assert reply(Map.delete(sampled("Paris"), "stopReason")) ==
             {:ok, Map.delete(sampled("Paris"), "stopReason")}
  end

  test "invalid consumed responses return generic invalid params without submitted contents" do
    for result <- [
          nil,
          %{},
          Map.delete(sampled("x"), "role"),
          Map.delete(sampled("x"), "content"),
          Map.delete(sampled("x"), "model"),
          Map.put(sampled("x"), "role", "system"),
          Map.put(sampled("x"), "model", 1),
          Map.put(sampled("x"), "stopReason", 1),
          Map.put(sampled("x"), "content", []),
          Map.put(sampled("x"), "content", %{"type" => "text", "text" => 1}),
          Map.put(sampled("x"), "content", %{
            "type" => "resource_link",
            "uri" => "a",
            "name" => "a"
          }),
          Map.put(sampled("x"), "_meta", []),
          Map.put(sampled("x"), "future", :atom)
        ] do
      assert_invalid(reply(result))
    end

    assert_invalid(Sampling.response(%{input_responses: []}, "summary", request()))
    assert_invalid(Sampling.response(nil, "summary", request()))

    # A response cannot be consumed through a request the dialect would refuse.
    bad_request = put_in(request(), ["params", "maxTokens"], 0)

    assert_invalid(
      Sampling.response(%{input_responses: %{"summary" => sampled("x")}}, "summary", bad_request)
    )
  end

  defp validate(messages) do
    Sampling.validate_request(%{
      "method" => "sampling/createMessage",
      "params" => %{"messages" => messages, "maxTokens" => 10}
    })
  end

  defp request, do: Sampling.create_message([@message], max_tokens: 10)

  defp sampled(text) do
    %{
      "role" => "assistant",
      "content" => %{"type" => "text", "text" => text},
      "model" => "test-model",
      "stopReason" => "endTurn"
    }
  end

  defp reply(result),
    do: Sampling.response(%{input_responses: %{"summary" => result}}, "summary", request())

  defp assert_invalid(result) do
    assert {:error,
            %Error{code: -32_602, message: "Invalid sampling response", data: nil, cause: nil}} =
             result
  end
end
