# A stdio MCP server for MCP.Client transport tests. Run it as
#   elixir -pa <mcp_ex ebin> test/fixtures/client_stdio_server.exs

defmodule MCPEx.ClientStdioFixture.Echo do
  use MCP.Tool, name: "echo", description: "Echo text after an optional delay"

  input_schema(%{
    "type" => "object",
    "properties" => %{
      "text" => %{"type" => "string"},
      "delayMs" => %{"type" => "integer", "minimum" => 0}
    },
    "required" => ["text"]
  })

  @impl true
  def call(%{"text" => text} = arguments, _context) do
    Process.sleep(Map.get(arguments, "delayMs", 0))
    {:ok, MCP.Result.text(text)}
  end
end

defmodule MCPEx.ClientStdioFixture.Park do
  use MCP.Tool, name: "park", description: "Registers the worker and waits to be cancelled"

  @impl true
  def call(_arguments, _context) do
    Agent.update(:client_stdio_parked, &[self() | &1])
    Process.sleep(:infinity)
  end
end

defmodule MCPEx.ClientStdioFixture.Parked do
  use MCP.Tool, name: "parked", description: "Counts parked workers that are still alive"

  @impl true
  def call(_arguments, _context) do
    alive = :client_stdio_parked |> Agent.get(& &1) |> Enum.count(&Process.alive?/1)
    {:ok, MCP.Result.structured(%{"alive" => alive})}
  end
end

defmodule MCPEx.ClientStdioFixture.Halt do
  use MCP.Tool, name: "halt", description: "Stops the server VM with exit status 3"

  @impl true
  def call(_arguments, _context), do: System.halt(3)
end

defmodule MCPEx.ClientStdioFixture.Large do
  use MCP.Tool, name: "large", description: "Returns a text result of the requested size"

  @impl true
  def call(%{"bytes" => bytes}, _context) do
    {:ok, MCP.Result.text(String.duplicate("x", bytes))}
  end
end

{:ok, _agent} = Agent.start_link(fn -> [] end, name: :client_stdio_parked)

router =
  Enum.reduce(
    [
      MCPEx.ClientStdioFixture.Echo,
      MCPEx.ClientStdioFixture.Park,
      MCPEx.ClientStdioFixture.Parked,
      MCPEx.ClientStdioFixture.Halt,
      MCPEx.ClientStdioFixture.Large
    ],
    MCP.Router.new(),
    &MCP.Router.register_tool(&2, &1)
  )

runtime =
  MCP.Server.Runtime.new(
    router: router,
    protocols: [MCP.Protocol.V2026_07_28],
    server_info: %{"name" => "client-stdio-fixture", "version" => "0.1.0"}
  )

case MCP.Transport.Stdio.serve(runtime) do
  :ok -> :ok
  {:error, reason} -> raise "client stdio fixture failed: #{inspect(reason)}"
end
