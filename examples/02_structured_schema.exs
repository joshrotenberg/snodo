defmodule Examples.StructuredSchema.Validator do
  @moduledoc false

  @behaviour Snodo.Schema.Validator

  @impl true
  def validate(value, %{"x-example-role" => "input"}) do
    case value do
      %{"labels" => labels, "mode" => mode}
      when is_list(labels) and mode in ["compact", "verbose"] ->
        if labels != [] and Enum.all?(labels, &is_binary/1),
          do: :ok,
          else: {:error, :labels_must_be_nonempty_strings}

      _invalid ->
        {:error, :invalid_input}
    end
  end

  def validate(value, %{"x-example-role" => "output"}) do
    case value do
      %{"count" => count, "labels" => labels}
      when is_integer(count) and count >= 0 and is_list(labels) ->
        if count == length(labels) and Enum.all?(labels, &is_binary/1),
          do: :ok,
          else: {:error, :inconsistent_output}

      _invalid ->
        {:error, :invalid_output}
    end
  end

  def validate(_value, _schema), do: :ok
end

defmodule Examples.StructuredSchema.NormalizeLabels do
  @moduledoc false

  use Snodo.Tool,
    name: "normalize_labels",
    description: "Normalize a list of labels"

  input_schema(%{
    "$schema" => "https://json-schema.org/draft/2020-12/schema",
    "$id" => "https://example.test/schemas/normalize-labels-input",
    "$defs" => %{
      "labelList" => %{
        "type" => "array",
        "minItems" => 1,
        "items" => %{"type" => "string"}
      },
      "hasLabels" => %{
        "properties" => %{"labels" => %{"$ref" => "#/$defs/labelList"}}
      }
    },
    "type" => "object",
    "properties" => %{
      "labels" => %{"$ref" => "#/$defs/labelList"},
      "mode" => %{"oneOf" => [%{"const" => "compact"}, %{"const" => "verbose"}]}
    },
    "required" => ["labels", "mode"],
    "allOf" => [
      %{"$ref" => "#/$defs/hasLabels"},
      %{
        "if" => %{"properties" => %{"mode" => %{"const" => "verbose"}}},
        "then" => %{"minProperties" => 2}
      }
    ],
    "unevaluatedProperties" => false,
    "x-example-role" => "input",
    "x-acme-preserved" => %{"revision" => 2, "flags" => [true, nil]}
  })

  output_schema(%{
    "$schema" => "https://json-schema.org/draft/2020-12/schema",
    "type" => "object",
    "properties" => %{
      "count" => %{"type" => "integer", "minimum" => 0},
      "labels" => %{"type" => "array", "items" => %{"type" => "string"}}
    },
    "required" => ["count", "labels"],
    "additionalProperties" => false,
    "x-example-role" => "output",
    "x-acme-output" => %{"format" => "normalized-v1"}
  })

  def reset_invocations, do: Process.put({__MODULE__, :invocations}, 0)
  def invocations, do: Process.get({__MODULE__, :invocations}, 0)
  def clear_invocations, do: Process.delete({__MODULE__, :invocations})

  @impl true
  def call(%{"labels" => labels}, _context) do
    Process.put({__MODULE__, :invocations}, invocations() + 1)
    normalized = Enum.map(labels, &String.upcase/1)
    {:ok, Snodo.Result.structured(%{"count" => length(normalized), "labels" => normalized})}
  end
end

defmodule Examples.StructuredSchema.Server do
  @moduledoc false

  use Snodo.Server,
    name: "structured-schema-example",
    version: "0.1.0",
    protocols: [Snodo.Protocol.V2026_07_28]

  tool(Examples.StructuredSchema.NormalizeLabels)
end

defmodule Examples.StructuredSchema.Runner do
  @moduledoc false

  alias Examples.StructuredSchema.NormalizeLabels
  alias Examples.StructuredSchema.Server
  alias Examples.StructuredSchema.Validator

  @server_metadata %{
    "io.modelcontextprotocol/serverInfo" => %{
      "name" => "structured-schema-example",
      "version" => "0.1.0"
    }
  }

  def run(args) do
    check? = check_mode!(args)
    NormalizeLabels.reset_invocations()

    try do
      runtime = Server.runtime(schema_validator: Validator)

      {:ok, list_response} =
        Snodo.Test.dispatch(runtime,
          id: "list",
          protocol: "2026-07-28",
          method: "tools/list"
        )

      listed_tool = list_response |> get_in(["result", "tools"]) |> List.first()
      wire_tool = listed_tool |> JSON.encode!() |> JSON.decode!()

      assert_equal(wire_tool["inputSchema"], NormalizeLabels.input_schema(), "input schema")
      assert_equal(wire_tool["outputSchema"], NormalizeLabels.output_schema(), "output schema")

      {:ok, valid_response} =
        Snodo.Test.dispatch(runtime,
          id: "valid",
          protocol: "2026-07-28",
          method: "tools/call",
          params: %{
            "name" => "normalize_labels",
            "arguments" => %{"labels" => ["alpha", "beta"], "mode" => "compact"}
          }
        )

      structured = %{"count" => 2, "labels" => ["ALPHA", "BETA"]}
      assert_equal(valid_response, expected_valid(structured), "valid tools/call response")
      assert_equal(NormalizeLabels.invocations(), 1, "handler invocation count after valid input")

      {:ok, invalid_response} =
        Snodo.Test.dispatch(runtime,
          id: "invalid",
          protocol: "2026-07-28",
          method: "tools/call",
          params: %{
            "name" => "normalize_labels",
            # Both required arguments are present, so the router admits the
            # call and the application's own validator is what rejects it:
            # the schema's minItems is a constraint the required list cannot
            # express.
            "arguments" => %{"labels" => [], "mode" => "compact"}
          }
        )

      assert_equal(invalid_response, expected_invalid(), "invalid tools/call response")

      {:ok, missing_response} =
        Snodo.Test.dispatch(runtime,
          id: "missing",
          protocol: "2026-07-28",
          method: "tools/call",
          params: %{
            "name" => "normalize_labels",
            "arguments" => %{"mode" => "compact"}
          }
        )

      assert_equal(missing_response, expected_missing(), "missing-argument tools/call response")

      assert_equal(
        NormalizeLabels.invocations(),
        1,
        "handler invocation count after invalid input"
      )

      if check? do
        IO.puts("02_structured_schema: ok")
      else
        print_walkthrough(listed_tool, valid_response, invalid_response, missing_response)
      end
    after
      NormalizeLabels.clear_invocations()
    end
  end

  defp expected_valid(structured) do
    %{
      "jsonrpc" => "2.0",
      "id" => "valid",
      "result" => %{
        "resultType" => "complete",
        "content" => [%{"type" => "text", "text" => JSON.encode!(structured)}],
        "structuredContent" => structured,
        "isError" => false,
        "_meta" => @server_metadata
      }
    }
  end

  # Invalid arguments are a tool execution error the model can read and
  # correct, not a JSON-RPC error.
  defp expected_invalid do
    tool_error("invalid", "Tool arguments failed schema validation")
  end

  defp expected_missing do
    tool_error("missing", "Missing required arguments: labels")
  end

  defp tool_error(id, message) do
    %{
      "jsonrpc" => "2.0",
      "id" => id,
      "result" => %{
        "resultType" => "complete",
        "content" => [%{"type" => "text", "text" => message}],
        "isError" => true,
        "_meta" => @server_metadata
      }
    }
  end

  defp print_walkthrough(tool, valid_response, invalid_response, missing_response) do
    IO.puts("Schemas remain application-owned JSON Schema documents.\n")

    IO.puts("Preserved vocabulary: #{inspect(Map.keys(tool["inputSchema"]) |> Enum.sort())}\n")

    IO.puts("Structured result (with text compatibility content):")
    IO.puts("#{inspect(valid_response, pretty: true)}\n")
    IO.puts("Rejected by the application validator before the handler ran again:")
    IO.puts("#{inspect(invalid_response, pretty: true)}\n")
    IO.puts("Rejected by the router, which enforces the schema's required list:")
    IO.puts(inspect(missing_response, pretty: true))
  end

  defp assert_equal(actual, expected, label) do
    unless actual == expected do
      raise "#{label} mismatch\nexpected: #{inspect(expected)}\nactual:   #{inspect(actual)}"
    end
  end

  defp check_mode!([]), do: false
  defp check_mode!(["--check"]), do: true

  defp check_mode!(_arguments) do
    raise "usage: mix run examples/02_structured_schema.exs [--check]"
  end
end

Examples.StructuredSchema.Runner.run(System.argv())
