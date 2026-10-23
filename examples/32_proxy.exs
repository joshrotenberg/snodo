defmodule Examples.Proxy.Notes do
  @moduledoc false
  use Snodo.Server, name: "notes", version: "1.0.0"

  tool "search", description: "Search the notes" do
    argument("query", :string, required: true)

    @impl true
    def call(%{"query" => query}, _context), do: {:ok, "notes matching #{query}"}
  end

  resource "today", uri: "notes://today" do
    @impl true
    def read(_params, _context), do: {:ok, "buy milk"}
  end
end

defmodule Examples.Proxy.Calendar do
  @moduledoc false
  use Snodo.Server, name: "calendar", version: "1.0.0"

  tool "search", description: "Search the calendar" do
    argument("query", :string, required: true)

    @impl true
    def call(%{"query" => query}, _context), do: {:ok, "events matching #{query}"}
  end
end

defmodule Examples.Proxy.Runner do
  @moduledoc false

  alias Examples.Proxy.Calendar
  alias Examples.Proxy.Notes
  alias Snodo.Client

  def run(args) do
    check? = check_mode!(args)

    # Both backends have a "search" tool; the proxy prefixes names with each
    # backend id. A backend could be {:http, url} or {:stdio, command, args}.
    {:ok, proxy} =
      Snodo.Proxy.start_link(
        backends: [
          [id: "notes", target: {:direct, Notes.runtime()}],
          [id: "calendar", target: {:direct, Calendar.runtime()}]
        ]
      )

    # Serve Snodo.Proxy.runtime/2 on any transport; a direct client is enough here.
    {:ok, client} = Client.direct(Snodo.Proxy.runtime(proxy))

    {:ok, tools} = Client.list_tools(client)
    names = Enum.map(tools, & &1["name"])
    ensure(names == ["calendar.search", "notes.search"], "merged, prefixed catalog")

    {:ok, %{"content" => [%{"text" => events}]}} =
      Client.call_tool(client, "calendar.search", %{"query" => "standup"})

    ensure(events == "events matching standup", "call routed to its backend")

    # Resources keep their backend in the URI.
    {:ok, [%{"uri" => uri}]} = Client.list_resources(client)
    ensure(uri == "mcp-proxy://notes/notes://today", "resource URI")
    {:ok, %{"contents" => [%{"text" => "buy milk"}]}} = Client.read_resource(client, uri)

    %{"notes" => %{status: :up}, "calendar" => %{status: :up}} = Snodo.Proxy.health(proxy)

    :ok = Snodo.Proxy.remove_backend(proxy, "calendar")
    {:ok, [%{"name" => "notes.search"}]} = Client.list_tools(client)

    if check? do
      IO.puts("32_proxy: ok")
    else
      IO.puts("Tools through the proxy: #{Enum.join(names, ", ")}")
      IO.puts("calendar.search -> #{events}")
      IO.puts("Resource: #{uri}")
    end
  end

  defp ensure(true, _label), do: :ok
  defp ensure(false, label), do: raise("check failed: #{label}")

  defp check_mode!([]), do: false
  defp check_mode!(["--check"]), do: true

  defp check_mode!(_arguments),
    do: raise("usage: mix example.proxy (from integrations/proxy)")
end

Examples.Proxy.Runner.run(System.argv())
