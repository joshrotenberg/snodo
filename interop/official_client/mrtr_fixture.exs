# Load compiled public APIs without Mix or private test helpers. The parent
# owns process lifetime, and all requests are read-only with no network calls.
project = Path.expand("../..", __DIR__)
ebin = System.get_env("MCP_EX_EBIN") || Path.join(project, "_build/dev/lib/mcp_ex/ebin")
true = Code.prepend_path(ebin)
{:ok, _applications} = Application.ensure_all_started(:mcp_ex)
Code.require_file(Path.join(project, "examples/support/mrtr_elicitation.exs"))
Examples.MRTR.Workflow.configure()
runtime = Examples.MRTR.Server.runtime()

case System.argv() do
  ["--stdio"] ->
    :ok = MCP.Transport.Stdio.serve(runtime)

  ["--http"] ->
    {:ok, listener} = MCP.Transport.StreamableHTTP.Server.start_link(runtime: runtime, port: 0)
    IO.puts(JSON.encode!(%{"url" => MCP.Transport.StreamableHTTP.Server.url(listener)}))
    _input = IO.read(:stdio, :eof)
    :ok = GenServer.stop(listener)

  _arguments ->
    raise "usage: elixir mrtr_fixture.exs --stdio|--http"
end
