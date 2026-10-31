defmodule Snodo.AppsTest do
  use ExUnit.Case, async: true

  alias Snodo.Apps
  alias Snodo.Client

  @uri "ui://weather/forecast"

  defmodule Server do
    use Snodo.Server,
      name: "apps-test",
      version: "1.0.0",
      extensions: [Snodo.Apps.extension()]

    tool "forecast", metadata: Snodo.Apps.tool_metadata("ui://weather/forecast") do
      @impl true
      def call(_arguments, context), do: {:ok, inspect(Snodo.Apps.supported?(context))}
    end

    resource "forecast_view",
      uri: "ui://weather/forecast",
      mime_type: "text/html;profile=mcp-app" do
      @impl true
      def read(_params, _context) do
        {:ok,
         Snodo.Result.resource_read(
           Snodo.Apps.html("ui://weather/forecast", "<p>sun</p>", permissions: [:geolocation])
         )}
      end
    end
  end

  describe "tool_metadata/2" do
    test "links a tool to its resource" do
      assert Apps.tool_metadata(@uri) == %{"ui" => %{"resourceUri" => @uri}}
    end

    test "carries visibility as the specification's strings" do
      assert Apps.tool_metadata(@uri, visibility: [:app]) ==
               %{"ui" => %{"resourceUri" => @uri, "visibility" => ["app"]}}

      assert Apps.tool_metadata(@uri, visibility: [:model, :app, :app])["ui"]["visibility"] ==
               ["model", "app"]
    end

    test "rejects a non-ui URI, unknown visibility, and unknown options" do
      assert_raise ArgumentError, ~r/must start with ui:\/\//, fn ->
        Apps.tool_metadata("https://example.com")
      end

      assert_raise ArgumentError, ~r/ui:\/\//, fn -> Apps.tool_metadata("ui://") end

      assert_raise ArgumentError, ~r/:visibility value: :user/, fn ->
        Apps.tool_metadata(@uri, visibility: [:user])
      end

      assert_raise ArgumentError, ~r/non-empty list/, fn ->
        Apps.tool_metadata(@uri, visibility: [])
      end

      assert_raise ArgumentError, ~r/unknown MCP Apps options: \[:hidden\]/, fn ->
        Apps.tool_metadata(@uri, hidden: true)
      end
    end
  end

  describe "resource_metadata/1" do
    test "is empty without options" do
      assert Apps.resource_metadata() == %{}
    end

    test "maps every option to the specification's keys" do
      assert Apps.resource_metadata(
               csp: [
                 connect_domains: ["https://api.example.com"],
                 resource_domains: ["https://cdn.example.com"],
                 frame_domains: ["https://embed.example.com"],
                 base_uri_domains: ["https://example.com"]
               ],
               permissions: [:camera, :microphone, :geolocation, :clipboard_write],
               domain: "abc.example-content.com",
               prefers_border: false
             ) == %{
               "ui" => %{
                 "csp" => %{
                   "connectDomains" => ["https://api.example.com"],
                   "resourceDomains" => ["https://cdn.example.com"],
                   "frameDomains" => ["https://embed.example.com"],
                   "baseUriDomains" => ["https://example.com"]
                 },
                 "permissions" => %{
                   "camera" => %{},
                   "microphone" => %{},
                   "geolocation" => %{},
                   "clipboardWrite" => %{}
                 },
                 "domain" => "abc.example-content.com",
                 "prefersBorder" => false
               }
             }
    end

    test "rejects malformed values" do
      assert_raise ArgumentError, ~r/:csp value: :script_domains/, fn ->
        Apps.resource_metadata(csp: [script_domains: []])
      end

      assert_raise ArgumentError, ~r/list of origins/, fn ->
        Apps.resource_metadata(csp: [connect_domains: "https://api.example.com"])
      end

      assert_raise ArgumentError, ~r/non-empty string/, fn ->
        Apps.resource_metadata(csp: [connect_domains: [""]])
      end

      assert_raise ArgumentError, ~r/:permissions value: :usb/, fn ->
        Apps.resource_metadata(permissions: [:usb])
      end

      assert_raise ArgumentError, ~r/:prefers_border/, fn ->
        Apps.resource_metadata(prefers_border: "yes")
      end
    end
  end

  test "html/3 builds a resource content with the MIME type and metadata" do
    assert Apps.html(@uri, "<p>sun</p>", prefers_border: true) == %{
             "uri" => @uri,
             "mimeType" => "text/html;profile=mcp-app",
             "text" => "<p>sun</p>",
             "_meta" => %{"ui" => %{"prefersBorder" => true}}
           }

    refute Map.has_key?(Apps.html(@uri, "<p>sun</p>"), "_meta")
    assert_raise ArgumentError, fn -> Apps.html("file:///view.html", "<p>sun</p>") end
  end

  describe "over the router" do
    test "the server advertises the extension and serves the linked tool and view" do
      {:ok, client} =
        Client.direct(Server.runtime(), client_capabilities: Apps.client_capabilities())

      {:ok, discovery} = Client.discover(client)
      assert discovery["capabilities"]["extensions"] == %{"io.modelcontextprotocol/ui" => %{}}

      {:ok, [tool]} = Client.list_tools(client)
      assert tool["_meta"] == %{"ui" => %{"resourceUri" => @uri}}

      {:ok, [resource]} = Client.list_resources(client)
      assert resource["mimeType"] == Apps.mime_type()

      {:ok, %{"contents" => [content]}} = Client.read_resource(client, @uri)
      assert content["_meta"] == %{"ui" => %{"permissions" => %{"geolocation" => %{}}}}
    end

    test "supported?/1 follows the client's mimeTypes" do
      for {capabilities, expected} <- [
            {Apps.client_capabilities(), "true"},
            {%{}, "false"},
            {%{"extensions" => %{Apps.id() => %{"mimeTypes" => ["text/html"]}}}, "false"},
            {%{"extensions" => %{Apps.id() => %{}}}, "false"}
          ] do
        {:ok, client} = Client.direct(Server.runtime(), client_capabilities: capabilities)

        assert {:ok, %{"content" => [%{"text" => ^expected}]}} =
                 Client.call_tool(client, "forecast")
      end
    end
  end
end
