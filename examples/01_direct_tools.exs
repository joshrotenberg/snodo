defmodule Examples.DirectTools.Greet do
  @moduledoc false

  use MCP.Tool,
    name: "greet",
    description: "Create a greeting"

  input_schema(%{
    "type" => "object",
    "properties" => %{"name" => %{"type" => "string"}},
    "required" => ["name"],
    "additionalProperties" => false
  })

  @impl true
  def call(%{"name" => name}, _context), do: {:ok, MCP.Result.text("Hello, #{name}!")}
end

defmodule Examples.DirectTools.Server do
  @moduledoc false

  use MCP.Server,
    name: "direct-tools-example",
    version: "0.1.0",
    protocols: [MCP.Protocol.V2026_07_28]

  tool(Examples.DirectTools.Greet)
end

defmodule Examples.DirectTools.Runner do
  @moduledoc false

  alias Examples.DirectTools.Greet
  alias Examples.DirectTools.Server

  @server_metadata %{
    "io.modelcontextprotocol/serverInfo" => %{
      "name" => "direct-tools-example",
      "version" => "0.1.0"
    }
  }

  def run(args) do
    check? = check_mode!(args)
    {:links, links_before} = Process.info(self(), :links)
    runtime = Server.runtime()

    {:ok, client} = MCP.Client.direct(runtime)
    {:ok, discovery} = MCP.Client.discover(client)
    {:ok, list} = MCP.Client.list_tools(client)
    {:ok, call} = MCP.Client.call_tool(client, "greet", %{"name" => "Ada"})

    {:links, links_after} = Process.info(self(), :links)

    assert_equal(discovery, expected_discovery(), "discovery result")
    assert_equal(list, expected_list(), "tools/list result")
    assert_equal(call, expected_call(), "tools/call result")
    assert_equal(links_after, links_before, "caller links")

    if check? do
      IO.puts("01_direct_tools: ok")
    else
      print_walkthrough(discovery, list, call)
    end
  end

  defp expected_discovery do
    %{
      "resultType" => "complete",
      "supportedVersions" => ["2026-07-28"],
      "capabilities" => %{"tools" => %{}},
      "ttlMs" => 0,
      "cacheScope" => "private",
      "_meta" => @server_metadata
    }
  end

  defp expected_list do
    [
      %{
        "name" => "greet",
        "description" => "Create a greeting",
        "inputSchema" => Greet.input_schema()
      }
    ]
  end

  defp expected_call do
    %{
      "resultType" => "complete",
      "content" => [%{"type" => "text", "text" => "Hello, Ada!"}],
      "isError" => false,
      "_meta" => @server_metadata
    }
  end

  defp print_walkthrough(discovery, list, call) do
    IO.puts("A declarative MCP server can be discovered and called without starting a process.\n")
    IO.puts("Discovery:\n#{inspect(discovery, pretty: true)}\n")
    IO.puts("Tools:\n#{inspect(list, pretty: true)}\n")
    IO.puts("Direct call:\n#{inspect(call, pretty: true)}")
  end

  defp assert_equal(actual, expected, label) do
    unless actual == expected do
      raise "#{label} mismatch\nexpected: #{inspect(expected)}\nactual:   #{inspect(actual)}"
    end
  end

  defp check_mode!([]), do: false
  defp check_mode!(["--check"]), do: true

  defp check_mode!(_arguments),
    do: raise("usage: mix run examples/01_direct_tools.exs [--check]")
end

Examples.DirectTools.Runner.run(System.argv())
