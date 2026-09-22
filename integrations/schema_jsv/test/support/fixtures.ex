defmodule MCPEx.JSV.SchemaProbe do
  @moduledoc false

  def json_schema do
    Process.put(:jsv_schema_probe_called, true)
    %{"type" => "string"}
  end
end

defmodule MCPEx.JSV.CastProbe do
  @moduledoc false

  # Raising is the point: reaching this hook means the adapter failed to reject
  # a cast, so the test asserts it is never called.
  @spec __jsv__(term(), term()) :: no_return()
  def __jsv__(_request, _builder) do
    Process.put(:jsv_cast_probe_called, true)
    raise "the adapter must reject a cast before invoking this hook"
  end
end

defmodule MCPEx.JSV.Echo do
  @moduledoc false
  use MCP.Tool, name: "echo"

  input_schema(%{
    "type" => "object",
    "$defs" => %{"count" => %{"type" => "integer"}},
    "properties" => %{
      "count" => %{"$ref" => "#/$defs/count"},
      "name" => %{"type" => "string", "default" => "do not insert"}
    },
    "unevaluatedProperties" => false,
    "x-vendor-preserved" => [true, nil, %{"nested" => 1}]
  })

  output_schema(%{
    "type" => "object",
    "properties" => %{"count" => %{"type" => "integer"}, "name" => %{"type" => "string"}},
    "unevaluatedProperties" => false
  })

  @impl true
  def call(arguments, _context) do
    Process.put(:jsv_echo_arguments, arguments)
    {:ok, MCP.Result.structured(arguments)}
  end
end

defmodule MCPEx.JSV.BadOutput do
  @moduledoc false
  use MCP.Tool, name: "bad_output"
  output_schema(%{"type" => "integer"})

  @impl true
  def call(_arguments, _context), do: {:ok, MCP.Result.structured("not an integer")}
end

defmodule MCPEx.JSV.BadSchema do
  @moduledoc false
  use MCP.Tool, name: "bad_schema"
  input_schema(%{"type" => "object", "minProperties" => -1})

  @impl true
  def call(_arguments, _context) do
    Process.put(:jsv_bad_schema_called, true)
    {:ok, MCP.Result.text("must not execute")}
  end
end

defmodule MCPEx.JSV.Server do
  @moduledoc false
  use MCP.Server,
    name: "jsv-test",
    version: "0.1.0",
    protocols: [MCP.Protocol.V2026_07_28],
    schema_validator: MCP.Schema.Validator.JSV

  tool(MCPEx.JSV.Echo)
  tool(MCPEx.JSV.BadOutput)
  tool(MCPEx.JSV.BadSchema)
end
