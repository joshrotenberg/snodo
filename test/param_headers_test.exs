defmodule Snodo.Transport.ParamHeadersTest do
  use ExUnit.Case, async: true

  alias Snodo.Transport.ParamHeaders

  defp object(properties), do: %{"type" => "object", "properties" => properties}
  defp header(type, name), do: %{"type" => type, "x-mcp-header" => name}

  describe "annotations/1" do
    test "collects top-level and nested annotations with their argument paths" do
      schema =
        object(%{
          "region" => header("string", "Region"),
          "target" => object(%{"zone" => header("integer", "Zone")}),
          "query" => %{"type" => "string"}
        })

      assert {:ok, annotations} = ParamHeaders.annotations(schema)

      assert Enum.sort_by(annotations, & &1.name) == [
               %{name: "Region", path: ["region"], type: "string"},
               %{name: "Zone", path: ["target", "zone"], type: "integer"}
             ]

      assert {:ok, []} = ParamHeaders.annotations(object(%{"query" => %{"type" => "string"}}))
    end

    test "rejects the annotations the official conformance suite marks invalid" do
      invalid = [
        {object(%{"value" => header("string", "")}), "must not be empty"},
        {object(%{"data" => header("object", "Data")}), "requires type"},
        {object(%{"items" => header("array", "Items")}), "requires type"},
        {object(%{"nil" => header("null", "Nil")}), "requires type"},
        {object(%{"n" => header("number", "N")}), "requires type"},
        {object(%{"t" => %{"x-mcp-header" => "T"}}), "requires type"},
        {object(%{"a" => header("string", "Region"), "b" => header("string", "Region")}),
         "more than once"},
        {object(%{"a" => header("string", "MyField"), "b" => header("string", "myfield")}),
         "more than once"},
        {object(%{"value" => header("string", "My Region")}), "not a valid header name"},
        {object(%{"value" => header("string", "Region:Primary")}), "not a valid header name"},
        {object(%{"value" => header("string", "Région")}), "not a valid header name"},
        {object(%{"value" => header("string", "Region\t1")}), "not a valid header name"},
        {object(%{"value" => header("string", 7)}), "must be a string"}
      ]

      for {schema, reason} <- invalid do
        assert {:error, message} = ParamHeaders.annotations(schema)
        assert message =~ reason
      end
    end

    test "rejects annotations not reached through properties alone" do
      misplaced = [
        Map.put(object(%{}), "x-mcp-header", "Root"),
        object(%{"list" => %{"type" => "array", "items" => header("string", "Item")}}),
        object(%{"choice" => %{"oneOf" => [header("string", "Choice")]}}),
        Map.put(object(%{}), "$defs", %{"region" => header("string", "Region")})
      ]

      for schema <- misplaced do
        assert {:error, "x-mcp-header is only allowed on properties" <> _rest} =
                 ParamHeaders.annotations(schema)
      end
    end

    test "ignores the keyword inside data keywords" do
      schema =
        object(%{
          "region" => Map.put(header("string", "Region"), "default", %{"x-mcp-header" => "x"})
        })

      assert {:ok, [%{name: "Region"}]} = ParamHeaders.annotations(schema)
    end
  end

  test "plain_value/1 renders primitives and skips null and structured values" do
    assert ParamHeaders.plain_value("us-west1") == "us-west1"
    assert ParamHeaders.plain_value("") == ""
    assert ParamHeaders.plain_value(42) == "42"
    assert ParamHeaders.plain_value(false) == "false"
    assert ParamHeaders.plain_value(nil) == nil
    assert ParamHeaders.plain_value(%{"a" => 1}) == nil
  end

  test "matches?/2 compares strings exactly, booleans by name, and numbers numerically" do
    assert ParamHeaders.matches?("us-west1", "us-west1")
    refute ParamHeaders.matches?("US-WEST1", "us-west1")
    assert ParamHeaders.matches?("true", true)
    refute ParamHeaders.matches?("True", true)
    assert ParamHeaders.matches?("42", 42)
    assert ParamHeaders.matches?("42.0", 42)
    refute ParamHeaders.matches?("42abc", 42)
  end

  test "a tool with an invalid annotation does not compile" do
    source = """
    defmodule SnodoTest.InvalidHeaderTool do
      use Snodo.Tool, name: "invalid_header"
      input_schema(%{"type" => "object", "properties" => %{"v" => %{"type" => "string", "x-mcp-header" => "A B"}}})
      @impl true
      def call(_arguments, _context), do: {:ok, Snodo.Result.text("never")}
    end
    """

    assert_raise CompileError, ~r/not a valid header name token/, fn ->
      Code.compile_string(source)
    end
  end

  defmodule HandWritten do
    @moduledoc false
    def name, do: "hand_written"
    def description, do: nil

    def input_schema,
      do: %{
        "type" => "object",
        "properties" => %{"v" => %{"type" => "object", "x-mcp-header" => "V"}}
      }

    def output_schema, do: nil
    def annotations, do: %{}
    def call(_arguments, _context), do: {:ok, Snodo.Result.text("never")}
  end

  test "registration refuses a hand-written tool with an invalid annotation" do
    assert_raise ArgumentError, ~r/requires type string, integer, or boolean/, fn ->
      Snodo.Router.register_tool(Snodo.Router.new(), HandWritten)
    end
  end
end
