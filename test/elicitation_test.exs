defmodule MCP.ElicitationTest do
  use ExUnit.Case, async: true

  alias MCP.Elicitation
  alias MCP.Error

  test "builders return bare embedded requests without legacy identifiers" do
    schema = schema(%{"name" => %{"type" => "string"}})

    assert Elicitation.form("Your name?", schema) == %{
             "method" => "elicitation/create",
             "params" => %{
               "mode" => "form",
               "message" => "Your name?",
               "requestedSchema" => schema
             }
           }

    assert Elicitation.url("Connect your account", "https://example.test/connect") == %{
             "method" => "elicitation/create",
             "params" => %{
               "mode" => "url",
               "message" => "Connect your account",
               "url" => "https://example.test/connect"
             }
           }
  end

  test "omitted form mode is valid and uses implicit form-only capability" do
    request = form() |> update_in(["params"], &Map.delete(&1, "mode"))
    assert Elicitation.validate_request(request) == :ok
    assert Elicitation.supported?(request, %{"elicitation" => %{}})
    assert accepted(request, %{"name" => "Ada"}) == {:ok, accept(%{"name" => "Ada"})}
  end

  test "capability checks require the actual requested mode" do
    url = Elicitation.url("Connect", "https://example.test/connect")

    for capabilities <- [%{}, %{"elicitation" => nil}, %{"elicitation" => true}] do
      refute Elicitation.supported?(form(), capabilities)
      refute Elicitation.supported?(url, capabilities)
    end

    assert Elicitation.supported?(form(), %{"elicitation" => %{}})
    refute Elicitation.supported?(url, %{"elicitation" => %{}})
    assert Elicitation.supported?(url, %{"elicitation" => %{"url" => %{}}})
    refute Elicitation.supported?(form(), %{"elicitation" => %{"url" => %{}}})
    assert Elicitation.supported?(form(), %{"elicitation" => %{"form" => %{}}})
    refute Elicitation.supported?(form(), %{"elicitation" => %{"form" => false}})
    refute Elicitation.supported?(form(), %{"elicitation" => %{"unknown" => %{}}})
    refute Elicitation.supported?(%{}, %{"elicitation" => %{}})
  end

  test "builders reject invalid parameter and envelope shapes" do
    for message <- [nil, 1, %{}] do
      assert_raise ArgumentError, fn -> Elicitation.form(message, schema(%{})) end
    end

    for key <- ["jsonrpc", "id", "elicitationId"] do
      assert {:error, _message} = Elicitation.validate_request(Map.put(form(), key, "legacy"))
    end

    for params <- [
          %{},
          %{"mode" => "other", "message" => "Question"},
          %{"message" => "Question", "requestedSchema" => schema(%{}), "url" => "https://a.test"},
          %{
            "mode" => "url",
            "message" => "Question",
            "url" => "https://a.test",
            "elicitationId" => "x"
          }
        ] do
      assert {:error, _message} =
               Elicitation.validate_request(%{
                 "method" => "elicitation/create",
                 "params" => params
               })
    end
  end

  test "HTTP and HTTPS navigation URLs are accepted but unsafe or malformed inputs are rejected" do
    for url <- ["http://localhost:4321/connect", "https://example.test/connect?state=opaque"] do
      assert Elicitation.validate_request(Elicitation.url("Connect", url)) == :ok
    end

    for url <- [
          nil,
          "/relative",
          "javascript:alert(1)",
          "https://",
          "https://user:secret@example.test/",
          "https://example.test/has space",
          "https://example.test/%zz"
        ] do
      assert_raise ArgumentError, fn -> Elicitation.url("Connect", url) end
    end
  end

  test "only the flat elicitation schema subset is accepted" do
    for property <- [
          %{"type" => "object", "properties" => %{}},
          %{"type" => "array", "items" => %{"type" => "string"}},
          %{"type" => "null"},
          %{"type" => ["string", "null"]},
          %{"type" => "string", "pattern" => ".*"},
          %{"type" => "string", "format" => "uuid"},
          %{"type" => "number", "exclusiveMinimum" => 1},
          %{"type" => "boolean", "title" => 1},
          %{"type" => "string", "default" => nil},
          %{"type" => "string", "minLength" => -1},
          %{"type" => "string", "maxLength" => 1.5},
          %{"type" => "integer", "minimum" => 4, "maximum" => 3}
        ] do
      assert_raise ArgumentError, fn ->
        Elicitation.form("Question", schema(%{"field" => property}))
      end
    end

    for invalid <- [
          nil,
          %{"type" => "object"},
          schema(%{:name => %{"type" => "string"}}),
          Map.put(schema(%{}), "required", ["undeclared"]),
          Map.put(schema(%{}), "additionalProperties", false),
          Map.put(schema(%{}), "$schema", false)
        ] do
      assert_raise ArgumentError, fn -> Elicitation.form("Question", invalid) end
    end
  end

  test "primitive response constraints include numeric, boolean, and Unicode codepoint lengths" do
    request =
      Elicitation.form("Question", %{
        "type" => "object",
        "properties" => %{
          "name" => %{"type" => "string", "minLength" => 2, "maxLength" => 3},
          "count" => %{"type" => "integer", "minimum" => 2, "maximum" => 5},
          "enabled" => %{"type" => "boolean"}
        },
        "required" => ["name", "count", "enabled"]
      })

    content = %{"name" => "e\u0301", "count" => 3, "enabled" => true}
    assert {:ok, _response} = accepted(request, content)

    for {key, value} <- [
          {"name", "é"},
          {"name", "four"},
          {"count", 1},
          {"count", 6},
          {"count", 2.5},
          {"enabled", "yes"}
        ] do
      assert_invalid(accepted(request, Map.put(content, key, value)))
    end
  end

  test "single and multiple enums enforce values including titled options" do
    options = [%{"const" => "red", "title" => "Red"}, %{"const" => "blue", "title" => "Blue"}]

    properties = %{
      "single" => %{"type" => "string", "enum" => ["red", "blue"]},
      "legacy" => %{"type" => "string", "enum" => ["red", "blue"], "enumNames" => ["Red", "Blue"]},
      "titled" => %{"type" => "string", "oneOf" => options},
      "multi" => %{"type" => "array", "items" => %{"type" => "string", "enum" => ["red", "blue"]}},
      "multi_titled" => %{
        "type" => "array",
        "items" => %{"anyOf" => options},
        "minItems" => 1,
        "maxItems" => 2
      }
    }

    request = Elicitation.form("Choose", schema(properties))

    valid = %{
      "single" => "red",
      "legacy" => "blue",
      "titled" => "red",
      "multi" => ["blue"],
      "multi_titled" => ["red", "blue"]
    }

    assert {:ok, _response} = accepted(request, valid)

    for {name, property} <- properties do
      invalid = if property["type"] == "array", do: ["green"], else: "green"
      assert_invalid(accepted(request, Map.put(valid, name, invalid)))
    end

    assert_invalid(accepted(request, Map.put(valid, "multi_titled", [])))
    assert_invalid(accepted(request, Map.put(valid, "multi_titled", ["red", "blue", "red"])))
  end

  test "enum schema structure is checked before Basic's composition lowering" do
    for property <- [
          %{"type" => "string", "enum" => []},
          %{"type" => "string", "enum" => ["same", "same"]},
          %{"type" => "string", "enum" => [1]},
          %{"type" => "string", "enum" => ["a"], "enumNames" => []},
          %{"type" => "string", "oneOf" => [%{"const" => "a"}]},
          %{
            "type" => "string",
            "oneOf" => [%{"const" => "a", "title" => "A", "type" => "string"}]
          },
          %{"type" => "string", "oneOf" => [%{"const" => "a", "title" => "A"}], "enum" => ["a"]},
          %{"type" => "array", "items" => %{"anyOf" => []}},
          %{"type" => "array", "items" => %{"anyOf" => [%{"const" => 1, "title" => "One"}]}},
          %{"type" => "string", "enum" => ["a"], "default" => "b"}
        ] do
      assert_raise ArgumentError, fn ->
        Elicitation.form("Choose", schema(%{"field" => property}))
      end
    end
  end

  test "supported formats are explicitly checked without remote verification" do
    for {format, valid, invalid} <- [
          {"email", "ada@example.test", "not-an-email"},
          {"uri", "urn:example:package", "/relative"},
          {"date", "2024-02-29", "2023-02-29"},
          {"date-time", "2026-09-14T12:34:56+01:00", "2026-09-14T12:34:56"}
        ] do
      request =
        Elicitation.form(
          "Question",
          schema(%{"field" => %{"type" => "string", "format" => format}})
        )

      assert {:ok, _response} = accepted(request, %{"field" => valid})
      assert_invalid(accepted(request, %{"field" => invalid}))
    end
  end

  test "responses are read by ID and unrelated responses are ignored" do
    context = %{input_responses: %{"unrelated" => %{"bogus" => "not an elicitation response"}}}
    assert Elicitation.response(context, "name", form()) == :missing
    assert Elicitation.response(%{}, "name", form()) == :missing

    context = put_in(context, [:input_responses, "name"], accept(%{"name" => "Ada"}))
    assert Elicitation.response(context, "name", form()) == {:ok, accept(%{"name" => "Ada"})}
  end

  test "invalid consumed responses return generic invalid params without submitted contents" do
    for result <- [
          nil,
          %{},
          %{"action" => "other"},
          %{"action" => "accept", "content" => nil},
          accept(%{"name" => %{"nested" => "private"}}),
          accept(%{"name" => [1]}),
          accept(%{"name" => nil}),
          accept(%{"name" => "private", "extra" => %{"nested" => true}}),
          Map.put(accept(%{"name" => "private"}), "extra", :invalid)
        ] do
      assert_invalid(reply(form(), result))
    end

    assert_invalid(Elicitation.response(%{input_responses: []}, "name", form()))
  end

  test "accepted content validates required fields but omitted optional content is allowed" do
    assert_invalid(reply(form(), %{"action" => "accept"}))
    request = Elicitation.form("Optional name", schema(%{"name" => %{"type" => "string"}}))
    assert reply(request, %{"action" => "accept"}) == {:ok, %{"action" => "accept"}}
  end

  test "decline and cancel are distinct and don't validate optional content against the form" do
    for action <- ["decline", "cancel"] do
      assert reply(form(), %{"action" => action}) == {:ok, %{"action" => action}}
      result = %{"action" => action, "content" => %{"unused" => true}}
      assert reply(form(), result) == {:ok, result}
      assert_invalid(reply(form(), %{"action" => action, "content" => %{"bad" => %{}}}))
    end
  end

  test "URL acceptance is returned as consent without deriving completion from content" do
    request = Elicitation.url("Connect", "https://example.test/connect")

    for action <- ["accept", "decline", "cancel"] do
      result = %{"action" => action}
      assert reply(request, result) == {:ok, result}
    end

    result = %{"action" => "accept", "content" => %{"complete" => true}}
    assert reply(request, result) == {:ok, result}
  end

  test "unknown JSON result fields and flat content properties are preserved" do
    result = %{
      "action" => "accept",
      "content" => %{"name" => "Ada", "extra" => ["one"]},
      "future" => %{"field" => true}
    }

    assert reply(form(), result) == {:ok, result}
  end

  defp schema(properties), do: %{"type" => "object", "properties" => properties}

  defp form do
    Elicitation.form(
      "Name?",
      Map.put(schema(%{"name" => %{"type" => "string"}}), "required", ["name"])
    )
  end

  defp accept(content), do: %{"action" => "accept", "content" => content}
  defp accepted(request, content), do: reply(request, accept(content))

  defp reply(request, result),
    do: Elicitation.response(%{input_responses: %{"name" => result}}, "name", request)

  defp assert_invalid(result) do
    assert {:error,
            %Error{code: -32_602, message: "Invalid elicitation response", data: nil, cause: nil}} =
             result
  end
end
