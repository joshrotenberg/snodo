defmodule Snodo.Tool do
  @moduledoc """
  Behaviour and compile-time convenience DSL for MCP tools.

  The DSL emits ordinary module functions, and schemas remain unmodified Elixir
  maps representing JSON Schema documents.

  ## Failure has two shapes, and they are not interchangeable

  `call/2` can fail in two ways, and they reach the client differently:

      # The call succeeded; the tool is reporting a bad outcome.
      # tools/call returns a result with isError: true.
      {:ok, Snodo.Result.error("hex.pm returned 503")}

      # The request itself was wrong or could not be attempted.
      # The JSON-RPC request fails with an error object and no result.
      {:error, Snodo.Error.invalid_params("version must be a semantic version")}

  The first is for anything the tool understands: an upstream service failing,
  a lookup finding nothing, a domain precondition being rejected. A client
  sees a normal response it can show a model, and one failing tool does not
  look like a broken server.

  The second escalates to the protocol. Reserve it for a request that should
  never have been dispatched.

  Arguments that are missing from the schema's `required` list, or that the
  installed validator rejects, never reach `call/2`. The router answers with
  an `isError` result naming the problem, as the 2026-07-28 tools
  specification asks, so a model can correct its call.

  For compatibility, `{:error, reason}` without an `Snodo.Error` is normalized
  into a tool error result. Prefer an explicit `Snodo.Result.error/2` for domain
  outcomes and a typed `Snodo.Error` when the JSON-RPC request must fail.

  ## Schemas are advertised, and required arguments are enforced

  `input_schema/1` is published verbatim in `tools/list`. The router enforces
  its `required` list before dispatch, so a handler may pattern match on those
  keys; a call missing one gets an `isError` result. Every other keyword is advertised but only enforced when the runtime
  installs a `Snodo.Schema.Validator`; the default is pass-through. See
  `Snodo.Schema.Validator.Basic` for the bundled common subset.

  A property may carry `"x-mcp-header": "Name"` to be mirrored into an
  `Mcp-Param-Name` header over Streamable HTTP. The annotation is checked when
  the tool compiles: see the Components guide for the rules.
  """

  alias Snodo.Context
  alias Snodo.JSONValue
  alias Snodo.Result
  alias Snodo.Tool.Definition
  alias Snodo.Transport.ParamHeaders

  @callback name() :: String.t()
  @callback description() :: String.t() | nil
  @callback input_schema() :: map()
  @callback output_schema() :: map() | nil
  @callback annotations() :: map()
  @callback call(map(), Context.t()) ::
              {:ok, Result.t() | term()} | {:error, Snodo.Error.t() | term()}

  defmacro __using__(opts) do
    name = Keyword.fetch!(opts, :name)
    description = Keyword.get(opts, :description)

    unless is_binary(name) do
      raise ArgumentError, "Snodo.Tool expects :name to be a string literal"
    end

    quote bind_quoted: [name: name, description: description] do
      @behaviour Snodo.Tool

      import Snodo.Tool,
        only: [description: 1, input_schema: 1, output_schema: 1, annotations: 1]

      Module.register_attribute(__MODULE__, :mcp_tool_name, persist: true)
      Module.register_attribute(__MODULE__, :mcp_tool_description, persist: true)
      Module.register_attribute(__MODULE__, :mcp_tool_input_schema, persist: true)
      Module.register_attribute(__MODULE__, :mcp_tool_output_schema, persist: true)
      Module.register_attribute(__MODULE__, :mcp_tool_annotations, persist: true)

      @mcp_tool_name name
      @mcp_tool_description description
      @mcp_tool_input_schema %{"type" => "object"}
      @mcp_tool_output_schema nil
      @mcp_tool_annotations %{}

      @before_compile Snodo.Tool
    end
  end

  @doc """
  Sets the description that `c:description/0` returns, replacing the
  `:description` option given to `use Snodo.Tool`.

  The value must be a string or `nil`; the router checks it on registration.
  """
  defmacro description(value) do
    quote do
      @mcp_tool_description unquote(value)
    end
  end

  @doc """
  Sets the input JSON Schema that `c:input_schema/0` returns.

  The value must be a map of JSON values with `"type" => "object"` at the
  root, and any `x-mcp-header` annotations must be valid; otherwise the module
  does not compile. Defaults to `%{"type" => "object"}`.
  """
  defmacro input_schema(value) do
    quote do
      @mcp_tool_input_schema unquote(value)
    end
  end

  @doc """
  Sets the output JSON Schema that `c:output_schema/0` returns.

  The value must be `nil` (the default) or a JSON Schema map; otherwise the
  module does not compile. When a schema is set, a call must return
  structured content (`Snodo.Result.structured/2`, a non-binary value, or a
  `Snodo.Result.raw/1` map with `"structuredContent"`) unless it returns
  `Snodo.Result.error/2` or `Snodo.Result.input_required/1`. The runtime's
  schema validator checks that content. Any other result fails the request
  with a -32603 error.
  """
  defmacro output_schema(value) do
    quote do
      @mcp_tool_output_schema unquote(value)
    end
  end

  @doc """
  Sets the tool annotations map that `c:annotations/0` returns, for example
  `%{"readOnlyHint" => true}`.

  The value must be a map of JSON values; otherwise the module does not
  compile. Defaults to `%{}`.
  """
  defmacro annotations(value) do
    quote do
      @mcp_tool_annotations unquote(value)
    end
  end

  defmacro __before_compile__(env) do
    name = Module.get_attribute(env.module, :mcp_tool_name)
    description = Module.get_attribute(env.module, :mcp_tool_description)
    input_schema = Module.get_attribute(env.module, :mcp_tool_input_schema)
    output_schema = Module.get_attribute(env.module, :mcp_tool_output_schema)
    annotations = Module.get_attribute(env.module, :mcp_tool_annotations)

    validate_compile_input_schema!(env, input_schema)
    validate_compile_output_schema!(env, output_schema)
    validate_compile_annotations!(env, annotations)

    quote do
      @impl Snodo.Tool
      def name, do: unquote(name)

      @impl Snodo.Tool
      def description, do: unquote(description)

      @impl Snodo.Tool
      def input_schema, do: unquote(Macro.escape(input_schema))

      @impl Snodo.Tool
      def output_schema, do: unquote(Macro.escape(output_schema))

      @impl Snodo.Tool
      def annotations, do: unquote(Macro.escape(annotations))
    end
  end

  @doc "Returns the protocol-neutral definition for a tool module."
  @spec definition(module()) :: Definition.t()
  def definition(tool) when is_atom(tool) do
    validate_module!(tool)

    %Definition{
      name: tool.name(),
      description: tool.description(),
      input_schema: tool.input_schema(),
      output_schema: tool.output_schema(),
      annotations: tool.annotations()
    }
  end

  @doc false
  @spec validate_module!(module()) :: :ok
  def validate_module!(tool) when is_atom(tool) do
    required = [
      name: 0,
      description: 0,
      input_schema: 0,
      output_schema: 0,
      annotations: 0,
      call: 2
    ]

    case Code.ensure_loaded(tool) do
      {:module, ^tool} -> :ok
      _ -> raise ArgumentError, "tool module #{inspect(tool)} could not be loaded"
    end

    Enum.each(required, fn {function, arity} ->
      unless function_exported?(tool, function, arity) do
        raise ArgumentError,
              "tool module #{inspect(tool)} does not export #{function}/#{arity}"
      end
    end)

    validate_definition!(tool)

    :ok
  end

  defp validate_definition!(tool) do
    validate_tool_name!(tool, tool.name())
    validate_tool_description!(tool, tool.description())
    validate_tool_input_schema!(tool, tool.input_schema())
    validate_tool_output_schema!(tool, tool.output_schema())
    validate_tool_annotations!(tool, tool.annotations())
  end

  defp validate_compile_input_schema!(env, schema) do
    unless is_map(schema) and Map.get(schema, "type") == "object" and JSONValue.valid?(schema) do
      compile_error!(env, "MCP tool input_schema must evaluate to an object-root JSON Schema map")
    end

    case ParamHeaders.annotations(schema) do
      {:ok, _annotations} -> :ok
      {:error, reason} -> compile_error!(env, "MCP tool input_schema: " <> reason)
    end
  end

  defp validate_compile_output_schema!(env, schema) do
    unless is_nil(schema) or (is_map(schema) and JSONValue.valid?(schema)) do
      compile_error!(env, "MCP tool output_schema must evaluate to nil or a JSON Schema map")
    end
  end

  defp validate_compile_annotations!(env, annotations) do
    unless is_map(annotations) and JSONValue.valid?(annotations) do
      compile_error!(env, "MCP tool annotations must evaluate to a map")
    end
  end

  @spec compile_error!(Macro.Env.t(), String.t()) :: no_return()
  defp compile_error!(env, description) do
    raise CompileError, file: env.file, line: env.line, description: description
  end

  defp validate_tool_name!(tool, name) do
    unless is_binary(name) and name != "" do
      raise ArgumentError, "tool #{inspect(tool)} must return a non-empty string name"
    end
  end

  defp validate_tool_description!(tool, description) do
    unless is_nil(description) or is_binary(description) do
      raise ArgumentError, "tool #{inspect(tool)} must return a string or nil description"
    end
  end

  defp validate_tool_input_schema!(tool, schema) do
    unless is_map(schema) and Map.get(schema, "type") == "object" and JSONValue.valid?(schema) do
      raise ArgumentError,
            "tool #{inspect(tool)} must return an object-root JSON Schema input schema"
    end

    case ParamHeaders.annotations(schema) do
      {:ok, _annotations} -> :ok
      {:error, reason} -> raise ArgumentError, "tool #{inspect(tool)} input schema: " <> reason
    end
  end

  defp validate_tool_output_schema!(tool, schema) do
    unless is_nil(schema) or (is_map(schema) and JSONValue.valid?(schema)) do
      raise ArgumentError,
            "tool #{inspect(tool)} must return a JSON Schema map or nil output schema"
    end
  end

  defp validate_tool_annotations!(tool, annotations) do
    unless is_map(annotations) and JSONValue.valid?(annotations) do
      raise ArgumentError, "tool #{inspect(tool)} must return a map of annotations"
    end
  end
end
