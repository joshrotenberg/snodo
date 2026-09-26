unless Code.ensure_loaded?(Snodo.Extensions.Tasks) do
  raise "start the combined fixture from extensions/tasks so :snodo_tasks is available"
end

Code.require_file("support/tasks.ex", __DIR__)
Code.require_file("support/fixture.ex", __DIR__)

port =
  case Integer.parse(System.get_env("MCP_PORT", "3001")) do
    {value, ""} when value in 0..65_535 -> value
    _invalid -> raise "MCP_PORT must be an integer from 0 to 65535"
  end

{:ok, _hub} = Snodo.Subscription.Hub.start_link(name: SnodoTest.Conformance.Stateless.hub())

{:ok, server} =
  Snodo.Transport.StreamableHTTP.Server.start_link(
    runtime: SnodoTest.Conformance.Fixture.runtime(),
    ip: {127, 0, 0, 1},
    port: port,
    path: "/mcp",
    max_concurrency: 32,
    max_queue: 256
  )

url = Snodo.Transport.StreamableHTTP.Server.url(server)

if System.get_env("MCP_CONFORMANCE_MANAGED") == "1" do
  IO.puts(JSON.encode!(%{"conformanceReady" => true, "url" => url}))
  _input = IO.read(:stdio, :eof)
  :ok = GenServer.stop(server)
else
  IO.puts(:stderr, "MCP conformance fixture listening at #{url}")
  Process.sleep(:infinity)
end
