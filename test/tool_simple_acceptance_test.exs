defmodule Snodo.Tool.SimpleAcceptanceTest do
  use ExUnit.Case, async: true

  defmodule SimpleSearch do
    use Snodo.Tool.Simple,
      name: "search",
      description: "Search packages",
      additional_properties: false

    argument("query", :string, required: true, min_length: 1)
    argument("page", :integer, minimum: 1)
    argument("sort", :string, enum: ["name", "downloads"])
    argument("tags", {:array, :string}, unique_items: true)

    @impl true
    def call(%{"query" => query} = arguments, _context) do
      {:ok,
       Snodo.Result.structured(%{
         "query" => query,
         "page" => Map.get(arguments, "page", 1),
         "sort" => Map.get(arguments, "sort")
       })}
    end
  end

  defmodule RawSearch do
    use Snodo.Tool, name: "search", description: "Search packages"

    input_schema(%{
      "type" => "object",
      "properties" => %{
        "query" => %{"type" => "string", "minLength" => 1},
        "page" => %{"type" => "integer", "minimum" => 1},
        "sort" => %{"type" => "string", "enum" => ["name", "downloads"]},
        "tags" => %{
          "type" => "array",
          "items" => %{"type" => "string"},
          "uniqueItems" => true
        }
      },
      "required" => ["query"],
      "additionalProperties" => false
    })

    @impl true
    def call(%{"query" => query} = arguments, _context) do
      {:ok,
       Snodo.Result.structured(%{
         "query" => query,
         "page" => Map.get(arguments, "page", 1),
         "sort" => Map.get(arguments, "sort")
       })}
    end
  end

  defmodule SimpleServer do
    use Snodo.Server,
      name: "equivalent-server",
      version: "1.0.0",
      schema_validator: Snodo.Schema.Validator.Basic

    tool(SimpleSearch)
  end

  defmodule RawServer do
    use Snodo.Server,
      name: "equivalent-server",
      version: "1.0.0",
      schema_validator: Snodo.Schema.Validator.Basic

    tool(RawSearch)
  end

  defmodule EscapedProperty do
    use Snodo.Tool.Simple, name: "escaped_property", schema: %{"x-root" => true}

    argument(
      "choice",
      %{"oneOf" => [%{"const" => "a"}, %{"const" => "b"}]},
      schema: %{"x-property" => [true, 7, nil]}
    )

    @impl true
    def call(arguments, _context), do: {:ok, Snodo.Result.structured(arguments)}
  end

  test "simple tools compile to the same ordinary Snodo.Tool definition as raw tools" do
    assert SimpleSearch.name() == RawSearch.name()
    assert SimpleSearch.description() == RawSearch.description()
    assert SimpleSearch.input_schema() == RawSearch.input_schema()
    assert SimpleSearch.output_schema() == RawSearch.output_schema()
    assert SimpleSearch.annotations() == RawSearch.annotations()
    assert Snodo.Tool.definition(SimpleSearch) == Snodo.Tool.definition(RawSearch)
  end

  test "raw and simple tools have equivalent list and call wire behavior" do
    simple_list = dispatch(SimpleServer.runtime(), "tools/list")
    raw_list = dispatch(RawServer.runtime(), "tools/list")
    assert get_in(simple_list, ["result", "tools"]) == get_in(raw_list, ["result", "tools"])

    params = %{
      "name" => "search",
      "arguments" => %{"query" => "ecto", "page" => 2, "sort" => "downloads"}
    }

    simple_call = dispatch(SimpleServer.runtime(), "tools/call", params)
    raw_call = dispatch(RawServer.runtime(), "tools/call", params)
    assert get_in(simple_call, ["result"]) == get_in(raw_call, ["result"])
  end

  test "simple schemas use the configured validator without wrapping call/2" do
    missing = dispatch(SimpleServer.runtime(), "tools/call", %{"name" => "search"})

    assert %{"isError" => true, "content" => [%{"text" => "Missing required arguments: query"}]} =
             missing["result"]

    invalid =
      dispatch(SimpleServer.runtime(), "tools/call", %{
        "name" => "search",
        "arguments" => %{"query" => "ecto", "page" => 0}
      })

    assert %{"isError" => true, "content" => [%{"text" => text}]} = invalid["result"]
    assert text =~ "Invalid arguments at /page"
  end

  test "property and root schema escape hatches preserve arbitrary JSON keywords" do
    schema = EscapedProperty.input_schema()
    assert schema["x-root"] == true

    assert schema["properties"]["choice"] == %{
             "oneOf" => [%{"const" => "a"}, %{"const" => "b"}],
             "x-property" => [true, 7, nil]
           }
  end

  test "invalid declarations fail at the caller with useful compile errors" do
    duplicate = """
    defmodule DuplicateSimpleArgument do
      use Snodo.Tool.Simple, name: "duplicate"
      argument("name", :string)
      argument("name", :integer)
      def call(_arguments, _context), do: {:ok, "ok"}
    end
    """

    assert_raise CompileError, ~r/declared more than once/, fn ->
      Code.compile_string(duplicate)
    end

    unknown_option = """
    defmodule UnknownSimpleOption do
      use Snodo.Tool.Simple, name: "unknown"
      argument("name", :string, magic: true)
      def call(_arguments, _context), do: {:ok, "ok"}
    end
    """

    assert_raise CompileError, ~r/unknown options: \[:magic\]/, fn ->
      Code.compile_string(unknown_option)
    end
  end

  defp dispatch(runtime, method, params \\ %{}) do
    {:ok, response} =
      Snodo.Test.dispatch(runtime,
        protocol: "2026-07-28",
        method: method,
        params: params
      )

    response
  end
end
