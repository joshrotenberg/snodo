# Load compiled public APIs without Mix or private test helpers. The parent
# owns process lifetime, and all requests are read-only with no network calls.
project = Path.expand("../..", __DIR__)
ebin = System.get_env("SNODO_EBIN") || Path.join(project, "_build/dev/lib/snodo/ebin")
true = Code.prepend_path(ebin)
{:ok, _applications} = Application.ensure_all_started(:snodo)
Code.require_file(Path.join(project, "examples/support/mrtr_elicitation.exs"))
Examples.MRTR.Workflow.configure()
runtime = Examples.MRTR.Server.runtime()

case System.argv() do
  ["--stdio"] ->
    :ok = Snodo.Transport.Stdio.serve(runtime)

  ["--http"] ->
    {:ok, listener} = Snodo.Transport.StreamableHTTP.Server.start_link(runtime: runtime, port: 0)
    IO.puts(JSON.encode!(%{"url" => Snodo.Transport.StreamableHTTP.Server.url(listener)}))
    _input = IO.read(:stdio, :eof)
    :ok = GenServer.stop(listener)

  _arguments ->
    raise "usage: elixir mrtr_fixture.exs --stdio|--http"
end
