defmodule Examples.MCPApps.Server do
  @moduledoc false
  use Snodo.Server,
    name: "mcp-apps-example",
    version: "1.0.0",
    extensions: [Snodo.Apps.extension()]

  tool "forecast",
    description: "Today's forecast for a city",
    metadata: Snodo.Apps.tool_metadata("ui://weather/forecast") do
    argument("city", :string, required: true)

    @impl true
    def call(%{"city" => city}, context) do
      # A host without MCP Apps shows text. One that declared the extension
      # gets the reading as structured content for the UI.
      if Snodo.Apps.supported?(context) do
        {:ok, Snodo.Result.structured(%{"city" => city, "celsius" => 21})}
      else
        {:ok, "#{city}: sunny, 21 C"}
      end
    end
  end

  tool "refresh_forecast",
    description: "Called from the forecast view only",
    metadata: Snodo.Apps.tool_metadata("ui://weather/forecast", visibility: [:app]) do
    @impl true
    def call(_arguments, _context), do: {:ok, "refreshed"}
  end

  resource "forecast_view",
    uri: "ui://weather/forecast",
    mime_type: "text/html;profile=mcp-app" do
    @html """
    <!doctype html>
    <html><body><div id="forecast"></div></body></html>
    """

    @impl true
    def read(_params, _context) do
      content =
        Snodo.Apps.html("ui://weather/forecast", @html,
          csp: [connect_domains: ["https://api.weather.example"]],
          prefers_border: true
        )

      {:ok, Snodo.Result.resource_read(content)}
    end
  end
end

defmodule Examples.MCPApps.Runner do
  @moduledoc false

  alias Examples.MCPApps.Server
  alias Snodo.Client

  def run(args) do
    check? = check_mode!(args)

    # A host that renders MCP Apps declares the extension.
    {:ok, host} =
      Client.direct(Server.runtime(), client_capabilities: Snodo.Apps.client_capabilities())

    {:ok, discovery} = Client.discover(host)
    ensure(Map.has_key?(discovery["capabilities"]["extensions"], Snodo.Apps.id()), "declared")

    {:ok, tools} = Client.list_tools(host)
    forecast = Enum.find(tools, &(&1["name"] == "forecast"))
    refresh = Enum.find(tools, &(&1["name"] == "refresh_forecast"))
    ensure(forecast["_meta"]["ui"] == %{"resourceUri" => "ui://weather/forecast"}, "tool link")
    ensure(refresh["_meta"]["ui"]["visibility"] == ["app"], "app-only tool")

    {:ok, %{"contents" => [view]}} = Client.read_resource(host, "ui://weather/forecast")
    ensure(view["mimeType"] == Snodo.Apps.mime_type(), "view MIME type")

    ensure(
      view["_meta"]["ui"] == %{
        "csp" => %{"connectDomains" => ["https://api.weather.example"]},
        "prefersBorder" => true
      },
      "view CSP"
    )

    {:ok, rich} = Client.call_tool(host, "forecast", %{"city" => "Lisbon"})
    ensure(rich["structuredContent"] == %{"city" => "Lisbon", "celsius" => 21}, "UI data")

    # A host without MCP Apps gets the same catalog and plain text.
    {:ok, plain_host} = Client.direct(Server.runtime())
    {:ok, plain} = Client.call_tool(plain_host, "forecast", %{"city" => "Lisbon"})
    ensure(plain["content"] == [%{"type" => "text", "text" => "Lisbon: sunny, 21 C"}], "plain")
    ensure(not Map.has_key?(plain, "structuredContent"), "no UI data")

    if check? do
      IO.puts("35_mcp_apps: ok")
    else
      IO.puts("forecast links to #{forecast["_meta"]["ui"]["resourceUri"]}")
      IO.puts("view: #{view["mimeType"]}, #{byte_size(view["text"])} bytes")
      IO.puts("with MCP Apps: #{inspect(rich["structuredContent"])}")
      IO.puts("without: #{hd(plain["content"])["text"]}")
    end
  end

  defp ensure(true, _label), do: :ok
  defp ensure(false, label), do: raise("check failed: #{label}")

  defp check_mode!([]), do: false
  defp check_mode!(["--check"]), do: true

  defp check_mode!(_arguments),
    do: raise("usage: mix run examples/35_mcp_apps.exs [--check]")
end

Examples.MCPApps.Runner.run(System.argv())
