defmodule SnodoTest.Telemetry.Echo do
  @moduledoc false
  use Snodo.Tool, name: "echo"

  @impl true
  def call(%{"text" => text}, _context), do: {:ok, Snodo.Result.text(text)}
end

defmodule SnodoTest.Telemetry.Server do
  @moduledoc false

  use Snodo.Server,
    name: "telemetry-test",
    version: "0.1.0",
    protocols: [Snodo.Protocol.V2026_07_28],
    capabilities: %{"tools" => %{"listChanged" => true}}

  tool(SnodoTest.Telemetry.Echo)
end

defmodule SnodoTest.Telemetry.Tasks do
  @moduledoc false

  alias Snodo.Extensions.Tasks
  alias Snodo.Extensions.Tasks.Store.Memory
  alias Snodo.Router
  alias Snodo.Server.Runtime

  @doc "A runtime whose `echo` tool runs in the Tasks runner when the request declares Tasks."
  def runtime(store, runner, instrumentation) do
    Runtime.new(
      router: Router.register_tool(Router.new(), SnodoTest.Telemetry.Echo),
      protocols: [Snodo.Protocol.V2026_07_28],
      extensions: [
        {Tasks,
         store: {Memory, store},
         runner: runner,
         task_support: %{"echo" => :optional},
         poll_interval_ms: 5}
      ],
      server_info: %{"name" => "telemetry-tasks-test", "version" => "0.1.0"},
      capabilities: %{"tools" => %{}, "extensions" => %{Tasks.id() => %{}}},
      instrumentation: instrumentation
    )
  end

  def client_capabilities, do: %{"extensions" => %{Tasks.id() => %{}}}
end
