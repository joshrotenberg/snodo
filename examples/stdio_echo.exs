defmodule Example.Echo do
  use Snodo.Tool,
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

    {:ok, Snodo.Result.text(text)}
  end
end

defmodule Example.Server do
  use Snodo.Server,
    name: "stdio-echo",
    version: "0.1.0",
    protocols: [Snodo.Protocol.V2026_07_28]

  tool(Example.Echo)
end

:ok = Snodo.Transport.Stdio.serve(Example.Server.runtime())
