defmodule Snodo.Schema.Validator.Basic.Error do
  @moduledoc "A structured failure returned by `Snodo.Schema.Validator.Basic`."

  @type path_segment :: String.t() | non_neg_integer()
  @type t :: %__MODULE__{
          path: [path_segment()],
          keyword: String.t(),
          message: String.t()
        }

  @enforce_keys [:path, :keyword, :message]
  defstruct [:path, :keyword, :message]
end

defmodule Snodo.Schema.Validator.Basic do
  @moduledoc """
  Dependency-free validation for the common JSON Schema subset used by tools.

  The validator supports primitive and union `type` declarations, `required`,
  recursive `properties`, `additionalProperties`, array `items`, `enum`,
  `const`, and the usual string, numeric, array, and object size constraints.
  Unknown keywords are preserved and ignored, so applications can use this as
  a useful baseline while retaining schemas that require a complete backend.

  Validation failures return `Snodo.Schema.Validator.Basic.Error` with a JSON
  path and the keyword that rejected the value. The MCP router deliberately
  keeps these details out of public invalid-params responses.
  """

  @behaviour Snodo.Schema.Validator

  alias Snodo.Schema.Validator.Basic.Error

  @json_types ~w(array boolean integer null number object string)

  @impl true
  def validate(instance, schema) when is_map(schema) do
    validate_schema(instance, schema, [])
  end

  def validate(_instance, _schema) do
    {:error, error([], "schema", "schema must be a map")}
  end

  defp validate_schema(_instance, true, _path), do: :ok

  defp validate_schema(_instance, false, path),
    do: {:error, error(path, "false", "value is rejected")}

  defp validate_schema(instance, schema, path) when is_map(schema) do
    with :ok <- validate_type(instance, schema, path),
         :ok <- validate_const(instance, schema, path),
         :ok <- validate_enum(instance, schema, path) do
      validate_shape(instance, schema, path)
    end
  end

  defp validate_schema(_instance, _schema, path) do
    {:error, error(path, "schema", "nested schema must be a map or boolean")}
  end

  defp validate_const(instance, %{"const" => expected}, path) do
    if json_equal?(instance, expected),
      do: :ok,
      else: {:error, error(path, "const", "value does not equal the declared constant")}
  end

  defp validate_const(_instance, _schema, _path), do: :ok

  defp validate_enum(instance, %{"enum" => allowed}, path) when is_list(allowed) do
    if Enum.any?(allowed, &json_equal?(instance, &1)),
      do: :ok,
      else: {:error, error(path, "enum", "value is not one of the allowed values")}
  end

  defp validate_enum(_instance, %{"enum" => _invalid}, path) do
    {:error, error(path, "enum", "enum must be a list")}
  end

  defp validate_enum(_instance, _schema, _path), do: :ok

  defp validate_type(instance, %{"type" => declaration}, path) do
    types = List.wrap(declaration)

    cond do
      types == [] or not Enum.all?(types, &(&1 in @json_types)) ->
        {:error, error(path, "type", "type must name one or more supported JSON types")}

      Enum.any?(types, &matches_type?(instance, &1)) ->
        :ok

      true ->
        {:error, error(path, "type", "value is not one of the declared JSON types")}
    end
  end

  defp validate_type(_instance, _schema, _path), do: :ok

  defp validate_shape(instance, schema, path) when is_map(instance) and not is_struct(instance),
    do: validate_object(instance, schema, path)

  defp validate_shape(instance, schema, path) when is_list(instance),
    do: validate_array(instance, schema, path)

  defp validate_shape(instance, schema, path) when is_binary(instance),
    do: validate_string(instance, schema, path)

  defp validate_shape(instance, schema, path) when is_number(instance),
    do: validate_number(instance, schema, path)

  defp validate_shape(_instance, _schema, _path), do: :ok

  defp validate_object(instance, schema, path) do
    with :ok <- validate_count(instance, schema, path, "minProperties", &map_size/1, :at_least),
         :ok <- validate_count(instance, schema, path, "maxProperties", &map_size/1, :at_most),
         :ok <- validate_required(instance, schema, path),
         :ok <- validate_properties(instance, schema, path) do
      validate_additional_properties(instance, schema, path)
    end
  end

  defp validate_required(instance, %{"required" => required}, path) when is_list(required) do
    if Enum.all?(required, &is_binary/1) and length(required) == length(Enum.uniq(required)) do
      case Enum.find(required, &(not Map.has_key?(instance, &1))) do
        nil -> :ok
        name -> {:error, error(path ++ [name], "required", "required property is missing")}
      end
    else
      {:error, error(path, "required", "required must contain unique string names")}
    end
  end

  defp validate_required(_instance, %{"required" => _invalid}, path) do
    {:error, error(path, "required", "required must be a list")}
  end

  defp validate_required(_instance, _schema, _path), do: :ok

  defp validate_properties(instance, %{"properties" => properties}, path)
       when is_map(properties) do
    properties
    |> Enum.sort_by(fn {name, _schema} -> name end)
    |> Enum.reduce_while(:ok, fn {name, property_schema}, :ok ->
      case Map.fetch(instance, name) do
        {:ok, value} -> continue_or_halt(validate_schema(value, property_schema, path ++ [name]))
        :error -> {:cont, :ok}
      end
    end)
  end

  defp validate_properties(_instance, %{"properties" => _invalid}, path) do
    {:error, error(path, "properties", "properties must be a map")}
  end

  defp validate_properties(_instance, _schema, _path), do: :ok

  defp validate_additional_properties(instance, schema, path) do
    properties = Map.get(schema, "properties", %{})
    extras = instance |> Map.keys() |> Enum.reject(&Map.has_key?(properties, &1)) |> Enum.sort()

    case Map.get(schema, "additionalProperties", true) do
      true ->
        :ok

      false ->
        case extras do
          [] ->
            :ok

          [name | _rest] ->
            {:error, error(path ++ [name], "additionalProperties", "property is not allowed")}
        end

      additional_schema when is_map(additional_schema) or is_boolean(additional_schema) ->
        Enum.reduce_while(extras, :ok, fn name, :ok ->
          continue_or_halt(
            validate_schema(Map.fetch!(instance, name), additional_schema, path ++ [name])
          )
        end)

      _invalid ->
        {:error,
         error(path, "additionalProperties", "additionalProperties must be a schema or boolean")}
    end
  end

  defp validate_array(instance, schema, path) do
    with :ok <- validate_count(instance, schema, path, "minItems", &length/1, :at_least),
         :ok <- validate_count(instance, schema, path, "maxItems", &length/1, :at_most),
         :ok <- validate_unique_items(instance, schema, path) do
      validate_items(instance, schema, path)
    end
  end

  defp validate_unique_items(instance, %{"uniqueItems" => true}, path) do
    if unique_json_values?(instance),
      do: :ok,
      else: {:error, error(path, "uniqueItems", "array items must be unique")}
  end

  defp validate_unique_items(_instance, %{"uniqueItems" => value}, path)
       when not is_boolean(value) do
    {:error, error(path, "uniqueItems", "uniqueItems must be a boolean")}
  end

  defp validate_unique_items(_instance, _schema, _path), do: :ok

  defp validate_items(instance, %{"items" => item_schema}, path) do
    instance
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {item, index}, :ok ->
      continue_or_halt(validate_schema(item, item_schema, path ++ [index]))
    end)
  end

  defp validate_items(_instance, _schema, _path), do: :ok

  defp validate_string(instance, schema, path) do
    with :ok <- validate_count(instance, schema, path, "minLength", &String.length/1, :at_least),
         :ok <- validate_count(instance, schema, path, "maxLength", &String.length/1, :at_most) do
      validate_pattern(instance, schema, path)
    end
  end

  defp validate_pattern(instance, %{"pattern" => pattern}, path) when is_binary(pattern) do
    case Regex.compile(pattern) do
      {:ok, regex} ->
        if Regex.match?(regex, instance),
          do: :ok,
          else: {:error, error(path, "pattern", "string does not match the required pattern")}

      {:error, _reason} ->
        {:error, error(path, "pattern", "pattern is not a valid regular expression")}
    end
  end

  defp validate_pattern(_instance, %{"pattern" => _invalid}, path) do
    {:error, error(path, "pattern", "pattern must be a string")}
  end

  defp validate_pattern(_instance, _schema, _path), do: :ok

  defp validate_number(instance, schema, path) do
    checks = [
      {"minimum", :at_least},
      {"maximum", :at_most},
      {"exclusiveMinimum", :greater_than},
      {"exclusiveMaximum", :less_than}
    ]

    Enum.reduce_while(checks, :ok, fn {keyword, comparison}, :ok ->
      continue_or_halt(validate_numeric_bound(instance, schema, path, keyword, comparison))
    end)
  end

  defp validate_numeric_bound(instance, schema, path, keyword, comparison) do
    case Map.fetch(schema, keyword) do
      :error ->
        :ok

      {:ok, bound} when is_number(bound) ->
        if compare(instance, bound, comparison),
          do: :ok,
          else: {:error, error(path, keyword, "number is outside the declared bound")}

      {:ok, _invalid} ->
        {:error, error(path, keyword, "numeric bound must be a number")}
    end
  end

  defp validate_count(instance, schema, path, keyword, counter, comparison) do
    case Map.fetch(schema, keyword) do
      :error ->
        :ok

      {:ok, bound} when is_integer(bound) and bound >= 0 ->
        if compare(counter.(instance), bound, comparison),
          do: :ok,
          else: {:error, error(path, keyword, "value violates the declared size bound")}

      {:ok, _invalid} ->
        {:error, error(path, keyword, "size bound must be a non-negative integer")}
    end
  end

  defp compare(value, bound, :at_least), do: value >= bound
  defp compare(value, bound, :at_most), do: value <= bound
  defp compare(value, bound, :greater_than), do: value > bound
  defp compare(value, bound, :less_than), do: value < bound

  defp matches_type?(value, "array"), do: is_list(value)
  defp matches_type?(value, "boolean"), do: is_boolean(value)
  defp matches_type?(value, "integer"), do: is_integer(value)
  defp matches_type?(value, "null"), do: is_nil(value)
  defp matches_type?(value, "number"), do: is_number(value)
  defp matches_type?(value, "object"), do: is_map(value) and not is_struct(value)
  defp matches_type?(value, "string"), do: is_binary(value)

  defp json_equal?(left, right) when is_number(left) and is_number(right), do: left == right

  defp json_equal?(left, right) when is_list(left) and is_list(right) do
    length(left) == length(right) and
      left
      |> Enum.zip(right)
      |> Enum.all?(fn {left_item, right_item} -> json_equal?(left_item, right_item) end)
  end

  defp json_equal?(left, right) when is_map(left) and is_map(right) do
    MapSet.new(Map.keys(left)) == MapSet.new(Map.keys(right)) and
      Enum.all?(left, fn {key, value} -> json_equal?(value, Map.fetch!(right, key)) end)
  end

  defp json_equal?(left, right), do: left === right

  defp unique_json_values?(values) do
    values
    |> Enum.reduce_while([], fn value, seen ->
      if Enum.any?(seen, &json_equal?(value, &1)),
        do: {:halt, :duplicate},
        else: {:cont, [value | seen]}
    end)
    |> Kernel.!=(:duplicate)
  end

  defp continue_or_halt(:ok), do: {:cont, :ok}
  defp continue_or_halt({:error, %Error{}} = error), do: {:halt, error}

  defp error(path, keyword, message) do
    %Error{path: path, keyword: keyword, message: message}
  end
end
