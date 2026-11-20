defmodule Snodo.Transport.ParamHeaders do
  @moduledoc false

  # `x-mcp-header` tool parameters (2026-07-28, SEP-2243). A tool may mark an
  # input property with `"x-mcp-header": "Name"`; over Streamable HTTP the
  # client mirrors that argument into an `Mcp-Param-Name` header and the server
  # checks the header against the body.
  #
  # An annotation is valid when its value is a non-empty RFC 9110 token, the
  # property's `type` is exactly "string", "integer", or "boolean", the name is
  # unique ignoring case, and the property is reached from the schema root
  # through `properties` keywords only.

  @annotation "x-mcp-header"
  @prefix "Mcp-Param-"
  @token ~r/\A[!#$%&'*+\-.^_`|~0-9A-Za-z]+\z/
  @decimal ~r/\A(?<sign>[+-]?)(?<whole>[0-9]+)(?:\.(?<fraction>[0-9]+))?(?:[eE](?<exponent>[+-]?[0-9]+))?\z/
  @max_safe_integer 9_007_199_254_740_991
  @types ["string", "integer", "boolean"]
  # Keywords whose values are JSON data, not subschemas.
  @data_keywords ["const", "default", "enum", "examples"]

  @type annotation :: %{name: String.t(), path: [String.t()], type: String.t()}

  @doc "Returns the schema's annotations, or the first reason it is invalid."
  @spec annotations(map()) :: {:ok, [annotation()]} | {:error, String.t()}
  def annotations(schema) when is_map(schema) do
    with {:ok, found} <- collect(schema, [], true, []),
         found = Enum.reverse(found),
         :ok <- unique(found) do
      {:ok, found}
    end
  end

  # A schema that is not a map carries no annotations.
  def annotations(_schema), do: {:ok, []}

  @doc "The header name for an annotation, as sent: `Mcp-Param-<Name>`."
  @spec header_name(annotation()) :: String.t()
  def header_name(%{name: name}), do: @prefix <> name

  @doc """
  Header mirrors for a server to check, in the shape of
  `Snodo.Transport.Policy` `mirrored_headers`, keyed by the lowercase name.
  """
  @spec mirrors([annotation()]) :: %{optional(String.t()) => Snodo.Transport.Policy.mirror()}
  def mirrors(annotations) do
    Map.new(annotations, fn annotation ->
      {String.downcase(header_name(annotation)),
       %{path: ["params", "arguments" | annotation.path], encoding: :base64_sentinel}}
    end)
  end

  @doc false
  @spec outside_safe_integer_range?(term()) :: boolean()
  def outside_safe_integer_range?(value) do
    (is_integer(value) or is_float(value)) and abs(value) > @max_safe_integer
  end

  @doc """
  The plain header value a client sends for an argument, before any base64
  sentinel encoding, or `nil` when no header is sent (the argument is null,
  absent, or a number outside the JavaScript safe integer range).
  """
  @spec plain_value(term()) :: String.t() | nil
  def plain_value(value) when is_binary(value), do: value
  def plain_value(value) when is_boolean(value), do: Atom.to_string(value)
  # The spec limits mirrored integers to the JavaScript safe integer range.
  def plain_value(value) when is_number(value) do
    cond do
      outside_safe_integer_range?(value) -> nil
      is_integer(value) -> Integer.to_string(value)
      true -> :erlang.float_to_binary(value, [:short])
    end
  end

  def plain_value(_absent_or_structured), do: nil

  @doc "Whether a decoded header value matches the argument in the body."
  @spec matches?(String.t(), term()) :: boolean()
  def matches?(header, value) when is_binary(value), do: header == value
  def matches?(header, value) when is_boolean(value), do: header == Atom.to_string(value)

  # Parse exactly because Float.parse/1 loses integer precision above 2^53.
  def matches?(header, value) when is_integer(value) do
    case Integer.parse(header) do
      {number, ""} -> number == value
      _decimal_or_invalid -> decimal_matches?(header, value)
    end
  end

  def matches?(header, value) when is_float(value) do
    # A float above the JavaScript safe integer range has no fractional bits.
    if outside_safe_integer_range?(value) do
      matches?(header, trunc(value))
    else
      case Float.parse(header) do
        {number, ""} -> number == value
        _not_a_number -> false
      end
    end
  end

  def matches?(_header, _value), do: false

  # Compare significant digits and decimal scale without rounding or expanding
  # an exponent supplied in a header.
  defp decimal_matches?(header, value) do
    case Regex.named_captures(@decimal, header) do
      %{"sign" => sign, "whole" => whole, "fraction" => fraction, "exponent" => exponent} ->
        digits = String.trim_leading(whole <> fraction, "0")
        significant = String.trim_trailing(digits, "0")
        expected = Integer.to_string(abs(value))
        expected_significant = String.trim_trailing(expected, "0")
        exponent = if exponent == "", do: 0, else: String.to_integer(exponent)

        if value == 0 do
          significant == ""
        else
          negative? = sign == "-"
          expected_negative? = value < 0
          integer_digits = exponent + byte_size(digits) - byte_size(fraction)

          negative? == expected_negative? and significant == expected_significant and
            integer_digits == byte_size(expected)
        end

      nil ->
        false
    end
  end

  defp collect(schema, path, reachable?, found) when is_map(schema) do
    with {:ok, found} <- own_annotation(schema, path, reachable?, found) do
      reduce_ok(schema, found, fn {keyword, value}, found ->
        collect_keyword(keyword, value, path, reachable?, found)
      end)
    end
  end

  defp collect(values, _path, _reachable?, found) when is_list(values),
    do: reduce_ok(values, found, &collect(&1, [], false, &2))

  defp collect(_scalar, _path, _reachable?, found), do: {:ok, found}

  defp collect_keyword("properties", properties, path, reachable?, found)
       when is_map(properties) do
    reduce_ok(properties, found, fn {name, property}, found ->
      collect(property, path ++ [name], reachable?, found)
    end)
  end

  defp collect_keyword(keyword, _value, _path, _reachable?, found)
       when keyword in [@annotation | @data_keywords],
       do: {:ok, found}

  defp collect_keyword(_keyword, value, _path, _reachable?, found),
    do: collect(value, [], false, found)

  # Enum.reduce over `{:ok, acc}` results, stopping at the first error.
  defp reduce_ok(enumerable, acc, fun) do
    Enum.reduce_while(enumerable, {:ok, acc}, fn item, {:ok, acc} ->
      case fun.(item, acc) do
        {:ok, acc} -> {:cont, {:ok, acc}}
        error -> {:halt, error}
      end
    end)
  end

  defp own_annotation(schema, path, reachable?, found) do
    case Map.fetch(schema, @annotation) do
      :error ->
        {:ok, found}

      {:ok, _name} when not reachable? or path == [] ->
        {:error, "x-mcp-header is only allowed on properties reached through `properties`"}

      {:ok, name} ->
        with :ok <- valid_name(name),
             :ok <- valid_type(Map.get(schema, "type"), name) do
          {:ok, [%{name: name, path: path, type: schema["type"]} | found]}
        end
    end
  end

  defp valid_name(name) when is_binary(name) do
    cond do
      name == "" -> {:error, "x-mcp-header must not be empty"}
      Regex.match?(@token, name) -> :ok
      true -> {:error, "x-mcp-header #{inspect(name)} is not a valid header name token"}
    end
  end

  defp valid_name(name), do: {:error, "x-mcp-header must be a string, got: #{inspect(name)}"}

  defp valid_type(type, _name) when type in @types, do: :ok

  defp valid_type(type, name),
    do:
      {:error,
       "x-mcp-header #{inspect(name)} requires type string, integer, or boolean, got: " <>
         inspect(type)}

  defp unique(annotations) do
    annotations
    |> Enum.group_by(&String.downcase(&1.name))
    |> Enum.find(fn {_key, group} -> length(group) > 1 end)
    |> case do
      nil ->
        :ok

      {_key, [first | _others]} ->
        {:error, "x-mcp-header #{inspect(first.name)} is used more than once, ignoring case"}
    end
  end
end
