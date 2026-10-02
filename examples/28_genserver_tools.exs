defmodule Examples.GenServerTools.Counter do
  @moduledoc false
  use GenServer

  def start_link(owner), do: GenServer.start_link(__MODULE__, owner, name: __MODULE__)

  @impl true
  def init(owner), do: {:ok, %{count: 0, owner: owner}}

  @impl true
  def handle_call(:get, _from, state), do: {:reply, state.count, state}
  def handle_call(:reset, _from, state), do: {:reply, :ok, %{state | count: 0}}

  def handle_call({:add, by}, _from, state) do
    count = state.count + by
    {:reply, count, %{state | count: count}}
  end

  @impl true
  def handle_cast({:add, by}, state) do
    send(state.owner, {:cast_processed, by})
    {:noreply, %{state | count: state.count + by}}
  end
end

defmodule Examples.GenServerTools.Schemas do
  @moduledoc false

  def empty, do: %{"type" => "object", "additionalProperties" => false}

  def add do
    %{
      "type" => "object",
      "properties" => %{"by" => %{"type" => "integer"}},
      "required" => ["by"],
      "additionalProperties" => false
    }
  end

  def count do
    %{
      "type" => "object",
      "properties" => %{"value" => %{"type" => "integer"}},
      "required" => ["value"]
    }
  end
end

defmodule Examples.GenServerTools.ManualGet do
  @moduledoc false
  alias Examples.GenServerTools.Counter
  alias Examples.GenServerTools.Schemas

  use Snodo.Tool, name: "manual_get", description: "Read the counter"
  input_schema(Schemas.empty())
  output_schema(Schemas.count())

  @impl true
  def call(_arguments, _context) do
    {:ok, Snodo.Result.structured(%{"value" => GenServer.call(Counter, :get)})}
  end
end

defmodule Examples.GenServerTools.ManualAdd do
  @moduledoc false
  alias Examples.GenServerTools.Counter
  alias Examples.GenServerTools.Schemas

  use Snodo.Tool, name: "manual_add", description: "Add to the counter"
  input_schema(Schemas.add())
  output_schema(Schemas.count())

  @impl true
  def call(%{"by" => by}, _context) do
    count = GenServer.call(Counter, {:add, by})
    {:ok, Snodo.Result.structured(%{"value" => count})}
  end
end

defmodule Examples.GenServerTools.ManualCastAdd do
  @moduledoc false
  alias Examples.GenServerTools.Counter
  alias Examples.GenServerTools.Schemas

  use Snodo.Tool, name: "manual_cast_add", description: "Send an increment"
  input_schema(Schemas.add())

  @impl true
  def call(%{"by" => by}, _context) do
    :ok = GenServer.cast(Counter, {:add, by})
    {:ok, Snodo.Result.structured(%{"sent" => true})}
  end
end

# This prototype deliberately accepts only the three generated modules below.
# It advertises an operation enum, but one broad argument schema cannot show
# each operation's specific required fields in tools/list.
defmodule Examples.GenServerTools.Generic do
  @moduledoc false
  use Snodo.Tool, name: "counter_operation", description: "Call one declared counter operation"

  input_schema(%{
    "type" => "object",
    "properties" => %{
      "operation" => %{"type" => "string", "enum" => ["get", "add", "cast_add"]},
      "arguments" => %{"type" => "object"}
    },
    "required" => ["operation"],
    "additionalProperties" => false
  })

  @operations %{
    "get" => Examples.GenServerTools.Server.GenServerTools.CounterGet,
    "add" => Examples.GenServerTools.Server.GenServerTools.CounterAdd,
    "cast_add" => Examples.GenServerTools.Server.GenServerTools.CounterCastAdd
  }

  @impl true
  def call(%{"operation" => operation} = arguments, context) do
    case Map.fetch(@operations, operation) do
      {:ok, module} -> module.call(Map.get(arguments, "arguments", %{}), context)
      :error -> {:ok, Snodo.Result.error("Unknown counter operation")}
    end
  end
end

defmodule Examples.GenServerTools.Server do
  @moduledoc false
  alias Examples.GenServerTools.Counter
  alias Examples.GenServerTools.Generic
  alias Examples.GenServerTools.ManualAdd
  alias Examples.GenServerTools.ManualCastAdd
  alias Examples.GenServerTools.ManualGet
  alias Examples.GenServerTools.Schemas

  use Snodo.Server, name: "genserver-tools-example", version: "0.1.0"
  import Snodo.Tool.GenServer

  tool(ManualGet)
  tool(ManualAdd)
  tool(ManualCastAdd)

  genserver_call("counter_get",
    target: Counter,
    description: "Read the counter",
    input_schema: Schemas.empty(),
    output_schema: Schemas.count(),
    message: :get,
    encode_reply: fn count -> %{"value" => count} end
  )

  genserver_call("counter_add",
    target: Counter,
    description: "Add to the counter",
    input_schema: Schemas.add(),
    output_schema: Schemas.count(),
    message: fn %{"by" => by} -> {:add, by} end,
    encode_reply: fn count -> %{"value" => count} end
  )

  genserver_cast("counter_cast_add",
    target: Counter,
    description: "Send an increment",
    input_schema: Schemas.add(),
    message: fn %{"by" => by} -> {:add, by} end
  )

  tool(Generic)
end

defmodule Examples.GenServerTools.Runner do
  @moduledoc false

  alias Examples.GenServerTools.Counter
  alias Examples.GenServerTools.Server
  alias Snodo.Client

  def run(args) do
    check? = check_mode!(args)
    {:ok, counter} = Counter.start_link(self())

    try do
      {:ok, client} = Client.direct(Server.runtime())
      {:ok, tools} = Client.list_tools(client)
      compare_advertised_tools(tools)
      compare_calls(client)
      compare_casts(client)
      compare_generic(client, tools)

      if check? do
        IO.puts("28_genserver_tools: ok")
      else
        IO.puts("Manual and generated Counter tools advertise the same schemas and results.")
        IO.puts("The generic tool offers one operation enum with a broader arguments schema.")
      end
    after
      GenServer.stop(counter)
    end
  end

  defp compare_advertised_tools(tools) do
    for {manual_name, generated_name} <- [
          {"manual_get", "counter_get"},
          {"manual_add", "counter_add"},
          {"manual_cast_add", "counter_cast_add"}
        ] do
      manual = Enum.find(tools, &(&1["name"] == manual_name))
      generated = Enum.find(tools, &(&1["name"] == generated_name))
      ensure(manual["inputSchema"] == generated["inputSchema"], "matching input schema")
      ensure(manual["outputSchema"] == generated["outputSchema"], "matching output schema")
    end
  end

  defp compare_calls(client) do
    {:ok, manual_get} = Client.call_tool(client, "manual_get")
    {:ok, generated_get} = Client.call_tool(client, "counter_get")
    ensure(manual_get == generated_get, "matching read result")

    {:ok, manual_add} = Client.call_tool(client, "manual_add", %{"by" => 2})
    :ok = GenServer.call(Counter, :reset)
    {:ok, generated_add} = Client.call_tool(client, "counter_add", %{"by" => 2})
    ensure(manual_add == generated_add, "matching state-changing call result")
  end

  defp compare_casts(client) do
    {:ok, manual_cast} = Client.call_tool(client, "manual_cast_add", %{"by" => 3})
    assert_cast_processed(3)
    :ok = GenServer.call(Counter, :reset)
    {:ok, generated_cast} = Client.call_tool(client, "counter_cast_add", %{"by" => 3})
    assert_cast_processed(3)
    ensure(manual_cast == generated_cast, "matching cast send result")
  end

  defp compare_generic(client, tools) do
    generic = Enum.find(tools, &(&1["name"] == "counter_operation"))

    ensure(
      generic["inputSchema"]["properties"]["operation"]["enum"] ==
        ["get", "add", "cast_add"],
      "generic operation enum"
    )

    ensure(
      generic["inputSchema"]["properties"]["arguments"] !=
        Enum.find(tools, &(&1["name"] == "counter_add"))["inputSchema"],
      "generic schema is broader"
    )

    {:ok, named} = Client.call_tool(client, "counter_get")
    {:ok, via_generic} = Client.call_tool(client, "counter_operation", %{"operation" => "get"})
    ensure(named == via_generic, "generic read result")

    {:ok, %{"isError" => true}} =
      Client.call_tool(client, "counter_operation", %{
        "operation" => "add",
        "arguments" => %{"by" => "wrong"}
      })

    {:ok, %{"isError" => true}} =
      Client.call_tool(client, "counter_operation", %{"operation" => "unknown"})
  end

  defp assert_cast_processed(by) do
    receive do
      {:cast_processed, ^by} -> :ok
    after
      1_000 -> raise("cast was not processed in the example")
    end
  end

  defp ensure(true, _label), do: :ok
  defp ensure(false, label), do: raise("check failed: #{label}")

  defp check_mode!([]), do: false
  defp check_mode!(["--check"]), do: true

  defp check_mode!(_arguments),
    do: raise("usage: mix run examples/28_genserver_tools.exs [--check]")
end

Examples.GenServerTools.Runner.run(System.argv())
