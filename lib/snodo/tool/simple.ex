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

  An `:object` or `{:array, :object}` argument may take a `do` block of
  further `argument` declarations, which become the properties of that object
  or of each array item. `output_schema/1` with a `do` block builds the output
  schema from the same declarations:

      defmodule Order do
        use Snodo.Tool.Simple, name: "order", description: "Place an order"

        argument "customer", :object, required: true do
          argument "id", :string, required: true
          argument "email", :string
        end

        argument "lines", {:array, :object}, required: true, min_items: 1 do
          argument "sku", :string, required: true
          argument "quantity", :integer, required: true, minimum: 1
        end

        output_schema do
          argument "order_id", :string, required: true
          argument "total", :number, required: true
        end

        @impl true
        def call(_arguments, _context) do
          {:ok, Snodo.Result.structured(%{"order_id" => "o-1", "total" => 12.5})}
        end
      end

  Both compile to plain JSON Schema maps, the same ones `Snodo.Tool.input_schema/1`
  and `Snodo.Tool.output_schema/1` accept.

  The `:title`, `:icons`, and `:metadata` options set the corresponding
  `Snodo.Tool` definition fields. They are validated when the module compiles.
  """

  alias Snodo.JSONValue

  @types ~w(array boolean integer null number object string)a
  @root_options [:additional_properties, :schema]
  @object_types [:object, {:array, :object}]

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
    title = Keyword.get(opts, :title)
    description = Keyword.get(opts, :description)
    icons = Keyword.get(opts, :icons, [])
    metadata = Keyword.get(opts, :metadata, quote(do: %{}))
    root_options = Keyword.drop(opts, [:name, :title, :description, :icons, :metadata])

    quote do
      use Snodo.Tool,
        name: unquote(name),
        title: unquote(title),
        description: unquote(description),
        icons: unquote(icons),
        metadata: unquote(metadata)

      # Snodo.Tool.Simple.output_schema/1 accepts a do block as well as a map,
      # so it replaces the import of Snodo.Tool.output_schema/1.
      import Snodo.Tool,
        only: [title: 1, description: 1, input_schema: 1, annotations: 1, icons: 1, metadata: 1]

      import Snodo.Tool.Simple, only: [argument: 2, argument: 3, argument: 4, output_schema: 1]

      @mcp_tool_input_schema Snodo.Tool.Simple.new_schema!(
                               unquote(root_options),
                               __ENV__
                             )

      Module.put_attribute(__MODULE__, :mcp_tool_simple_scopes, [])
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

  ## Nested objects

  When `type` is `:object` or `{:array, :object}`, a `do` block may follow.
  Each `argument` inside it declares a property of that object, or of the
  object in `"items"` for an array, and may itself take a block. `:required`
  inside the block adds the name to the nested object's `"required"` list.
  A block argument also accepts `:additional_properties`, a boolean or schema
  map set as the nested object's `"additionalProperties"`. The other options,
  including `:schema`, apply to the property itself, so for an array they sit
  beside `"items"`.

      argument "filters", {:array, :object}, min_items: 1, additional_properties: false do
        argument "field", :string, required: true
        argument "value", :string
      end

  A block argument's `:schema` cannot set the keys the block generates:
  `"properties"` and `"required"` for `:object`, and `"items"` for
  `{:array, :object}`.

  An empty or repeated name, an unknown or repeated option, an option value
  of the wrong type, or a block on any other type is a compile error.
  """
  defmacro argument(name, type, opts \\ []) do
    case block_options(opts) do
      {:block, opts, block} -> nested_argument(name, type, opts, block)
      :flat -> flat_argument(name, type, opts)
    end
  end

  @doc false
  defmacro argument(name, type, opts, block) do
    case block_options(block) do
      {:block, [], block} -> nested_argument(name, type, opts, block)
      _other -> compile_error!(__CALLER__, "Snodo.Tool.Simple argument expects a do block")
    end
  end

  @doc """
  Sets the tool's output schema, either from a JSON Schema map or from a
  `do` block of `argument` declarations.

  With a map, this is `Snodo.Tool.output_schema/1`:

      output_schema(%{"type" => "object", "properties" => %{"version" => %{"type" => "string"}}})

  With a block, the declarations take the same forms as the input schema,
  including nested blocks, and produce an object schema:

      output_schema do
        argument "version", :string, required: true
        argument "published_at", :string
      end

  `:additional_properties` and `:schema` apply to the output root as the
  matching `use Snodo.Tool.Simple` options apply to the input root. They go in
  the same keyword list as the block:

      output_schema(
        additional_properties: false,
        do:
          (
            argument("version", :string, required: true)
            argument("published_at", :string)
          )
      )

  With an output schema, `call/2` must return structured content; see
  `Snodo.Tool.output_schema/1`. Declaring the output schema a second time
  when either declaration is a block, or declaring it inside an argument
  block, is a compile error.
  """
  defmacro output_schema(value) do
    case block_options(value) do
      {:block, opts, block} ->
        quote do
          unquote(__MODULE__).__open_output__(__MODULE__, unquote(opts), __ENV__)
          unquote(block)
          unquote(__MODULE__).__close_scope__(__MODULE__, __ENV__)
        end

      :flat ->
        quote do
          unquote(__MODULE__).__output_schema__(__MODULE__, unquote(value), __ENV__)
        end
    end
  end

  defp block_options(opts) when is_list(opts) do
    if Keyword.keyword?(opts) and Keyword.has_key?(opts, :do) do
      {block, rest} = Keyword.pop(opts, :do)
      {:block, rest, block}
    else
      :flat
    end
  end

  defp block_options(_opts), do: :flat

  defp flat_argument(name, type, opts) do
    quote do
      unquote(__MODULE__).__argument__(
        __MODULE__,
        unquote(name),
        unquote(type),
        unquote(opts),
        __ENV__
      )
    end
  end

  defp nested_argument(name, type, opts, block) do
    quote do
      unquote(__MODULE__).__open_argument__(
        __MODULE__,
        unquote(name),
        unquote(type),
        unquote(opts),
        __ENV__
      )

      unquote(block)
      unquote(__MODULE__).__close_scope__(__MODULE__, __ENV__)
    end
  end

  # An open `argument ... do` or `output do` block is a scope on
  # `@mcp_tool_simple_scopes`, innermost first. Declarations go to the
  # innermost scope, or to the input schema when none is open. A label is the
  # `{kind, path}` that compile errors use to name a declaration.

  @doc false
  @spec __argument__(module(), term(), term(), term(), Macro.Env.t()) :: :ok
  def __argument__(module, name, type, opts, env) do
    {target, label} = current_target(module)
    put_target(module, add_argument!(target, name, type, opts, env, label))
  end

  @doc false
  @spec __open_argument__(module(), term(), term(), term(), Macro.Env.t()) :: :ok
  def __open_argument__(module, name, type, opts, env) do
    {target, label} = current_target(module)
    allowed = [:additional_properties | @property_options]
    validate_argument!(target, name, opts, allowed, env, label)
    subject = subject(label, name)

    unless type in @object_types do
      compile_error!(
        env,
        "#{subject} has a do block, so its type must be :object or {:array, :object}; " <>
          "got #{inspect(type)}"
      )
    end

    validate_additional_properties!(opts, env, subject)
    validate_block_schema!(type, opts, env, subject)

    object =
      %{"type" => "object", "properties" => %{}}
      |> maybe_put_additional_properties(opts)

    push_scope(module, %{
      kind: :argument,
      name: name,
      type: type,
      opts: opts,
      label: label,
      object: object
    })
  end

  @doc false
  @spec __output_schema__(module(), term(), Macro.Env.t()) :: :ok
  def __output_schema__(module, schema, env) do
    unless scopes(module) == [] do
      compile_error!(env, "Snodo.Tool.Simple output_schema cannot be declared inside a block")
    end

    if Module.get_attribute(module, :mcp_tool_simple_output_block) do
      compile_error!(env, "Snodo.Tool.Simple output schema is already declared by a block")
    end

    Module.put_attribute(module, :mcp_tool_output_schema, schema)
  end

  defp validate_block_schema!(type, opts, env, subject) do
    generated = if type == :object, do: ["properties", "required"], else: ["items"]

    case Keyword.get(opts, :schema) do
      schema when is_map(schema) ->
        case Enum.filter(generated, &Map.has_key?(schema, &1)) do
          [] ->
            :ok

          keys ->
            compile_error!(
              env,
              "#{subject} :schema cannot set #{inspect(keys)}; its do block declares them"
            )
        end

      _other ->
        :ok
    end
  end

  @doc false
  @spec __open_output__(module(), term(), Macro.Env.t()) :: :ok
  def __open_output__(module, opts, env) do
    unless scopes(module) == [] do
      compile_error!(env, "Snodo.Tool.Simple output_schema cannot be declared inside a block")
    end

    unless is_nil(Module.get_attribute(module, :mcp_tool_output_schema)) do
      compile_error!(env, "Snodo.Tool.Simple output schema is already declared")
    end

    object = new_schema!(opts, env, "Snodo.Tool.Simple output_schema")
    Module.put_attribute(module, :mcp_tool_simple_output_block, true)
    push_scope(module, %{kind: :output, object: object})
  end

  @doc false
  @spec __close_scope__(module(), Macro.Env.t()) :: :ok
  def __close_scope__(module, env) do
    [scope | rest] = scopes(module)
    Module.put_attribute(module, :mcp_tool_simple_scopes, rest)
    close_scope(module, scope, env)
  end

  defp close_scope(module, %{kind: :output, object: object}, _env) do
    Module.put_attribute(module, :mcp_tool_output_schema, object)
  end

  defp close_scope(module, %{kind: :argument} = scope, env) do
    %{name: name, type: type, opts: opts, label: label, object: object} = scope

    base =
      case type do
        :object -> object
        {:array, :object} -> %{"type" => "array", "items" => object}
      end

    property = build_property!(base, opts, env, label, name)
    {target, _label} = current_target(module)

    target
    |> put_property!(name, property, Keyword.get(opts, :required, false), env, label)
    |> then(&put_target(module, &1))
  end

  defp scopes(module), do: Module.get_attribute(module, :mcp_tool_simple_scopes) || []

  defp push_scope(module, scope) do
    Module.put_attribute(module, :mcp_tool_simple_scopes, [scope | scopes(module)])
  end

  defp current_target(module) do
    case scopes(module) do
      [] ->
        {Module.get_attribute(module, :mcp_tool_input_schema), {:argument, []}}

      [%{kind: :output, object: object} | _rest] ->
        {object, {:output, []}}

      [%{kind: :argument, object: object, name: name, label: {kind, path}} | _rest] ->
        {object, {kind, path ++ [name]}}
    end
  end

  defp put_target(module, object) do
    case scopes(module) do
      [] ->
        Module.put_attribute(module, :mcp_tool_input_schema, object)

      [scope | rest] ->
        Module.put_attribute(module, :mcp_tool_simple_scopes, [%{scope | object: object} | rest])
    end
  end

  # `argument "name"` for a top-level input argument, `argument "a.b"` inside a
  # block, and `output argument "a.b"` inside an output block.
  defp display({kind, path}, name) do
    prefix = if kind == :output, do: "output argument", else: "argument"
    "#{prefix} #{inspect(Enum.join(path ++ [name], "."))}"
  end

  defp subject(label, name), do: "Snodo.Tool.Simple " <> display(label, name)

  @doc false
  @spec new_schema!(keyword(), Macro.Env.t(), String.t()) :: map()
  def new_schema!(opts, env, subject \\ "Snodo.Tool.Simple")

  def new_schema!(opts, env, subject) when is_list(opts) do
    validate_options!(opts, @root_options, env, subject)
    validate_additional_properties!(opts, env, subject)
    root_schema = Keyword.get(opts, :schema, %{})

    unless is_map(root_schema) and JSONValue.valid?(root_schema) do
      compile_error!(env, "#{subject} :schema must be a JSON Schema map")
    end

    schema =
      %{"type" => "object", "properties" => %{}}
      |> Map.merge(root_schema)
      |> maybe_put_additional_properties(opts)

    unless schema["type"] == "object" and is_map(schema["properties"]) and
             valid_required?(Map.get(schema, "required", [])) and
             JSONValue.valid?(schema) do
      compile_error!(env, "#{subject} must produce an object schema with properties")
    end

    schema
  end

  def new_schema!(_opts, env, subject) do
    compile_error!(env, "#{subject} options must be a keyword list")
  end

  defp add_argument!(root, name, type, opts, env, label) do
    validate_argument!(root, name, opts, @property_options, env, label)

    property =
      type
      |> type_schema!(env)
      |> build_property!(opts, env, label, name)

    put_property!(root, name, property, Keyword.get(opts, :required, false), env, label)
  end

  defp validate_argument!(root, name, opts, allowed, env, label)
       when is_map(root) and is_binary(name) and is_list(opts) do
    if name == "" do
      compile_error!(env, "Snodo.Tool.Simple argument names cannot be empty" <> within(label))
    end

    validate_options!(opts, allowed, env, subject(label, name))
    validate_property_options!(opts, env, display(label, name))

    if root |> Map.fetch!("properties") |> Map.has_key?(name) do
      compile_error!(env, "#{subject(label, name)} is declared more than once")
    end
  end

  defp validate_argument!(_root, name, _opts, _allowed, env, label) do
    compile_error!(
      env,
      "Snodo.Tool.Simple argument expects a string name and keyword options, got " <>
        inspect(name) <> within(label)
    )
  end

  # Where a declaration sits, for errors that cannot name the declaration.
  defp within({:argument, []}), do: ""
  defp within({:output, []}), do: " (in output_schema)"
  defp within({kind, path}), do: " (in #{display({kind, Enum.drop(path, -1)}, List.last(path))})"

  defp build_property!(base, opts, env, label, name) do
    property =
      base
      |> put_property_options(opts)
      |> merge_property_schema!(opts, env, display(label, name))

    unless JSONValue.valid?(property) do
      compile_error!(env, "#{subject(label, name)} must produce JSON Schema")
    end

    property
  end

  defp put_property!(root, name, property, required, env, label) do
    properties = Map.fetch!(root, "properties")

    root
    |> Map.put("properties", Map.put(properties, name, property))
    |> put_required!(name, required, env, display(label, name))
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

  defp merge_property_schema!(property, opts, env, display) do
    case Keyword.get(opts, :schema, %{}) do
      schema when is_map(schema) -> Map.merge(property, schema)
      _invalid -> compile_error!(env, "#{display} :schema must be a map")
    end
  end

  defp put_required!(root, _name, false, _env, _display), do: root

  defp put_required!(root, name, true, _env, _display) do
    Map.update(root, "required", [name], &Enum.uniq(&1 ++ [name]))
  end

  defp put_required!(_root, _name, _required, env, display) do
    compile_error!(env, "#{display} :required must be a boolean")
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

  defp validate_additional_properties!(opts, env, subject) do
    case Keyword.fetch(opts, :additional_properties) do
      :error ->
        :ok

      {:ok, value} when is_boolean(value) ->
        :ok

      {:ok, value} when is_map(value) ->
        unless JSONValue.valid?(value) do
          compile_error!(env, "#{subject} :additional_properties must be a schema or boolean")
        end

      {:ok, _invalid} ->
        compile_error!(env, "#{subject} :additional_properties must be a schema or boolean")
    end
  end

  defp validate_property_options!(opts, env, display) do
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

    Enum.each(validators, &validate_property_option!(&1, opts, env, display))
  end

  defp validate_property_option!({option, valid?, expectation}, opts, env, display) do
    case Keyword.fetch(opts, option) do
      {:ok, value} ->
        unless valid?.(value) do
          compile_error!(env, "#{display} :#{option} must be #{expectation}")
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
