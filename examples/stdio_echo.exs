defmodule Example.Echo do
  use MCP.Tool,
    name: "echo",
    description: "Echo text"

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
    case Map.get(arguments, "delayMs", 0) do
      delay when is_integer(delay) and delay > 0 -> Process.sleep(delay)
      _no_delay -> :ok
    end

    {:ok, MCP.Result.text(text)}
  end
end

defmodule Example.Server do
  use MCP.Server,
    name: "stdio-echo",
    version: "0.1.0",
    protocols: [MCP.Protocol.V2026_07_28]

  tool(Example.Echo)
end

:ok = MCP.Transport.Stdio.serve(Example.Server.runtime())
