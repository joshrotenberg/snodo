defmodule Examples.InlineComponents.Search do
  @moduledoc false

  use Snodo.Tool.Simple, name: "search", description: "Search a fixed package list"

  argument("query", :string, required: true)

  @packages ["jason", "plug", "phoenix", "req"]

  @impl true
  def call(%{"query" => query}, _context) do
    {:ok, %{"matches" => Enum.filter(@packages, &String.contains?(&1, query))}}
  end
end

# Inline blocks generate one module per component, registered exactly like the
# module component above. Handlers may return plain values: a string is text,
# and any other JSON value is structured content or a JSON resource.
defmodule Examples.InlineComponents.Server do
  @moduledoc false

  use Snodo.Server, name: "inline-components-example", version: "0.1.0"

  tool "greet", description: "Create a greeting" do
    argument("name", :string, required: true)

    @impl true
    def call(%{"name" => name}, _context), do: {:ok, "Hello, #{name}!"}
  end

  resource "package_info", uri_template: "hex://{name}/info", mime_type: "application/json" do
    @impl true
    def read(%{"name" => name}, _context), do: {:ok, %{"name" => name, "source" => "example"}}
  end

  prompt "review", description: "Review a package" do
    argument("name", required: true, description: "Package name")
    argument("focus", description: "quality, security, or upgrade")

    @impl true
    def render(%{"name" => name} = arguments, _context) do
      {:ok, "Review #{name} with a focus on #{arguments["focus"] || "quality"}."}
    end
  end

  tool(Examples.InlineComponents.Search)
end

defmodule Examples.InlineComponents.Runner do
  @moduledoc false

  alias Examples.InlineComponents.Server
  alias Snodo.Client

  def run(args) do
    check? = check_mode!(args)
    {:ok, client} = Client.direct(Server.runtime())

    {:ok, tools} = Client.list_tools(client)
    {:ok, [template]} = Client.list_resource_templates(client)
    {:ok, [prompt]} = Client.list_prompts(client)

    {:ok, %{"content" => [%{"text" => greeting}]}} =
      Client.call_tool(client, "greet", %{"name" => "Ada"})

    {:ok, %{"structuredContent" => %{"matches" => matches}}} =
      Client.call_tool(client, "search", %{"query" => "ph"})

    {:ok, %{"contents" => [info]}} = Client.read_resource(client, "hex://jason/info")
    {:ok, %{"messages" => [message]}} = Client.get_prompt(client, "review", %{"name" => "req"})

    ensure(Enum.map(tools, & &1["name"]) == ["greet", "search"], "tools were not listed")
    ensure(template["uriTemplate"] == "hex://{name}/info", "template was not listed")
    ensure(Enum.map(prompt["arguments"], & &1["name"]) == ["name", "focus"], "prompt arguments")
    ensure(greeting == "Hello, Ada!", "inline tool text")
    ensure(matches == ["phoenix"], "module tool structured content")
    ensure(info["mimeType"] == "application/json", "inline resource MIME type")
    ensure(JSON.decode!(info["text"]) == %{"name" => "jason", "source" => "example"}, "resource")

    ensure(
      message["content"]["text"] == "Review req with a focus on quality.",
      "inline prompt text"
    )

    ensure(Code.ensure_loaded?(Server.Tools.Greet), "generated tool module")

    if check? do
      IO.puts("25_inline_components: ok")
    else
      IO.puts("Inline and module components in one server:\n")
      IO.puts("  tools: #{Enum.map_join(tools, ", ", & &1["name"])}")
      IO.puts("  greet -> #{inspect(greeting)}")
      IO.puts("  search \"ph\" -> #{inspect(matches)}")
      IO.puts("  hex://jason/info -> #{info["text"]}")
      IO.puts("  review -> #{inspect(message["content"]["text"])}")

      IO.puts(
        "  generated modules: #{inspect(Server.Tools.Greet)}, #{inspect(Server.Prompts.Review)}"
      )
    end
  end

  defp ensure(true, _label), do: :ok
  defp ensure(false, label), do: raise("check failed: #{label}")

  defp check_mode!([]), do: false
  defp check_mode!(["--check"]), do: true

  defp check_mode!(_arguments),
    do: raise("usage: mix run examples/25_inline_components.exs [--check]")
end

Examples.InlineComponents.Runner.run(System.argv())
