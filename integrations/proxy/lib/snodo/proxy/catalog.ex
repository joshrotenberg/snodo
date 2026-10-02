defmodule Snodo.Proxy.Catalog do
  @moduledoc false

  alias Snodo.Resource.Template

  @uri_scheme "mcp-proxy://"

  defstruct tools: %{},
            prompts: %{},
            resources: %{},
            resource_templates: %{},
            resource_names: %{},
            lists: %{tools: [], prompts: [], resources: [], resource_templates: []}

  @doc false
  def new(backends, max_items) when is_list(backends) and is_integer(max_items) do
    with {:ok, catalog} <- Enum.reduce_while(backends, {:ok, %__MODULE__{}}, &add_backend/2),
         :ok <- check_size(catalog, max_items) do
      {:ok, %{catalog | lists: build_lists(catalog)}}
    end
  end

  @doc false
  def lookup(%__MODULE__{} = catalog, :tool, name), do: Map.fetch(catalog.tools, name)
  def lookup(%__MODULE__{} = catalog, :prompt, name), do: Map.fetch(catalog.prompts, name)

  @doc false
  def lookup_resource(%__MODULE__{} = catalog, public_uri) when is_binary(public_uri) do
    case Map.fetch(catalog.resources, public_uri) do
      {:ok, entry} ->
        {:ok, entry, entry.original_uri}

      :error ->
        case decode_uri(public_uri) do
          {:ok, id, original_uri} -> lookup_template(catalog, id, original_uri)
          :error -> :error
        end
    end
  end

  defp lookup_template(catalog, id, original_uri) do
    matches =
      for entry <- Map.values(catalog.resource_templates),
          entry.id == id,
          Template.match(entry.compiled_template, original_uri) != :error,
          do: entry

    case matches do
      [entry] -> {:ok, entry, original_uri}
      [] -> :error
      _ambiguous -> {:error, :ambiguous}
    end
  end

  @doc false
  def uri(id, original_uri) when is_binary(id) and is_binary(original_uri),
    do: @uri_scheme <> id <> "/" <> original_uri

  @doc false
  def decode_uri(@uri_scheme <> rest) do
    case String.split(rest, "/", parts: 2) do
      [id, original_uri] when id != "" and original_uri != "" -> {:ok, id, original_uri}
      _invalid -> :error
    end
  end

  def decode_uri(_uri), do: :error

  @doc false
  def changed_kinds(%__MODULE__{lists: previous}, %__MODULE__{lists: current}) do
    for kind <- [:tools, :prompts, :resources, :resource_templates],
        Map.fetch!(previous, kind) != Map.fetch!(current, kind),
        do: kind
  end

  defp add_backend(backend, {:ok, catalog}) do
    with {:ok, catalog} <- add_named(catalog, backend, :tools, :tool),
         {:ok, catalog} <- add_named(catalog, backend, :prompts, :prompt),
         {:ok, catalog} <- add_resources(catalog, backend, :resources, :resource),
         {:ok, catalog} <-
           add_resources(catalog, backend, :resource_templates, :resource_template) do
      {:cont, {:ok, catalog}}
    else
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  defp add_named(catalog, backend, field, kind) do
    Enum.reduce_while(Map.fetch!(backend.catalog, field), {:ok, catalog}, fn definition,
                                                                             {:ok, current} ->
      case add_named_definition(current, backend, field, kind, definition) do
        {:ok, next} -> {:cont, {:ok, next}}
        {:error, reason} -> {:halt, {:error, {field, reason}}}
      end
    end)
  end

  defp add_named_definition(current, backend, field, kind, %{"name" => name} = definition)
       when is_binary(name) and name != "" do
    public_name = backend.prefix <> name
    entry = entry(backend, kind, definition, Map.put(definition, "name", public_name))

    case put_unique(Map.fetch!(current, field), public_name, entry) do
      {:ok, entries} -> {:ok, Map.put(current, field, entries)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp add_named_definition(_current, _backend, _field, _kind, _invalid),
    do: {:error, :invalid_definition}

  defp add_resources(catalog, backend, field, kind) do
    uri_field = if kind == :resource, do: "uri", else: "uriTemplate"

    Enum.reduce_while(Map.fetch!(backend.catalog, field), {:ok, catalog}, fn definition,
                                                                             {:ok, current} ->
      case add_resource_definition(current, backend, field, kind, uri_field, definition) do
        {:ok, next} -> {:cont, {:ok, next}}
        {:error, reason} -> {:halt, {:error, {field, reason}}}
      end
    end)
  end

  defp add_resource_definition(current, backend, field, kind, uri_field, definition)
       when is_map(definition) do
    name = Map.get(definition, "name")
    original_uri = Map.get(definition, uri_field)

    if is_binary(name) and name != "" and is_binary(original_uri) and original_uri != "" do
      public_name = backend.prefix <> name
      public_uri = uri(backend.id, original_uri)

      public_definition =
        definition
        |> Map.put("name", public_name)
        |> Map.put(uri_field, public_uri)

      entry =
        backend
        |> entry(kind, definition, public_definition)
        |> Map.put(:original_uri, original_uri)
        |> Map.put(
          :subscribed?,
          kind == :resource and MapSet.member?(backend.subscribed_uris, original_uri)
        )

      with {:ok, names} <- put_unique(current.resource_names, public_name, entry),
           {:ok, entry} <- maybe_compile_template(entry),
           {:ok, entries} <- put_unique(Map.fetch!(current, field), public_uri, entry) do
        {:ok, current |> Map.put(:resource_names, names) |> Map.put(field, entries)}
      end
    else
      {:error, :invalid_definition}
    end
  end

  defp add_resource_definition(_current, _backend, _field, _kind, _uri_field, _invalid),
    do: {:error, :invalid_definition}

  defp maybe_compile_template(%{kind: :resource_template, original_uri: template} = entry) do
    case Template.compile(template) do
      {:ok, compiled} -> {:ok, Map.put(entry, :compiled_template, compiled)}
      {:error, reason} -> {:error, {:unsupported_template, template, reason}}
    end
  end

  defp maybe_compile_template(entry), do: {:ok, entry}

  defp entry(backend, kind, original, public) do
    %{
      id: backend.id,
      kind: kind,
      client: backend.client,
      backend_pid: backend.pid,
      original: original,
      public: public,
      name: public["name"]
    }
  end

  defp put_unique(entries, key, value) do
    if Map.has_key?(entries, key),
      do: {:error, {:collision, key}},
      else: {:ok, Map.put(entries, key, value)}
  end

  defp check_size(catalog, max_items) when max_items > 0 do
    count =
      map_size(catalog.tools) + map_size(catalog.prompts) + map_size(catalog.resources) +
        map_size(catalog.resource_templates)

    if count <= max_items, do: :ok, else: {:error, {:catalog_limit, max_items}}
  end

  defp build_lists(catalog) do
    %{
      tools: public_sorted(catalog.tools, "name"),
      prompts: public_sorted(catalog.prompts, "name"),
      resources: public_sorted(catalog.resources, "uri"),
      resource_templates: public_sorted(catalog.resource_templates, "uriTemplate")
    }
  end

  defp public_sorted(entries, field) do
    entries
    |> Map.values()
    |> Enum.map(& &1.public)
    |> Enum.sort_by(&Map.fetch!(&1, field))
  end
end
