# The official runner's server fixture. Start it from conformance/fixture so
# the core, Tasks, and the Plug adapter with Bandit are all on the code path:
#
#     cd conformance/fixture
#     MCP_PORT=3001 mix run ../fixture_server.exs
#
# MCP_FIXTURE_PROFILE picks the runtime: "latest" (default) is the combined
# 2026-07-28 fixture with Tasks, input_required, and subscriptions; "legacy"
# enables the initialize-era dialects next to 2026-07-28. MCP_FIXTURE_TRANSPORT
# picks the listener: "native" (default) or "plug" for Snodo.Transport.Plug
# on Bandit.

unless Code.ensure_loaded?(Snodo.Extensions.Tasks) and Code.ensure_loaded?(Snodo.Transport.Plug) do
  raise "start the fixture from conformance/fixture so :snodo_tasks and :snodo_plug are available"
end

Code.require_file("support/tasks.ex", __DIR__)
Code.require_file("support/fixture.ex", __DIR__)

port =
  case Integer.parse(System.get_env("MCP_PORT", "3001")) do
    {value, ""} when value in 0..65_535 -> value
    _invalid -> raise "MCP_PORT must be an integer from 0 to 65535"
  end

runtime =
  case System.get_env("MCP_FIXTURE_PROFILE", "latest") do
    "latest" ->
      {:ok, _hub} =
        Snodo.Subscription.Hub.start_link(name: SnodoTest.Conformance.Stateless.hub())

      SnodoTest.Conformance.Fixture.runtime()

    "legacy" ->
      SnodoTest.Conformance.Fixture.legacy_runtime()

    other ->
      raise "MCP_FIXTURE_PROFILE must be latest or legacy, got: #{inspect(other)}"
  end

{stop, url} =
  case System.get_env("MCP_FIXTURE_TRANSPORT", "native") do
    "native" ->
      {:ok, server} =
        Snodo.Transport.StreamableHTTP.Server.start_link(
          runtime: runtime,
          ip: {127, 0, 0, 1},
          port: port,
          path: "/mcp",
          max_concurrency: 32,
          max_queue: 256
        )

      {fn -> GenServer.stop(server) end, Snodo.Transport.StreamableHTTP.Server.url(server)}

    "plug" ->
      {:ok, _executor} =
        Snodo.Server.Executor.start_link(
          name: SnodoTest.Conformance.Executor,
          max_concurrency: 32,
          max_queue: 256
        )

      {:ok, listener} =
        Bandit.start_link(
          plug:
            {Snodo.Transport.Plug, runtime: runtime, executor: SnodoTest.Conformance.Executor},
          ip: {127, 0, 0, 1},
          port: port,
          startup_log: false,
          # The runner leaves keep-alive connections open; do not wait the
          # default 15 seconds for them to drain on shutdown.
          thousand_island_options: [
            shutdown_timeout: 1_000,
            transport_options: [send_timeout: 5_000, send_timeout_close: true]
          ]
        )

      {:ok, {_ip, bound}} = ThousandIsland.listener_info(listener)
      {fn -> Supervisor.stop(listener) end, "http://127.0.0.1:#{bound}/mcp"}

    other ->
      raise "MCP_FIXTURE_TRANSPORT must be native or plug, got: #{inspect(other)}"
  end

if System.get_env("MCP_CONFORMANCE_MANAGED") == "1" do
  IO.puts(JSON.encode!(%{"conformanceReady" => true, "url" => url}))
  _input = IO.read(:stdio, :eof)
  :ok = stop.()
else
  IO.puts(:stderr, "MCP conformance fixture listening at #{url}")
  Process.sleep(:infinity)
end
