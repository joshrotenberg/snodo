unless Code.ensure_loaded?(MCP.Extensions.Tasks) do
  raise "start the combined fixture from extensions/tasks so :mcp_ex_tasks is available"
end

Code.require_file("support/tasks.ex", __DIR__)
Code.require_file("support/fixture.ex", __DIR__)

port =
  case Integer.parse(System.get_env("MCP_PORT", "3001")) do
    {value, ""} when value in 1..65_535 -> value
    _invalid -> raise "MCP_PORT must be an integer from 1 to 65535"
  end

{:ok, server} =
  MCP.Transport.StreamableHTTP.Server.start_link(
    runtime: MCPEx.Conformance.Fixture.runtime(),
    ip: {127, 0, 0, 1},
    port: port,
    path: "/mcp",
    max_concurrency: 32,
    max_queue: 256
  )

IO.puts(
  :stderr,
  "MCP conformance fixture listening at #{MCP.Transport.StreamableHTTP.Server.url(server)}"
)

Process.sleep(:infinity)
