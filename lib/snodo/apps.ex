defmodule Snodo.Apps do
  @moduledoc """
  Shapes for the MCP Apps extension (`io.modelcontextprotocol/ui`,
  specification 2026-01-26).

  MCP Apps links a tool to a `ui://` resource holding an HTML document that the
  host renders. The extension adds no methods: the server declares it, links
  tools through `_meta`, and serves the resource. These functions return the
  plain values the existing options take:

      use Snodo.Server,
        name: "weather",
        version: "1.0.0",
        extensions: [Snodo.Apps.extension()]

      tool "forecast", metadata: Snodo.Apps.tool_metadata("ui://weather/forecast") do
        @impl true
        def call(_arguments, _context), do: {:ok, "Sunny, 21 C"}
      end

      resource "forecast_view",
        uri: "ui://weather/forecast",
        mime_type: "text/html;profile=mcp-app" do
        @impl true
        def read(_params, _context) do
          {:ok,
           Snodo.Result.resource_read(
             Snodo.Apps.html("ui://weather/forecast", @html,
               csp: [connect_domains: ["https://api.example.com"]],
               prefers_border: true
             )
           )}
        end
      end

  A host without MCP Apps ignores `_meta.ui` and shows the tool's content, so
  a tool's result stays meaningful as text. `supported?/1` tells a handler
  whether the client declared the extension, for a handler that returns
  something different to such a client.

  The extension is negotiated through `capabilities["extensions"]`, which
  only the 2026-07-28 dialect carries. On the initialize-era dialects
  `supported?/1` is `false`.
  """

  alias Snodo.Context
  alias Snodo.Resource

  @id "io.modelcontextprotocol/ui"
  @mime_type "text/html;profile=mcp-app"
  @visibility %{model: "model", app: "app"}
  @permissions %{
    camera: "camera",
    microphone: "microphone",
    geolocation: "geolocation",
    clipboard_write: "clipboardWrite"
  }
  @csp %{
    connect_domains: "connectDomains",
    resource_domains: "resourceDomains",
    frame_domains: "frameDomains",
    base_uri_domains: "baseUriDomains"
  }

  @type visibility :: :model | :app
  @type permission :: :camera | :microphone | :geolocation | :clipboard_write

  @doc "The extension id, `\"io.modelcontextprotocol/ui\"`."
  @spec id() :: String.t()
  def id, do: @id

  @doc "The MIME type of an MCP Apps HTML resource, `\"text/html;profile=mcp-app\"`."
  @spec mime_type() :: String.t()
  def mime_type, do: @mime_type

  @doc "The declared extension for `use Snodo.Server, extensions: [...]`."
  @spec extension() :: {:declared, String.t(), map()}
  def extension, do: {:declared, @id, %{}}

  @doc """
  The client side of the declaration, for `Snodo.Client`'s
  `:client_capabilities`: the extension with `mimeTypes` listing
  `mime_type/0`.
  """
  @spec client_capabilities() :: map()
  def client_capabilities, do: %{"extensions" => %{@id => %{"mimeTypes" => [@mime_type]}}}

  @doc """
  Returns whether the client declared the extension with `mime_type/0` in
  its `mimeTypes`.
  """
  @spec supported?(Context.t()) :: boolean()
  def supported?(%Context{} = context) do
    case Context.extension_settings(context, @id) do
      %{"mimeTypes" => types} when is_list(types) -> @mime_type in types
      _other -> false
    end
  end

  @doc """
  The tool `_meta` that links a tool to the UI resource at `resource_uri`.

  ## Options

    * `:visibility` - who may call the tool, a non-empty list of `:model`
      and `:app`. A tool with `[:app]` is hidden from the model and callable
      only from the UI. Omitted, hosts treat it as `[:model, :app]`.
  """
  @spec tool_metadata(String.t(), keyword()) :: map()
  def tool_metadata(resource_uri, opts \\ []) when is_list(opts) do
    validate_uri!(resource_uri)
    opts = validate_options!(opts, [:visibility])

    ui =
      case Keyword.fetch(opts, :visibility) do
        {:ok, visibility} -> %{"visibility" => visibility!(visibility)}
        :error -> %{}
      end

    %{"ui" => Map.put(ui, "resourceUri", resource_uri)}
  end

  @doc """
  The `_meta` of a UI resource: its Content Security Policy, permissions,
  sandbox domain, and border preference. Returns `%{}` when no option is
  given.

  ## Options

    * `:csp` - keyword list of origin lists: `:connect_domains` (fetch, XHR,
      WebSocket), `:resource_domains` (scripts, images, styles, fonts),
      `:frame_domains` (nested iframes), and `:base_uri_domains`. Without it
      the host allows no external origins.
    * `:permissions` - list of `:camera`, `:microphone`, `:geolocation`, and
      `:clipboard_write`.
    * `:domain` - a dedicated sandbox origin, in the format the host
      documents.
    * `:prefers_border` - whether the host should draw a border and
      background.
  """
  @spec resource_metadata(keyword()) :: map()
  def resource_metadata(opts \\ []) when is_list(opts) do
    opts = validate_options!(opts, [:csp, :permissions, :domain, :prefers_border])

    ui =
      Enum.reduce(opts, %{}, fn
        {:csp, csp}, ui -> Map.put(ui, "csp", csp!(csp))
        {:permissions, permissions}, ui -> Map.put(ui, "permissions", permissions!(permissions))
        {:domain, domain}, ui -> Map.put(ui, "domain", string!(domain, ":domain"))
        {:prefers_border, border}, ui -> Map.put(ui, "prefersBorder", boolean!(border))
      end)

    if ui == %{}, do: %{}, else: %{"ui" => ui}
  end

  @doc """
  A `resources/read` content map for the HTML document `html` at the `ui://`
  URI `uri`, with `mime_type/0` and the `_meta` from `resource_metadata/1`,
  which takes the same options.
  """
  @spec html(String.t(), String.t(), keyword()) :: map()
  def html(uri, html, opts \\ []) when is_binary(html) and is_list(opts) do
    validate_uri!(uri)
    Resource.text(uri, html, mime_type: @mime_type, metadata: resource_metadata(opts))
  end

  defp validate_uri!("ui://" <> rest) when rest != "", do: :ok

  defp validate_uri!(uri),
    do:
      raise(ArgumentError, "an MCP Apps resource URI must start with ui://, got: #{inspect(uri)}")

  defp validate_options!(opts, allowed) do
    case Keyword.keys(opts) -- allowed do
      [] -> opts
      unknown -> raise ArgumentError, "unknown MCP Apps options: #{inspect(unknown)}"
    end
  end

  defp visibility!([_ | _] = visibility),
    do: Enum.uniq(Enum.map(visibility, &fetch!(@visibility, &1, ":visibility")))

  defp visibility!(other),
    do: raise(ArgumentError, ":visibility must be a non-empty list, got: #{inspect(other)}")

  defp permissions!(permissions) when is_list(permissions),
    do: Map.new(permissions, &{fetch!(@permissions, &1, ":permissions"), %{}})

  defp permissions!(other),
    do: raise(ArgumentError, ":permissions must be a list, got: #{inspect(other)}")

  defp csp!(csp) when is_list(csp) do
    Map.new(csp, fn {key, domains} ->
      {fetch!(@csp, key, ":csp"), domains!(domains, key)}
    end)
  end

  defp csp!(other),
    do: raise(ArgumentError, ":csp must be a keyword list, got: #{inspect(other)}")

  defp domains!(domains, key) when is_list(domains) do
    Enum.each(domains, &string!(&1, ":csp #{inspect(key)}"))
    domains
  end

  defp domains!(other, key),
    do:
      raise(
        ArgumentError,
        ":csp #{inspect(key)} must be a list of origins, got: #{inspect(other)}"
      )

  defp fetch!(names, key, label) do
    case Map.fetch(names, key) do
      {:ok, name} -> name
      :error -> raise ArgumentError, "unknown #{label} value: #{inspect(key)}"
    end
  end

  defp string!(value, _label) when is_binary(value) and value != "", do: value

  defp string!(value, label),
    do: raise(ArgumentError, "#{label} must be a non-empty string, got: #{inspect(value)}")

  defp boolean!(value) when is_boolean(value), do: value

  defp boolean!(value),
    do: raise(ArgumentError, ":prefers_border must be a boolean, got: #{inspect(value)}")
end
