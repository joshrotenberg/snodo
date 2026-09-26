defmodule Snodo.Tool.Simple do
  @moduledoc """
  Opt-in argument DSL for tools with straightforward object input schemas.

  `Snodo.Tool.Simple` builds the same raw JSON Schema returned by `Snodo.Tool` and
  leaves `call/2` untouched. Argument maps therefore retain protocol-native
  string keys, and simple tools register in `Snodo.Router` exactly like raw tools.

      defmodule Search do
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
          {:ok, Snodo.Result.text("searching for \#{query} on page \#{arguments["page"] || 1}")}
        end
      end

  An argument type may be one of the JSON primitive atoms, `{:array, type}`, or
  a raw property-schema map. The `:schema` option merges arbitrary JSON Schema
  keywords into a generated property, providing a local escape hatch without
  abandoning the concise form. The raw `Snodo.Tool` DSL remains available when
  the input root itself needs complete hand-authored control.
  """

  alias Snodo.JSONValue

  @types ~w(array boolean integer null number object string)a
  @root_options [:additional_properties, :schema]

  @property_options [
    :default,
    :description,
    :enum,
    :exclusive_maximum,
    :exclusive_minimum,
    :max_items,
    :max_length,
    :maximum,
    :min_items,
    :min_length,
    :minimum,
    :pattern,
    :required,
    :schema,
    :unique_items
  ]

  @option_keys %{
    default: "default",
    description: "description",
    enum: "enum",
    exclusive_maximum: "exclusiveMaximum",
    exclusive_minimum: "exclusiveMinimum",
    max_items: "maxItems",
    max_length: "maxLength",
    maximum: "maximum",
    min_items: "minItems",
    min_length: "minLength",
    minimum: "minimum",
    pattern: "pattern",
    unique_items: "uniqueItems"
  }

  defmacro __using__(opts) do
    name = Keyword.fetch!(opts, :name)
    description = Keyword.get(opts, :description)
    root_options = Keyword.drop(opts, [:name, :description])

    quote do
      use Snodo.Tool, name: unquote(name), description: unquote(description)

      import Snodo.Tool.Simple, only: [argument: 2, argument: 3]

      @mcp_tool_input_schema Snodo.Tool.Simple.new_schema!(
                               unquote(root_options),
                               __ENV__
                             )
    end
  end

  @doc """
  Declares one property of the tool's input schema.

  `name` is the property name as a string. `type` is a JSON type atom
  (`:string`, `:integer`, `:number`, `:boolean`, `:array`, `:object`, or
  `:null`), `{:array, type}` for an array whose `"items"` has that type, or a
  raw property-schema map.

  Options:

    * `:required` - when `true`, adds `name` to the schema's `"required"`
      list. Defaults to `false`.
    * `:description`, `:default`, `:enum`, `:pattern` - set the JSON Schema
      keyword of the same name.
    * `:min_length`, `:max_length`, `:min_items`, `:max_items`, `:minimum`,
      `:maximum`, `:exclusive_minimum`, `:exclusive_maximum`, `:unique_items` -
      set the camel-case JSON Schema keyword, such as `"minLength"`.
    * `:schema` - a map of other JSON Schema keywords, merged into the
      property last, so it overrides the generated keys.

  An empty or repeated name, an unknown or repeated option, or an option
  value of the wrong type is a compile error.
  """
  defmacro argument(name, type, opts \\ []) do
    quote do
      @mcp_tool_input_schema Snodo.Tool.Simple.add_argument!(
                               @mcp_tool_input_schema,
                               unquote(name),
                               unquote(type),
                               unquote(opts),
                               __ENV__
                             )
    end
  end

  @doc false
  @spec new_schema!(keyword(), Macro.Env.t()) :: map()
  def new_schema!(opts, env) when is_list(opts) do
    validate_options!(opts, @root_options, env, "Snodo.Tool.Simple")
    validate_root_options!(opts, env)
    root_schema = Keyword.get(opts, :schema, %{})

    unless is_map(root_schema) and JSONValue.valid?(root_schema) do
      compile_error!(env, "Snodo.Tool.Simple :schema must be a JSON Schema map")
    end

    schema =
      %{"type" => "object", "properties" => %{}}
      |> Map.merge(root_schema)
      |> maybe_put_additional_properties(opts)

    unless schema["type"] == "object" and is_map(schema["properties"]) and
             valid_required?(Map.get(schema, "required", [])) and
             JSONValue.valid?(schema) do
      compile_error!(env, "Snodo.Tool.Simple must produce an object schema with properties")
    end

    schema
  end

  def new_schema!(_opts, env) do
    compile_error!(env, "Snodo.Tool.Simple options must be a keyword list")
  end

  @doc false
  @spec add_argument!(map(), String.t(), term(), keyword(), Macro.Env.t()) :: map()
  def add_argument!(root, name, type, opts, env)
      when is_map(root) and is_binary(name) and is_list(opts) do
    if name == "", do: compile_error!(env, "Snodo.Tool.Simple argument names cannot be empty")

    validate_options!(opts, @property_options, env, "Snodo.Tool.Simple argument #{inspect(name)}")
    validate_property_options!(opts, env, name)

    properties = Map.fetch!(root, "properties")

    if Map.has_key?(properties, name) do
      compile_error!(
        env,
        "Snodo.Tool.Simple argument #{inspect(name)} is declared more than once"
      )
    end

    property =
      type
      |> type_schema!(env)
      |> put_property_options(opts)
      |> merge_property_schema!(opts, env, name)

    unless JSONValue.valid?(property) do
      compile_error!(env, "Snodo.Tool.Simple argument #{inspect(name)} must produce JSON Schema")
    end

    root
    |> Map.put("properties", Map.put(properties, name, property))
    |> put_required!(name, Keyword.get(opts, :required, false), env)
  end

  def add_argument!(_root, name, _type, _opts, env) do
    compile_error!(
      env,
      "Snodo.Tool.Simple argument expects a string name and keyword options, got #{inspect(name)}"
    )
  end

  defp type_schema!(type, _env) when type in @types do
    %{"type" => Atom.to_string(type)}
  end

  defp type_schema!({:array, item_type}, env) do
    %{"type" => "array", "items" => type_schema!(item_type, env)}
  end

  defp type_schema!(schema, _env) when is_map(schema) do
    schema
  end

  defp type_schema!(type, env) do
    compile_error!(
      env,
      "Snodo.Tool.Simple argument type must be a JSON type atom, {:array, type}, or schema map; got #{inspect(type)}"
    )
  end

  defp put_property_options(property, opts) do
    Enum.reduce(@option_keys, property, fn {option, schema_key}, schema ->
      case Keyword.fetch(opts, option) do
        {:ok, value} -> Map.put(schema, schema_key, value)
        :error -> schema
      end
    end)
  end

  defp merge_property_schema!(property, opts, env, name) do
    case Keyword.get(opts, :schema, %{}) do
      schema when is_map(schema) -> Map.merge(property, schema)
      _invalid -> compile_error!(env, "argument #{inspect(name)} :schema must be a map")
    end
  end

  defp put_required!(root, _name, false, _env), do: root

  defp put_required!(root, name, true, _env) do
    Map.update(root, "required", [name], &Enum.uniq(&1 ++ [name]))
  end

  defp put_required!(_root, name, _required, env) do
    compile_error!(env, "argument #{inspect(name)} :required must be a boolean")
  end

  defp maybe_put_additional_properties(schema, opts) do
    case Keyword.fetch(opts, :additional_properties) do
      {:ok, value} -> Map.put(schema, "additionalProperties", value)
      :error -> schema
    end
  end

  defp validate_options!(opts, allowed, env, subject) do
    unless Keyword.keyword?(opts) do
      compile_error!(env, "#{subject} options must be a keyword list")
    end

    keys = Keyword.keys(opts)

    if length(keys) != length(Enum.uniq(keys)) do
      compile_error!(env, "#{subject} options cannot be repeated")
    end

    case keys |> Enum.reject(&(&1 in allowed)) |> Enum.uniq() do
      [] -> :ok
      unknown -> compile_error!(env, "#{subject} received unknown options: #{inspect(unknown)}")
    end
  end

  defp validate_root_options!(opts, env) do
    case Keyword.fetch(opts, :additional_properties) do
      :error ->
        :ok

      {:ok, value} when is_boolean(value) or is_map(value) ->
        :ok

      {:ok, _invalid} ->
        compile_error!(
          env,
          "Snodo.Tool.Simple :additional_properties must be a schema or boolean"
        )
    end
  end

  defp validate_property_options!(opts, env, name) do
    validators = [
      {:required, &is_boolean/1, "a boolean"},
      {:description, &is_binary/1, "a string"},
      {:enum, &is_list/1, "a list"},
      {:pattern, &is_binary/1, "a string"},
      {:unique_items, &is_boolean/1, "a boolean"},
      {:min_length, &non_negative_integer?/1, "a non-negative integer"},
      {:max_length, &non_negative_integer?/1, "a non-negative integer"},
      {:min_items, &non_negative_integer?/1, "a non-negative integer"},
      {:max_items, &non_negative_integer?/1, "a non-negative integer"},
      {:minimum, &is_number/1, "a number"},
      {:maximum, &is_number/1, "a number"},
      {:exclusive_minimum, &is_number/1, "a number"},
      {:exclusive_maximum, &is_number/1, "a number"}
    ]

    Enum.each(validators, &validate_property_option!(&1, opts, env, name))
  end

  defp validate_property_option!({option, valid?, expectation}, opts, env, name) do
    case Keyword.fetch(opts, option) do
      {:ok, value} ->
        unless valid?.(value) do
          compile_error!(env, "argument #{inspect(name)} :#{option} must be #{expectation}")
        end

      :error ->
        :ok
    end
  end

  defp valid_required?(required) do
    is_list(required) and Enum.all?(required, &is_binary/1) and
      length(required) == length(Enum.uniq(required))
  end

  defp non_negative_integer?(value), do: is_integer(value) and value >= 0

  @spec compile_error!(Macro.Env.t(), String.t()) :: no_return()
  defp compile_error!(env, description) do
    raise CompileError, file: env.file, line: env.line, description: description
  end
end
