defmodule ReleaseSmoke.Greet do
  @moduledoc false
  use Snodo.Tool, name: "greet", description: "Return a greeting"

  @impl true
  def call(_arguments, _context), do: {:ok, Snodo.Result.text("Hello from the archive")}
end

defmodule ReleaseSmoke.Server do
  @moduledoc false
  use Snodo.Server, name: "release-smoke", version: "0.0.0"

  tool(ReleaseSmoke.Greet)
end

version = System.fetch_env!("SNODO_SMOKE_VERSION")
lock = Mix.Dep.Lock.read()

for {app, ^version, opts} <- Mix.Project.config()[:deps], opts[:repo] == "local" do
  {:hex, ^app, ^version, _, _, requirements, "local", _} = Map.fetch!(lock, app)

  parent =
    case app do
      :snodo -> nil
      store when store in [:snodo_tasks_postgres, :snodo_tasks_sqlite] -> :snodo_tasks
      _ -> :snodo
    end

  if parent do
    {^parent, requirement, metadata} = List.keyfind(requirements, parent, 0)

    unless metadata[:hex] == parent and metadata[:repo] == "hexpm" and
             metadata[:optional] == false and Version.match?(version, requirement) do
      raise "Invalid archived dependency from #{app} to #{parent}: #{inspect(requirement)}"
    end
  end
end

for module <- [
      Snodo.Transport.Plug,
      Plug.Conn,
      Snodo.Schema.Validator.JSV,
      JSV,
      Snodo.Extensions.Tasks.Store.Memory
    ] do
  Code.ensure_loaded!(module)
end

{:ok, client} = Snodo.Client.direct(ReleaseSmoke.Server.runtime())

try do
  {:ok, [%{"name" => "greet"}]} = Snodo.Client.list_tools(client)

  {:ok, %{"content" => [%{"type" => "text", "text" => "Hello from the archive"}]}} =
    Snodo.Client.call_tool(client, "greet", %{})
after
  Snodo.Client.close(client)
end

IO.puts("Release archive smoke test passed for #{version}")
