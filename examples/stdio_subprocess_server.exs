defmodule SnodoTest.StdioSubprocessFixture.NoisyTool do
  use Snodo.Tool,
    name: "noisy",
    description: "Writes diagnostics before returning a protocol result"

  require Logger

  input_schema(%{
    "type" => "object",
    "properties" => %{"text" => %{"type" => "string"}},
    "required" => ["text"],
    "additionalProperties" => false
  })

  @impl true
  def call(%{"text" => text}, _context) do
    Logger.info("STDIO_FIXTURE_LOGGER")
    IO.puts("STDIO_FIXTURE_RAW_IO")
    Logger.flush()

    {:ok, Snodo.Result.text(text)}
  end
end

router =
  Snodo.Router.new()
  |> Snodo.Router.register_tool(SnodoTest.StdioSubprocessFixture.NoisyTool)

runtime =
  Snodo.Server.Runtime.new(
    router: router,
    protocols: [Snodo.Protocol.V2026_07_28],
    server_info: %{"name" => "stdio-subprocess-fixture", "version" => "0.1.0"}
  )

case Snodo.Transport.Stdio.serve(runtime) do
  :ok -> :ok
  {:error, reason} -> raise "stdio fixture failed: #{inspect(reason)}"
end
