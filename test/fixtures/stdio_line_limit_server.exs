# A stdio MCP server for the long-line tests. It takes :max_line_bytes from
# SNODO_MAX_LINE_BYTES, samples VM memory every 2 ms, and reports the largest
# growth over its first sample through the "memory" tool. Run it as
#   elixir -pa <snodo ebin> test/fixtures/stdio_line_limit_server.exs

defmodule SnodoTest.LineLimitFixture.Memory do
  use Snodo.Tool, name: "memory", description: "Reports the peak memory growth"

  @impl true
  def call(_arguments, _context) do
    {baseline, peak} = Agent.get(:line_limit_memory, & &1)
    {:ok, Snodo.Result.structured(%{"growth" => peak - baseline})}
  end
end

defmodule SnodoTest.LineLimitFixture.Sampler do
  def run do
    memory = :erlang.memory(:total)
    Agent.update(:line_limit_memory, fn {first, peak} -> {first, max(peak, memory)} end)
    Process.sleep(2)
    run()
  end
end

memory = :erlang.memory(:total)
{:ok, _agent} = Agent.start_link(fn -> {memory, memory} end, name: :line_limit_memory)
spawn_link(&SnodoTest.LineLimitFixture.Sampler.run/0)

router = Snodo.Router.register_tool(Snodo.Router.new(), SnodoTest.LineLimitFixture.Memory)

runtime =
  Snodo.Server.Runtime.new(
    router: router,
    protocols: [Snodo.Protocol.V2026_07_28],
    server_info: %{"name" => "stdio-line-limit-fixture", "version" => "0.1.0"}
  )

max_line_bytes = "SNODO_MAX_LINE_BYTES" |> System.fetch_env!() |> String.to_integer()

case Snodo.Transport.Stdio.serve(runtime, max_line_bytes: max_line_bytes) do
  :ok -> :ok
  {:error, reason} -> raise "stdio line limit fixture failed: #{inspect(reason)}"
end
