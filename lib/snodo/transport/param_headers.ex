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

  @doc """
  The plain header value a client sends for an argument, before any base64
  sentinel encoding, or `nil` when no header is sent (the argument is null or
  absent).
  """
  @spec plain_value(term()) :: String.t() | nil
  def plain_value(value) when is_binary(value), do: value
  def plain_value(value) when is_boolean(value), do: Atom.to_string(value)
  def plain_value(value) when is_integer(value), do: Integer.to_string(value)
  def plain_value(value) when is_float(value), do: :erlang.float_to_binary(value, [:short])
  def plain_value(_absent_or_structured), do: nil

  @doc "Whether a decoded header value matches the argument in the body."
  @spec matches?(String.t(), term()) :: boolean()
  def matches?(header, value) when is_binary(value), do: header == value
  def matches?(header, value) when is_boolean(value), do: header == Atom.to_string(value)

  # Integers compare numerically, so "42.0" matches 42.
  def matches?(header, value) when is_number(value) do
    case Float.parse(header) do
      {number, ""} -> number == value
      _not_a_number -> false
    end
  end

  def matches?(_header, _value), do: false

  defp collect(schema, path, reachable?, found) when is_map(schema) do
    with {:ok, found} <- own_annotation(schema, path, reachable?, found) do
      Enum.reduce_while(schema, {:ok, found}, fn {keyword, value}, {:ok, found} ->
        case collect_keyword(keyword, value, path, reachable?, found) do
          {:ok, found} -> {:cont, {:ok, found}}
          error -> {:halt, error}
        end
      end)
    end
  end

  defp collect(values, _path, _reachable?, found) when is_list(values) do
    Enum.reduce_while(values, {:ok, found}, fn value, {:ok, found} ->
      case collect(value, [], false, found) do
        {:ok, found} -> {:cont, {:ok, found}}
        error -> {:halt, error}
      end
    end)
  end

  defp collect(_scalar, _path, _reachable?, found), do: {:ok, found}

  defp collect_keyword("properties", properties, path, reachable?, found)
       when is_map(properties) do
    Enum.reduce_while(properties, {:ok, found}, fn {name, property}, {:ok, found} ->
      case collect(property, path ++ [name], reachable?, found) do
        {:ok, found} -> {:cont, {:ok, found}}
        error -> {:halt, error}
      end
    end)
  end

  defp collect_keyword(keyword, _value, _path, _reachable?, found)
       when keyword in [@annotation | @data_keywords],
       do: {:ok, found}

  defp collect_keyword(_keyword, value, _path, _reachable?, found),
    do: collect(value, [], false, found)

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
