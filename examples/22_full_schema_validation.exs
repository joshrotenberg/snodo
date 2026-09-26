# Run from integrations/schema_jsv: mix example.jsv
# The optional backend validates canonical schemas without changing arguments.
defmodule Examples.FullSchema.Tool do
  use Snodo.Tool,
    name: "package_selection",
    description: "Validates a local package selection; performs no network requests"

  @input %{
    # An http(s) $id, not a urn:. JSV resolves a $ref against the nearest $id
    # with URI.merge/2, which before Elixir 1.19 rejected a base without an
    # authority. This project supports 1.18, so a urn: base would build here
    # and fail there.
    "$id" => "https://example.test/schemas/package-selection",
    "type" => "object",
    "$defs" => %{"package" => %{"type" => "string", "pattern" => "^[a-z][a-z0-9_]*$"}},
    "properties" => %{
      "package" => %{"$ref" => "#/$defs/package"},
      "mode" => %{"enum" => ["summary", "release"]},
      "version" => %{"type" => "string"},
      "include_docs" => %{"type" => "boolean", "default" => true}
    },
    "required" => ["package", "mode"],
    "if" => %{"properties" => %{"mode" => %{"const" => "release"}}},
    "then" => %{"required" => ["version"]},
    "unevaluatedProperties" => false
  }
  @output %{
    "$id" => "https://example.test/schemas/package-selection-result",
    "type" => "object",
    "properties" => %{"selection" => @input},
    "required" => ["selection"],
    "additionalProperties" => false
  }
  input_schema(@input)
  output_schema(@output)

  @impl true
  def call(arguments, _context), do: {:ok, Snodo.Result.structured(%{"selection" => arguments})}
end

defmodule Examples.FullSchema.Validator do
  @behaviour Snodo.Schema.Validator
  alias Snodo.Schema.Validator.JSV

  # Fixed application catalog: compiled immutable roots, no global cache.
  @schemas [Examples.FullSchema.Tool.input_schema(), Examples.FullSchema.Tool.output_schema()]
  @compiled Map.new(@schemas, fn schema ->
              {:ok, compiled} = JSV.compile(schema)
              {schema, compiled}
            end)

  @impl true
  def validate(instance, schema) do
    JSV.validate_compiled(instance, Map.fetch!(@compiled, schema))
  end
end

defmodule Examples.FullSchema.Server do
  use Snodo.Server,
    name: "full-schema-example",
    version: "1.0.0",
    protocols: [Snodo.Protocol.V2026_07_28],
    schema_validator: Examples.FullSchema.Validator

  tool(Examples.FullSchema.Tool)
end

defmodule Examples.FullSchema.Check do
  def run do
    runtime = Examples.FullSchema.Server.runtime()
    valid = %{"package" => "ecto", "mode" => "release", "version" => "3.14.0"}
    %{"result" => result} = call(runtime, valid)
    true = result["structuredContent"] == %{"selection" => valid}
    false = Map.has_key?(result["structuredContent"]["selection"], "include_docs")

    for invalid <- [
          Map.delete(valid, "version"),
          Map.put(valid, "package", "INVALID!"),
          Map.put(valid, "unexpected", true),
          Map.put(valid, "include_docs", "true")
        ] do
      # Invalid arguments are a tool error the model can read, and the
      # handler never runs.
      %{"result" => %{"isError" => true}} = call(runtime, invalid)
    end

    %{"result" => %{"tools" => [definition]}} = dispatch(runtime, "tools/list", %{})
    true = definition["inputSchema"] == Examples.FullSchema.Tool.input_schema()
    true = definition["outputSchema"] == Examples.FullSchema.Tool.output_schema()

    {:error, %Snodo.Schema.Validator.JSV.BuildError{}} =
      Snodo.Schema.Validator.JSV.compile(%{"$ref" => "https://example.invalid/no-fetch"})

    :ok
  end

  defp call(runtime, arguments) do
    dispatch(runtime, "tools/call", %{"name" => "package_selection", "arguments" => arguments})
  end

  defp dispatch(runtime, method, params) do
    metadata = %{
      "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
      "io.modelcontextprotocol/clientInfo" => %{"name" => "example", "version" => "1.0.0"},
      "io.modelcontextprotocol/clientCapabilities" => %{}
    }

    {:ok, response} =
      Snodo.Server.dispatch(
        runtime,
        %{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => method,
          "params" => Map.put(params, "_meta", metadata)
        },
        %Snodo.Transport.Context{transport: :direct}
      )

    response
  end
end

case System.argv() do
  ["--check"] ->
    :ok = Examples.FullSchema.Check.run()
    IO.puts("22_full_schema_validation: ok")

  [] ->
    :ok = Examples.FullSchema.Check.run()
    IO.puts("Compiled a fixed schema catalog with local references and conditional validation.")
    IO.puts("Rejected invalid input and remote refs; preserved arguments and advertised schemas.")

  _arguments ->
    raise "usage: mix example.jsv or mix run ../../examples/22_full_schema_validation.exs [--check]"
end
