defmodule Snodo.Schema.Validator.JSV.Policy do
  @moduledoc false

  alias Snodo.Schema.Validator.JSV.BuildError

  @draft202012 "https://json-schema.org/draft/2020-12/schema"
  @draft7 "http://json-schema.org/draft-07/schema"
  @schema_maps ~w($defs definitions properties patternProperties dependentSchemas dependencies)
  @schema_values ~w(additionalProperties propertyNames contains not if then else items additionalItems unevaluatedProperties unevaluatedItems)
  @schema_arrays ~w(allOf anyOf oneOf prefixItems)
  @root_uri "https://snodo.invalid/__schema_root__"
  @vocabularies Enum.map(
                  ~w(core applicator validation unevaluated meta-data format-annotation format-assertion content),
                  &("https://json-schema.org/draft/2020-12/vocab/" <> &1)
                )

  def dialect(schema) when is_boolean(schema), do: @draft202012

  def dialect(schema) when is_map(schema) do
    normalize_dialect(Map.get(schema, "$schema", @draft202012))
  end

  def check!(schema, dialect) do
    index = %{
      locations: MapSet.new(),
      resources: %{@root_uri => []},
      anchors: %{},
      references: []
    }

    index = index_schema(schema, dialect, [], @root_uri, index)
    walk(schema, dialect, [], index.locations)
    Enum.each(index.references, &check_reference!(&1, index))
  end

  defp walk(schema, dialect, path, locations) when is_map(schema) do
    Enum.each(schema, fn
      {keyword, _value} when keyword in ["jsv-cast", "x-jsv-cast"] ->
        fail!({:unsupported_cast, path ++ [keyword]})

      {"$schema", value} ->
        if normalize_dialect(value) != dialect, do: fail!({:mixed_dialects, path})

      {"$vocabulary", value} ->
        check_vocabularies!(value, path)

      {"$id", value} when is_binary(value) ->
        require_schema_location!(locations, path)
        check_identifier!(value, path)

      {keyword, _value} when keyword in ["$anchor", "$dynamicAnchor", "$ref", "$dynamicRef"] ->
        require_schema_location!(locations, path)

      {keyword, values} when keyword in @schema_maps and is_map(values) ->
        walk_schema_map(values, keyword, dialect, path, locations)

      {keyword, value} ->
        walk(value, dialect, path ++ [keyword], locations)
    end)
  end

  defp walk(values, dialect, path, locations) when is_list(values) do
    values
    |> Enum.with_index()
    |> Enum.each(fn {value, index} ->
      walk(value, dialect, path ++ [to_string(index)], locations)
    end)
  end

  defp walk(_value, _dialect, _path, _locations), do: :ok

  defp walk_schema_map(values, keyword, dialect, path, locations) do
    if MapSet.member?(locations, path) and schema_map_keyword?(keyword, dialect) do
      Enum.each(values, fn {name, value} ->
        walk(value, dialect, path ++ [keyword, name], locations)
      end)
    else
      walk(values, dialect, path ++ [keyword], locations)
    end
  end

  # Only references into schema-valued positions are admitted. JSON Schema also
  # permits implementations to follow pointers into arbitrary annotation data;
  # those targets have not been validated by the selected meta-schema. Never let
  # the builder interpret them as new schemas or execute extension build hooks.
  defp index_schema(schema, dialect, path, base, index) when is_map(schema) do
    index = %{index | locations: MapSet.put(index.locations, path)}
    {base, index} = index_identifier(schema, path, base, index)
    index = index_anchors(schema, path, base, index)
    index = index_references(schema, path, base, index)

    Enum.reduce(schema, index, fn {keyword, value}, index ->
      index_children(keyword, value, dialect, path ++ [keyword], base, index)
    end)
  end

  defp index_schema(schema, _dialect, path, _base, index) when is_boolean(schema),
    do: %{index | locations: MapSet.put(index.locations, path)}

  defp index_schema(_invalid, _dialect, _path, _base, index), do: index

  defp index_children(keyword, values, dialect, path, base, index)
       when keyword in @schema_maps and is_map(values) do
    if schema_map_keyword?(keyword, dialect) do
      Enum.reduce(values, index, fn {name, schema}, index ->
        index_schema(schema, dialect, path ++ [name], base, index)
      end)
    else
      index
    end
  end

  defp index_children(keyword, values, dialect, path, base, index)
       when keyword in @schema_arrays and is_list(values) do
    if dialect == @draft7 and keyword == "prefixItems" do
      index
    else
      index_array(values, dialect, path, base, index)
    end
  end

  defp index_children("items", values, @draft7, path, base, index) when is_list(values),
    do: index_array(values, @draft7, path, base, index)

  defp index_children(keyword, schema, dialect, path, base, index)
       when keyword in @schema_values do
    cond do
      dialect == @draft7 and keyword in ["unevaluatedProperties", "unevaluatedItems"] -> index
      dialect == @draft202012 and keyword == "additionalItems" -> index
      true -> index_schema(schema, dialect, path, base, index)
    end
  end

  defp index_children(_keyword, _value, _dialect, _path, _base, index), do: index

  defp schema_map_keyword?(keyword, dialect),
    do: not (dialect == @draft7 and keyword in ["$defs", "dependentSchemas"])

  defp index_array(values, dialect, path, base, index) do
    values
    |> Enum.with_index()
    |> Enum.reduce(index, fn {schema, position}, index ->
      index_schema(schema, dialect, path ++ [to_string(position)], base, index)
    end)
  end

  defp index_identifier(schema, path, base, index) do
    case Map.fetch(schema, "$id") do
      {:ok, identifier} when is_binary(identifier) ->
        uri = resolve_uri!(base, identifier)
        field = if URI.parse(uri).fragment in [nil, ""], do: :resources, else: :anchors
        {uri, put_identifier!(index, field, uri, path)}

      :error ->
        {base, index}

      _invalid ->
        fail!({:invalid_identifier, path})
    end
  end

  defp index_anchors(schema, path, base, index) do
    Enum.reduce(["$anchor", "$dynamicAnchor"], index, fn keyword, index ->
      case Map.fetch(schema, keyword) do
        {:ok, anchor} when is_binary(anchor) ->
          put_identifier!(index, :anchors, resolve_uri!(base, "#" <> anchor), path)

        :error ->
          index

        _invalid ->
          fail!({:invalid_anchor, path})
      end
    end)
  end

  defp index_references(schema, path, base, index) do
    Enum.reduce(["$ref", "$dynamicRef"], index, fn keyword, index ->
      case Map.fetch(schema, keyword) do
        {:ok, reference} when is_binary(reference) ->
          %{index | references: [{reference, base, path} | index.references]}

        :error ->
          index

        _invalid ->
          fail!({:invalid_reference, path})
      end
    end)
  end

  defp put_identifier!(index, field, uri, path) do
    case Map.fetch(Map.fetch!(index, field), uri) do
      {:ok, ^path} -> index
      {:ok, _other} -> fail!({:ambiguous_identifier, uri})
      :error -> Map.update!(index, field, &Map.put(&1, uri, path))
    end
  end

  defp check_reference!({reference, base, source}, index) do
    uri = URI.parse(resolve_uri!(base, reference))
    resource = URI.to_string(%{uri | fragment: nil})

    if resource not in JSV.Resolver.Embedded.embedded_normalized_ids() do
      target = reference_target(uri.fragment, resource, index)

      unless target != nil and MapSet.member?(index.locations, target),
        do: fail!({:unsupported_reference_target, reference, source})
    end
  end

  defp reference_target(fragment, resource, index) when fragment in [nil, ""],
    do: Map.get(index.resources, resource)

  defp reference_target(fragment, resource, index) do
    fragment = URI.decode(fragment)

    if String.starts_with?(fragment, "/") do
      case Map.fetch(index.resources, resource) do
        {:ok, root} -> root ++ pointer_parts!(fragment)
        :error -> nil
      end
    else
      Map.get(index.anchors, resource <> "#" <> fragment)
    end
  end

  defp pointer_parts!("/" <> pointer) do
    pointer
    |> String.split("/")
    |> Enum.map(fn part ->
      if Regex.match?(~r/~(?:[^01]|$)/, part), do: fail!({:invalid_pointer, pointer})
      part |> String.replace("~1", "/") |> String.replace("~0", "~")
    end)
  end

  defp resolve_uri!(base, reference), do: base |> URI.merge(reference) |> URI.to_string()

  defp require_schema_location!(locations, path) do
    unless MapSet.member?(locations, path), do: fail!({:unsupported_schema_location, path})
  end

  defp check_vocabularies!(vocabularies, path) when is_map(vocabularies) do
    Enum.each(vocabularies, fn
      {uri, required?} when is_boolean(required?) ->
        if required? and uri not in @vocabularies,
          do: fail!({:unsupported_vocabulary, uri, path})

      _invalid ->
        fail!({:invalid_vocabulary, path})
    end)
  end

  defp check_vocabularies!(_value, path), do: fail!({:invalid_vocabulary, path})

  defp check_identifier!(value, path) do
    case URI.parse(value) do
      %URI{host: host} when is_binary(host) ->
        if String.downcase(host) == "json-schema.org",
          do: fail!({:reserved_schema_identifier, value, path})

      _other ->
        :ok
    end
  end

  defp normalize_dialect(value) when is_binary(value) do
    case value do
      dialect when dialect in [@draft202012, @draft7] -> dialect
      @draft202012 <> "#" -> @draft202012
      @draft7 <> "#" -> @draft7
      _unsupported -> fail!({:unsupported_dialect, value})
    end
  end

  defp normalize_dialect(value), do: fail!({:unsupported_dialect, value})

  @spec fail!(term()) :: no_return()
  defp fail!(reason), do: raise(BuildError, reason: reason)
end
