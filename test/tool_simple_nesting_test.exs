defmodule Snodo.Tool.SimpleNestingTest do
  use ExUnit.Case, async: true

  defmodule Order do
    use Snodo.Tool.Simple, name: "order", description: "Place an order"

    argument "customer", :object, required: true, description: "Who is ordering" do
      argument("id", :string, required: true)
      argument("email", :string)

      argument "address", :object, additional_properties: false do
        argument("city", :string, required: true)
        argument("postcode", :string)
      end
    end

    argument "lines", {:array, :object},
      required: true,
      min_items: 1,
      additional_properties: false do
      argument("sku", :string, required: true)
      argument("quantity", :integer, required: true, minimum: 1)
      argument("tags", {:array, :string})
    end

    argument("note", :string)

    output_schema(
      additional_properties: false,
      do:
        (
          argument("order_id", :string, required: true)

          argument "lines", {:array, :object}, required: true do
            argument("sku", :string, required: true)
            argument("price", :number)
          end
        )
    )

    @impl true
    def call(%{"lines" => lines} = arguments, _context) do
      case arguments["note"] do
        "bad output" ->
          {:ok, Snodo.Result.structured(%{"order_id" => "o-1", "lines" => [%{"price" => 1}]})}

        _other ->
          {:ok,
           Snodo.Result.structured(%{
             "order_id" => "o-1",
             "lines" => Enum.map(lines, &%{"sku" => &1["sku"], "price" => 2.5})
           })}
      end
    end
  end

  defmodule RawOrder do
    use Snodo.Tool, name: "order", description: "Place an order"

    input_schema(%{
      "type" => "object",
      "properties" => %{
        "customer" => %{
          "type" => "object",
          "description" => "Who is ordering",
          "properties" => %{
            "id" => %{"type" => "string"},
            "email" => %{"type" => "string"},
            "address" => %{
              "type" => "object",
              "properties" => %{
                "city" => %{"type" => "string"},
                "postcode" => %{"type" => "string"}
              },
              "required" => ["city"],
              "additionalProperties" => false
            }
          },
          "required" => ["id"]
        },
        "lines" => %{
          "type" => "array",
          "minItems" => 1,
          "items" => %{
            "type" => "object",
            "properties" => %{
              "sku" => %{"type" => "string"},
              "quantity" => %{"type" => "integer", "minimum" => 1},
              "tags" => %{"type" => "array", "items" => %{"type" => "string"}}
            },
            "required" => ["sku", "quantity"],
            "additionalProperties" => false
          }
        },
        "note" => %{"type" => "string"}
      },
      "required" => ["customer", "lines"]
    })

    output_schema(%{
      "type" => "object",
      "properties" => %{
        "order_id" => %{"type" => "string"},
        "lines" => %{
          "type" => "array",
          "items" => %{
            "type" => "object",
            "properties" => %{
              "sku" => %{"type" => "string"},
              "price" => %{"type" => "number"}
            },
            "required" => ["sku"]
          }
        }
      },
      "required" => ["order_id", "lines"],
      "additionalProperties" => false
    })

    @impl true
    def call(_arguments, _context), do: {:ok, Snodo.Result.structured(%{})}
  end

  defmodule OrderServer do
    use Snodo.Server,
      name: "order-server",
      version: "1.0.0",
      schema_validator: Snodo.Schema.Validator.Basic

    tool(Order)

    tool "inline_order", description: "Inline nested tool" do
      argument "items", {:array, :object}, required: true do
        argument("sku", :string, required: true)
      end

      output_schema do
        argument("count", :integer, required: true)
      end

      @impl true
      def call(%{"items" => items}, _context),
        do: {:ok, Snodo.Result.structured(%{"count" => output(items)})}

      defp output(items), do: length(items)
    end
  end

  defmodule Flat do
    use Snodo.Tool.Simple, name: "flat", additional_properties: false

    argument("query", :string, required: true, min_length: 1)
    argument("tags", {:array, :string}, unique_items: true)
    argument("filter", :object, schema: %{"properties" => %{"a" => %{"type" => "string"}}})

    @impl true
    def call(_arguments, _context), do: {:ok, "ok"}
  end

  # Helpers named like the DSL, as a tool written before nested blocks
  # existed might have. None of these names or arities are imported.
  defmodule LocalHelpers do
    use Snodo.Tool.Simple, name: "local_helpers"

    argument("value", :string, required: true)

    @impl true
    def call(%{"value" => value}, _context), do: {:ok, output(value) <> output(value, "!")}

    defp output(value), do: String.upcase(value)
    defp output(value, suffix), do: value <> suffix
    defp output_schema(value, _context), do: value
    defp argument(value, _a, _b, _c, _d), do: value

    def helpers(value), do: {output_schema(value, nil), argument(value, 1, 2, 3, 4)}
  end

  defmodule MapOutput do
    use Snodo.Tool.Simple, name: "map_output"

    output_schema(%{"type" => "string"})
    output_schema(%{"type" => "object", "properties" => %{"a" => %{"type" => "string"}}})

    @impl true
    def call(_arguments, _context), do: {:ok, %{"a" => "b"}}
  end

  defmodule NoOutput do
    use Snodo.Tool.Simple, name: "no_output"

    argument "filter", :object do
    end

    @impl true
    def call(_arguments, _context), do: {:ok, "ok"}
  end

  test "nested blocks compile to the same schemas as the raw form" do
    assert Order.input_schema() == RawOrder.input_schema()
    assert Order.output_schema() == RawOrder.output_schema()
    assert Snodo.Tool.definition(Order) == Snodo.Tool.definition(RawOrder)
  end

  test "required is collected at each level and omitted where nothing is required" do
    schema = Order.input_schema()
    assert schema["required"] == ["customer", "lines"]
    assert schema["properties"]["customer"]["required"] == ["id"]
    assert schema["properties"]["customer"]["properties"]["address"]["required"] == ["city"]
    assert schema["properties"]["lines"]["items"]["required"] == ["sku", "quantity"]
    refute Map.has_key?(schema["properties"]["lines"], "required")

    assert NoOutput.input_schema() == %{
             "type" => "object",
             "properties" => %{"filter" => %{"type" => "object", "properties" => %{}}}
           }

    assert NoOutput.output_schema() == nil
  end

  test "tools/list advertises the generated input and output schemas" do
    tools = dispatch("tools/list")["result"]["tools"]
    order = Enum.find(tools, &(&1["name"] == "order"))
    assert order["inputSchema"] == RawOrder.input_schema()
    assert order["outputSchema"] == RawOrder.output_schema()

    inline = Enum.find(tools, &(&1["name"] == "inline_order"))

    assert inline["inputSchema"]["properties"]["items"] == %{
             "type" => "array",
             "items" => %{
               "type" => "object",
               "properties" => %{"sku" => %{"type" => "string"}},
               "required" => ["sku"]
             }
           }

    assert inline["outputSchema"] == %{
             "type" => "object",
             "properties" => %{"count" => %{"type" => "integer"}},
             "required" => ["count"]
           }
  end

  test "nested arguments are validated and structured output is checked" do
    ok =
      dispatch("tools/call", %{
        "name" => "order",
        "arguments" => %{
          "customer" => %{"id" => "c-1", "address" => %{"city" => "Oslo"}},
          "lines" => [%{"sku" => "a", "quantity" => 2}]
        }
      })

    assert ok["result"]["structuredContent"] == %{
             "order_id" => "o-1",
             "lines" => [%{"sku" => "a", "price" => 2.5}]
           }

    missing_nested =
      dispatch("tools/call", %{
        "name" => "order",
        "arguments" => %{"customer" => %{}, "lines" => [%{"sku" => "a", "quantity" => 1}]}
      })

    assert %{"isError" => true, "content" => [%{"text" => text}]} = missing_nested["result"]
    assert text =~ "Invalid arguments at /customer"

    bad_item =
      dispatch("tools/call", %{
        "name" => "order",
        "arguments" => %{
          "customer" => %{"id" => "c-1"},
          "lines" => [%{"sku" => "a", "quantity" => 0}]
        }
      })

    assert %{"isError" => true, "content" => [%{"text" => text}]} = bad_item["result"]
    assert text =~ "Invalid arguments at /lines/0/quantity"

    extra_item_key =
      dispatch("tools/call", %{
        "name" => "order",
        "arguments" => %{
          "customer" => %{"id" => "c-1"},
          "lines" => [%{"sku" => "a", "quantity" => 1, "colour" => "red"}]
        }
      })

    assert %{"isError" => true} = extra_item_key["result"]

    bad_output =
      dispatch("tools/call", %{
        "name" => "order",
        "arguments" => %{
          "customer" => %{"id" => "c-1"},
          "lines" => [%{"sku" => "a", "quantity" => 1}],
          "note" => "bad output"
        }
      })

    assert bad_output["error"]["code"] == -32_603
    refute Map.has_key?(bad_output, "result")

    inline =
      dispatch("tools/call", %{
        "name" => "inline_order",
        "arguments" => %{"items" => [%{"sku" => "a"}, %{"sku" => "b"}]}
      })

    assert inline["result"]["structuredContent"] == %{"count" => 2}
  end

  test "the flat form still produces the same schema" do
    assert Flat.input_schema() == %{
             "type" => "object",
             "properties" => %{
               "query" => %{"type" => "string", "minLength" => 1},
               "tags" => %{
                 "type" => "array",
                 "items" => %{"type" => "string"},
                 "uniqueItems" => true
               },
               "filter" => %{"type" => "object", "properties" => %{"a" => %{"type" => "string"}}}
             },
             "required" => ["query"],
             "additionalProperties" => false
           }

    assert Flat.output_schema() == nil
  end

  test "output_schema still accepts a map, and a map may replace an earlier map" do
    assert MapOutput.output_schema() ==
             %{"type" => "object", "properties" => %{"a" => %{"type" => "string"}}}
  end

  test "local helpers named output, output_schema/2, and argument/5 are not captured" do
    assert LocalHelpers.call(%{"value" => "abc"}, nil) == {:ok, "ABCabc!"}
    assert LocalHelpers.helpers("v") == {"v", "v"}
    assert LocalHelpers.output_schema() == nil

    inline =
      dispatch("tools/call", %{
        "name" => "inline_order",
        "arguments" => %{"items" => [%{"sku" => "a"}]}
      })

    assert inline["result"]["structuredContent"] == %{"count" => 1}
  end

  describe "compile errors" do
    test "a block on a type that is not an object or array of objects" do
      for type <- [":string", "{:array, :string}", "%{\"type\" => \"object\"}"] do
        assert_compile_error(
          """
          argument "x", #{type} do
            argument "y", :string
          end
          """,
          ~r/argument "x" has a do block, so its type must be :object or \{:array, :object\}/
        )
      end
    end

    test "errors inside a block name the nested path" do
      assert_compile_error(
        """
        argument "customer", :object do
          argument "address", :object do
            argument "city", :string
            argument "city", :string
          end
        end
        """,
        ~r/argument "customer.address.city" is declared more than once/
      )

      assert_compile_error(
        """
        argument "lines", {:array, :object} do
          argument "sku", :string, magic: true
        end
        """,
        ~r/argument "lines.sku" received unknown options: \[:magic\]/
      )

      assert_compile_error(
        """
        output_schema do
          argument "lines", {:array, :object} do
            argument "sku", :string, required: :yes
          end
        end
        """,
        ~r/output argument "lines.sku" :required must be a boolean/
      )
    end

    test "a nested name that repeats a sibling is rejected" do
      assert_compile_error(
        """
        argument "customer", :string
        argument "customer", :object do
          argument "id", :string
        end
        """,
        ~r/argument "customer" is declared more than once/
      )
    end

    test "additional_properties is only accepted with a block, and must be a schema or boolean" do
      assert_compile_error(
        ~s|argument "x", :object, additional_properties: false|,
        ~r/unknown options: \[:additional_properties\]/
      )

      assert_compile_error(
        """
        argument "x", :object, additional_properties: "no" do
          argument "y", :string
        end
        """,
        ~r/argument "x" :additional_properties must be a schema or boolean/
      )
    end

    test "empty and non-string nested names name the enclosing argument" do
      assert_compile_error(
        """
        argument "customer", :object do
          argument "address", :object do
            argument "", :string
          end
        end
        """,
        ~r/argument names cannot be empty \(in argument "customer.address"\)/
      )

      assert_compile_error(
        """
        output_schema do
          argument :id, :string
        end
        """,
        ~r/expects a string name and keyword options, got :id \(in output_schema\)/
      )
    end

    test "schema on a block argument cannot replace what the block declares" do
      assert_compile_error(
        """
        argument "lines", {:array, :object}, schema: %{"items" => %{"type" => "string"}} do
          argument "sku", :string
        end
        """,
        ~r/argument "lines" :schema cannot set \["items"\]; its do block declares them/
      )

      assert_compile_error(
        """
        argument "customer", :object, schema: %{"properties" => %{}, "required" => []} do
          argument "id", :string
        end
        """,
        ~r/argument "customer" :schema cannot set \["properties", "required"\]/
      )
    end

    test "an output schema block cannot be nested or combined with another output schema" do
      assert_compile_error(
        """
        argument "x", :object do
          output_schema do
            argument "y", :string
          end
        end
        """,
        ~r/output_schema cannot be declared inside a block/
      )

      assert_compile_error(
        """
        output_schema do
          output_schema(%{"type" => "object"})
        end
        """,
        ~r/output_schema cannot be declared inside a block/
      )

      assert_compile_error(
        """
        output_schema do
          argument "y", :string
        end

        output_schema do
          argument "z", :string
        end
        """,
        ~r/output schema is already declared/
      )

      assert_compile_error(
        """
        output_schema(%{"type" => "object"})

        output_schema do
          argument "z", :string
        end
        """,
        ~r/output schema is already declared/
      )

      assert_compile_error(
        """
        output_schema do
          argument "z", :string
        end

        output_schema(%{"type" => "object"})
        """,
        ~r/output schema is already declared by a block/
      )
    end

    test "output schema block options are validated like the root options" do
      assert_compile_error(
        ~s|output_schema(magic: true, do: argument("y", :string))|,
        ~r/Snodo.Tool.Simple output_schema received unknown options: \[:magic\]/
      )

      assert_compile_error(
        ~s|output_schema(schema: %{"type" => "array"}, do: argument("y", :string))|,
        ~r/Snodo.Tool.Simple output_schema must produce an object schema with properties/
      )

      assert_compile_error(
        ~s|output_schema(additional_properties: false)|,
        ~r/output_schema must evaluate to nil or a JSON Schema map/
      )
    end
  end

  defp assert_compile_error(body, pattern) do
    module = "SnodoTest.SimpleNesting#{System.unique_integer([:positive])}"

    source = """
    defmodule #{module} do
      use Snodo.Tool.Simple, name: "bad"
      #{body}
      def call(_arguments, _context), do: {:ok, "ok"}
    end
    """

    assert_raise CompileError, pattern, fn -> Code.compile_string(source) end
  end

  defp dispatch(method, params \\ %{}) do
    {:ok, response} =
      Snodo.Test.dispatch(OrderServer.runtime(),
        protocol: "2026-07-28",
        method: method,
        params: params
      )

    response
  end
end
