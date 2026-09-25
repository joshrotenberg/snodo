defmodule Snodo.JSONValue do
  @moduledoc """
  The JSON value rule every result, content map, and metadata map must satisfy.

  A JSON value here is `nil`, a boolean, a number, a string, a list of JSON
  values, or a map whose keys are **strings** and whose values are JSON values.
  Atom keys and atom values are rejected. The protocol carries these values
  through untouched, so accepting atoms would mean guessing at encoding and
  silently resolving collisions between `:name` and `"name"`.

  Elixir domain layers usually return atom-keyed maps and structs, so a value
  arriving from application code often needs converting first.
  `encodable!/1` does that:

      iex> Snodo.JSONValue.encodable!(%{name: "jason", tags: [:json, :parser]})
      %{"name" => "jason", "tags" => ["json", "parser"]}

  `Snodo.Result.structured/2`, `Snodo.Resource.json/3`, and the content builders
  all validate with `valid?/1` and raise on anything else.
  """

  @doc """
  Returns whether a term is a JSON value under the rule above.
  """
  @spec valid?(term()) :: boolean()
  def valid?(value)
      when is_nil(value) or is_boolean(value) or is_binary(value) or is_number(value),
      do: true

  def valid?(value) when is_list(value), do: Enum.all?(value, &valid?/1)

  def valid?(value) when is_map(value) and not is_struct(value) do
    Enum.all?(value, fn {key, nested} -> is_binary(key) and valid?(nested) end)
  end

  def valid?(_value), do: false

  @doc """
  Converts an Elixir term into a JSON value, raising when it cannot.

  The rules are fixed so the result is predictable:

    * atom keys become strings, and a map that would collide two keys onto one
      string raises rather than dropping either;
    * atom values become strings, except `nil`, `true`, and `false`;
    * `Date`, `Time`, `DateTime`, `NaiveDateTime`, `URI`, and `Version` become
      their canonical string forms;
    * any other struct becomes a map of its fields;
    * tuples, PIDs, references, functions, and ports raise, because there is no
      correct JSON form to pick for them. A keyword list is a list of tuples
      and therefore raises; convert it with `Map.new/1` first.

  Strings are returned unchanged and are not checked for UTF-8 validity;
  encoding catches that later.
  """
  @spec encodable!(term()) :: term()
  def encodable!(value)
      when is_nil(value) or is_boolean(value) or is_binary(value) or is_number(value),
      do: value

  def encodable!(%Date{} = value), do: Date.to_iso8601(value)
  def encodable!(%Time{} = value), do: Time.to_iso8601(value)
  def encodable!(%DateTime{} = value), do: DateTime.to_iso8601(value)
  def encodable!(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  def encodable!(%URI{} = value), do: URI.to_string(value)
  def encodable!(%Version{} = value), do: Version.to_string(value)

  def encodable!(%_struct{} = value), do: value |> Map.from_struct() |> encodable!()

  def encodable!(value) when is_map(value) do
    Enum.reduce(value, %{}, fn {key, nested}, converted ->
      key = encodable_key!(key)

      if Map.has_key?(converted, key) do
        raise ArgumentError,
              "cannot convert map to a JSON value: two keys both become #{inspect(key)}"
      end

      Map.put(converted, key, encodable!(nested))
    end)
  end

  def encodable!(value) when is_list(value), do: Enum.map(value, &encodable!/1)

  def encodable!(value) when is_atom(value), do: Atom.to_string(value)

  def encodable!(value) do
    raise ArgumentError, "cannot convert #{inspect(value)} to a JSON value"
  end

  defp encodable_key!(key) when is_binary(key), do: key
  defp encodable_key!(key) when is_atom(key) and not is_boolean(key), do: Atom.to_string(key)
  defp encodable_key!(key) when is_number(key), do: to_string(key)

  defp encodable_key!(key) do
    raise ArgumentError, "cannot use #{inspect(key)} as a JSON object key"
  end
end
