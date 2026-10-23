defmodule Snodo.DeclaredExtensionTest do
  use ExUnit.Case, async: true

  alias Snodo.Client
  alias Snodo.Protocol.V2025_11_25
  alias Snodo.Protocol.V2026_07_28
  alias Snodo.Server.Runtime
  alias SnodoTest.TestExtensions.Echo

  @ui "io.modelcontextprotocol/ui"

  defmodule Server do
    use Snodo.Server,
      name: "declared-extension-test",
      version: "1.0.0",
      extensions: [{:declared, "io.modelcontextprotocol/ui", %{"version" => "1"}}]

    tool "chart" do
      @impl true
      def call(_arguments, context) do
        case Snodo.Context.extension_settings(context, "io.modelcontextprotocol/ui") do
          nil -> {:ok, "text"}
          settings -> {:ok, Snodo.Result.structured(%{"rich" => settings})}
        end
      end
    end
  end

  defp runtime(opts) do
    [
      router: Server.router(),
      server_info: %{"name" => "t", "version" => "1"},
      protocols: [V2026_07_28]
    ]
    |> Keyword.merge(opts)
    |> Runtime.new()
  end

  test "a declared extension is advertised with its server settings" do
    {:ok, client} = Client.direct(Server.runtime())
    {:ok, discovery} = Client.discover(client)

    assert discovery["capabilities"]["extensions"] == %{@ui => %{"version" => "1"}}
  end

  test "the handler sees the client's settings only when the client declared the extension" do
    {:ok, plain} = Client.direct(Server.runtime())
    assert {:ok, %{"content" => [%{"text" => "text"}]}} = Client.call_tool(plain, "chart")

    client_settings = %{"mimeTypes" => ["text/html"]}

    {:ok, rich} =
      Client.direct(Server.runtime(),
        client_capabilities: %{"extensions" => %{@ui => client_settings}}
      )

    assert {:ok, %{"structuredContent" => %{"rich" => ^client_settings}}} =
             Client.call_tool(rich, "chart")
  end

  test "an explicit capabilities entry wins over the declared settings" do
    runtime =
      runtime(
        extensions: [{:declared, @ui, %{"version" => "1"}}],
        capabilities: %{"tools" => %{}, "extensions" => %{@ui => %{"version" => "2"}}}
      )

    assert runtime.capabilities["extensions"] == %{@ui => %{"version" => "2"}}
  end

  test "declared extensions sit next to installed modules and initialize-era dialects" do
    runtime =
      runtime(
        protocols: [V2026_07_28, V2025_11_25],
        extensions: [Echo, {:declared, @ui, %{}}],
        capabilities: %{"tools" => %{}, "extensions" => %{Echo.id() => %{}}}
      )

    assert runtime.capabilities["extensions"] == %{Echo.id() => %{}, @ui => %{}}
  end

  test "invalid and duplicate declarations are refused" do
    for {extensions, message} <- [
          {[{:declared, "not namespaced", %{}}], "namespaced"},
          {[{:declared, @ui, ["not", "an", "object"]}], "JSON object"},
          {[{:declared, @ui, %{}}, {:declared, @ui, %{}}], "duplicate"},
          {[Echo, {:declared, Echo.id(), %{}}], "duplicate"}
        ] do
      assert_raise ArgumentError, ~r/#{message}/, fn -> runtime(extensions: extensions) end
    end
  end
end
