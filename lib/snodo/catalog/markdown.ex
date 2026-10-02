defmodule Snodo.Catalog.Markdown do
  @moduledoc """
  Collects an MCP server catalog through `Snodo.Client` and renders Markdown.

  `collect/1` uses the selected protocol's discovery information and follows
  every list method through its final page. The resulting string-keyed catalog
  can also be passed to `render/1` without a client connection.
  """

  alias Snodo.Client
  alias Snodo.Client.Session
  alias Snodo.Error

  @server_info_key "io.modelcontextprotocol/serverInfo"

  @type catalog :: %{
          required(String.t()) => map() | [map()] | String.t()
        }

  @doc "Collects discovery details and all tools, resources, templates, and prompts."
  @spec collect(Client.t()) :: {:ok, catalog()} | {:error, Error.t()}
  def collect(%Client{} = client) do
    with {:ok, {server_info, capabilities}} <- discovery(client),
         {:ok, tools} <- list_if_supported(client, capabilities, "tools", &Client.list_tools/1),
         {:ok, resources} <-
           list_if_supported(client, capabilities, "resources", &Client.list_resources/1),
         {:ok, templates} <-
           list_if_supported(client, capabilities, "resources", &Client.list_resource_templates/1),
         {:ok, prompts} <-
           list_if_supported(client, capabilities, "prompts", &Client.list_prompts/1) do
      {:ok,
       %{
         "serverInfo" => server_info,
         "protocolVersion" => client.protocol,
         "tools" => tools,
         "resources" => resources,
         "resourceTemplates" => templates,
         "prompts" => prompts
       }}
    end
  end

  @doc "Renders a collected, protocol-shaped catalog with documentation coverage counts."
  @spec render(catalog()) :: String.t()
  def render(catalog) when is_map(catalog) do
    tools = entries(catalog, "tools")
    resources = entries(catalog, "resources")
    templates = entries(catalog, "resourceTemplates")
    prompts = entries(catalog, "prompts")

    [
      introduction(catalog),
      section("Tools", tools, &tool/1),
      section("Resources", resources, &resource/1),
      section("Resource templates", templates, &resource_template/1),
      section("Prompts", prompts, &prompt/1),
      coverage(tools, resources, templates, prompts)
    ]
    |> Enum.join("\n\n")
    |> Kernel.<>("\n")
  end

  defp discovery(%Client{protocol: "2026-07-28"} = client) do
    case Client.discover(client) do
      {:ok, result} ->
        metadata = Map.get(result, "_meta", %{})
        info = if is_map(metadata), do: Map.get(metadata, @server_info_key, %{}), else: %{}
        {:ok, {if(is_map(info), do: info, else: %{}), Map.get(result, "capabilities", %{})}}

      {:error, %Error{} = error} ->
        {:error, error}
    end
  end

  defp discovery(%Client{
         session: %Session{server_info: info, server_capabilities: capabilities}
       }),
       do: {:ok, {info, capabilities}}

  defp list_if_supported(client, capabilities, kind, list) do
    if is_map(capabilities) and Map.has_key?(capabilities, kind),
      do: list.(client),
      else: {:ok, []}
  end

  defp entries(catalog, key) do
    catalog
    |> Map.get(key, [])
    |> Enum.sort_by(&Map.get(&1, "name", Map.get(&1, "uri", "")))
  end

  defp introduction(catalog) do
    info = Map.get(catalog, "serverInfo", %{})
    name = Map.get(info, "name")
    version = Map.get(info, "version")

    [
      "# MCP catalog" <> if(is_binary(name), do: ": " <> escape(name), else: ""),
      "Protocol: " <> escape(Map.get(catalog, "protocolVersion", "unknown")),
      if(is_binary(version), do: "Server version: " <> escape(version), else: nil)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n\n")
  end

  defp section(title, [], _renderer), do: "## #{title}\n\nNone."

  defp section(title, items, renderer) do
    "## #{title}\n\n" <> Enum.map_join(items, "\n\n", renderer)
  end

  defp tool(item) do
    [
      heading("Tool", item),
      description(item),
      schema_table("Input schema", Map.get(item, "inputSchema", %{})),
      maybe_schema_table("Output schema", Map.get(item, "outputSchema")),
      annotations(item)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n\n")
  end

  defp resource(item) do
    [
      heading("Resource", item),
      description(item),
      details([{"URI", Map.get(item, "uri")}, {"MIME type", Map.get(item, "mimeType")}]),
      annotations(item)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n\n")
  end

  defp resource_template(item) do
    [
      heading("Resource template", item),
      description(item),
      details([
        {"URI template", Map.get(item, "uriTemplate")},
        {"MIME type", Map.get(item, "mimeType")}
      ]),
      annotations(item)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n\n")
  end

  defp prompt(item) do
    args = Map.get(item, "arguments", [])

    [
      heading("Prompt", item),
      description(item),
      argument_table(args)
    ]
    |> Enum.join("\n\n")
  end

  defp heading(kind, item), do: "### #{kind}: " <> escape(Map.get(item, "name", "unnamed"))

  defp description(item) do
    case Map.get(item, "description") do
      value when is_binary(value) ->
        if String.trim(value) == "", do: "_No description._", else: escape(value)

      _other ->
        "_No description._"
    end
  end

  defp schema_table(title, schema) when is_map(schema) do
    properties = Map.get(schema, "properties", %{})
    required = Map.get(schema, "required", [])

    property_rows = property_rows(properties, required)

    root_rules = schema_rules(schema, ["properties", "required"])

    [
      "#### #{title}",
      if(property_rows == [],
        do: "No named properties.",
        else: table(["Property", "Type", "Required", "Description", "Other rules"], property_rows)
      ),
      if(root_rules == "None", do: nil, else: "Schema rules: " <> escape(root_rules))
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n\n")
  end

  defp schema_table(title, _schema), do: "#### #{title}\n\nNo named properties."
  defp maybe_schema_table(_title, nil), do: nil
  defp maybe_schema_table(title, schema), do: schema_table(title, schema)

  defp property_rows(properties, required) when is_map(properties) do
    properties
    |> Enum.sort_by(fn {name, _definition} -> name end)
    |> Enum.map(&property_row(&1, required))
  end

  defp property_rows(_properties, _required), do: []

  defp property_row({name, definition}, required) do
    definition = if is_map(definition), do: definition, else: %{}

    [
      name,
      schema_type(definition),
      if(name in required, do: "Yes", else: "No"),
      Map.get(definition, "description", ""),
      schema_rules(definition, ["type", "description"])
    ]
  end

  defp schema_type(%{"type" => type}) when is_binary(type), do: type
  defp schema_type(%{"type" => types}) when is_list(types), do: Enum.join(types, " | ")
  defp schema_type(%{"$ref" => reference}), do: "$ref " <> to_string(reference)
  defp schema_type(_schema), do: "Any"

  defp schema_rules(schema, excluded) do
    schema
    |> Map.drop(excluded)
    |> Enum.sort_by(fn {name, _value} -> name end)
    |> Enum.map_join(", ", fn {name, value} -> "#{name}=#{JSON.encode!(value)}" end)
    |> case do
      "" -> "None"
      rules -> rules
    end
  end

  defp argument_table([]), do: "No arguments."

  defp argument_table(arguments) do
    rows =
      arguments
      |> Enum.sort_by(&Map.get(&1, "name", ""))
      |> Enum.map(fn argument ->
        [
          Map.get(argument, "name", ""),
          if(Map.get(argument, "required", false), do: "Yes", else: "No"),
          Map.get(argument, "description", "")
        ]
      end)

    table(["Argument", "Required", "Description"], rows)
  end

  defp details(fields) do
    rows = for {name, value} <- fields, not is_nil(value), do: [name, value]
    if rows == [], do: nil, else: table(["Field", "Value"], rows)
  end

  defp annotations(item) do
    case Map.get(item, "annotations", %{}) do
      values when is_map(values) and map_size(values) > 0 ->
        rows =
          values
          |> Enum.sort_by(fn {name, _value} -> name end)
          |> Enum.map(fn {name, value} -> [name, JSON.encode!(value)] end)

        "#### Annotations\n\n" <> table(["Name", "Value"], rows)

      _other ->
        nil
    end
  end

  defp coverage(tools, resources, templates, prompts) do
    components =
      Enum.flat_map(
        [
          {"tool", tools},
          {"resource", resources},
          {"resource template", templates},
          {"prompt", prompts}
        ],
        fn {kind, items} -> Enum.map(items, &{kind, &1}) end
      )

    missing_components =
      for {kind, item} <- components,
          missing_description?(item),
          do: "#{kind} #{Map.get(item, "name", "unnamed")}"

    arguments =
      Enum.flat_map(tools, &tool_arguments/1) ++ Enum.flat_map(prompts, &prompt_arguments/1)

    missing_arguments =
      for {name, argument} <- arguments, missing_description?(argument), do: name

    [
      "## Documentation coverage",
      table(
        ["Item", "Missing", "Total"],
        [
          ["Component descriptions", length(missing_components), length(components)],
          ["Argument descriptions", length(missing_arguments), length(arguments)]
        ]
      ),
      missing_list("Components missing descriptions", missing_components),
      missing_list("Arguments missing descriptions", missing_arguments)
    ]
    |> Enum.join("\n\n")
  end

  defp missing_description?(item) when is_map(item) do
    value = Map.get(item, "description")
    not is_binary(value) or String.trim(value) == ""
  end

  defp missing_description?(_item), do: true

  defp tool_arguments(tool) do
    properties = get_in(tool, ["inputSchema", "properties"])

    if is_map(properties) do
      Enum.map(properties, fn {name, definition} ->
        {"tool #{Map.get(tool, "name", "unnamed")}.#{name}", definition}
      end)
    else
      []
    end
  end

  defp prompt_arguments(prompt) do
    Enum.map(Map.get(prompt, "arguments", []), fn argument ->
      {"prompt #{Map.get(prompt, "name", "unnamed")}.#{Map.get(argument, "name", "unnamed")}",
       argument}
    end)
  end

  defp missing_list(title, []), do: "#{title}: none."

  defp missing_list(title, names) do
    "#{title}:\n" <> Enum.map_join(Enum.sort(names), "\n", &("- " <> escape(&1)))
  end

  defp table(headers, rows) do
    separator = "| " <> Enum.map_join(headers, " | ", fn _header -> "---" end) <> " |"
    [table_row(headers), separator | Enum.map(rows, &table_row/1)] |> Enum.join("\n")
  end

  defp table_row(cells), do: "| " <> Enum.map_join(cells, " | ", &escape/1) <> " |"

  defp escape(value) when is_binary(value) do
    value
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\r", " ")
    |> String.replace("\n", " ")
    |> then(
      &Regex.replace(~r/[\\`*_{}\[\]()#+\-.!>|~]/u, &1, fn character -> "\\" <> character end)
    )
  end

  defp escape(value), do: value |> to_string() |> escape()
end
