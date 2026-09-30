# A stdio MCP server for Snodo.Client transport tests. Run it as
#   elixir -pa <snodo ebin> test/fixtures/client_stdio_server.exs

defmodule SnodoTest.ClientStdioFixture.Echo do
  use Snodo.Tool, name: "echo", description: "Echo text after an optional delay"

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
    Process.sleep(Map.get(arguments, "delayMs", 0))
    {:ok, Snodo.Result.text(text)}
  end
end

defmodule SnodoTest.ClientStdioFixture.Park do
  use Snodo.Tool, name: "park", description: "Registers the worker and waits to be cancelled"

  @impl true
  def call(_arguments, _context) do
    Agent.update(:client_stdio_parked, &[self() | &1])
    Process.sleep(:infinity)
  end
end

defmodule SnodoTest.ClientStdioFixture.Parked do
  use Snodo.Tool, name: "parked", description: "Counts parked workers that are still alive"

  @impl true
  def call(_arguments, _context) do
    alive = :client_stdio_parked |> Agent.get(& &1) |> Enum.count(&Process.alive?/1)
    {:ok, Snodo.Result.structured(%{"alive" => alive})}
  end
end

defmodule SnodoTest.ClientStdioFixture.Halt do
  use Snodo.Tool, name: "halt", description: "Stops the server VM with exit status 3"

  @impl true
  def call(_arguments, _context), do: System.halt(3)
end

defmodule SnodoTest.ClientStdioFixture.Large do
  use Snodo.Tool, name: "large", description: "Returns a text result of the requested size"

  @impl true
  def call(%{"bytes" => bytes}, _context) do
    {:ok, Snodo.Result.text(String.duplicate("x", bytes))}
  end
end

defmodule SnodoTest.ClientStdioFixture.Emit do
  use Snodo.Tool, name: "emit", description: "Publishes a subscription event to every stream"

  alias Snodo.Subscription.Event

  @impl true
  def call(%{"kind" => kind} = arguments, _context) do
    metadata = %{"seq" => Map.get(arguments, "seq", 0)}

    event =
      case kind do
        "tools" -> Event.tools_list_changed(metadata: metadata)
        "prompts" -> Event.prompts_list_changed(metadata: metadata)
        "resources" -> Event.resources_list_changed(metadata: metadata)
        "resource" -> Event.resource_updated(Map.fetch!(arguments, "uri"), metadata: metadata)
      end

    :ok = SnodoTest.TestSubscriptionHub.emit_all(:client_stdio_hub, event)
    {:ok, Snodo.Result.text("emitted")}
  end
end

defmodule SnodoTest.ClientStdioFixture.Complete do
  use Snodo.Tool, name: "complete", description: "Ends every stream with the terminal result"

  @impl true
  def call(_arguments, _context) do
    :ok = SnodoTest.TestSubscriptionHub.complete_all(:client_stdio_hub)
    {:ok, Snodo.Result.text("completed")}
  end
end

defmodule SnodoTest.ClientStdioFixture.Fail do
  use Snodo.Tool, name: "fail", description: "Fails every stream's source"

  @impl true
  def call(_arguments, _context) do
    :ok = SnodoTest.TestSubscriptionHub.fail_all(:client_stdio_hub, :fixture_failure)
    {:ok, Snodo.Result.text("failed")}
  end
end

defmodule SnodoTest.ClientStdioFixture.Subscriptions do
  use Snodo.Tool, name: "subscriptions", description: "Counts the open streams"

  @impl true
  def call(_arguments, _context) do
    open = SnodoTest.TestSubscriptionHub.count(:client_stdio_hub)
    {:ok, Snodo.Result.structured(%{"open" => open})}
  end
end

{:ok, _agent} = Agent.start_link(fn -> [] end, name: :client_stdio_parked)
{:ok, hub} = SnodoTest.TestSubscriptionHub.start_link()
true = Process.register(hub, :client_stdio_hub)

router =
  Enum.reduce(
    [
      SnodoTest.ClientStdioFixture.Echo,
      SnodoTest.ClientStdioFixture.Park,
      SnodoTest.ClientStdioFixture.Parked,
      SnodoTest.ClientStdioFixture.Halt,
      SnodoTest.ClientStdioFixture.Large,
      SnodoTest.ClientStdioFixture.Emit,
      SnodoTest.ClientStdioFixture.Complete,
      SnodoTest.ClientStdioFixture.Fail,
      SnodoTest.ClientStdioFixture.Subscriptions,
      SnodoTest.TestTools.Ticks,
      SnodoTest.MRTR.Tool,
      SnodoTest.MRTR.UrlTool,
      SnodoTest.MRTR.SamplingTool,
      SnodoTest.MRTR.RootsTool,
      SnodoTest.MRTR.MixedTool
    ],
    Snodo.Router.new(),
    &Snodo.Router.register_tool(&2, &1)
  )

runtime =
  Snodo.Server.Runtime.new(
    router: router,
    protocols: [Snodo.Protocol.V2026_07_28],
    server_info: %{"name" => "client-stdio-fixture", "version" => "0.1.0"},
    capabilities: %{
      "tools" => %{"listChanged" => true},
      "resources" => %{"subscribe" => true}
    },
    subscription_source: {SnodoTest.TestSubscriptionSource, hub}
  )

case Snodo.Transport.Stdio.serve(runtime) do
  :ok -> :ok
  {:error, reason} -> raise "client stdio fixture failed: #{inspect(reason)}"
end
