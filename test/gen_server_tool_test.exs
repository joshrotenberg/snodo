defmodule Snodo.GenServerToolTest do
  use ExUnit.Case, async: false

  alias Snodo.Client

  defmodule Counter do
    use GenServer

    def start_link(owner), do: GenServer.start_link(__MODULE__, owner, name: __MODULE__)

    @impl true
    def init(owner), do: {:ok, %{count: 0, owner: owner}}

    @impl true
    def handle_call(:get, _from, state), do: {:reply, state.count, state}

    def handle_call({:add, by}, _from, state) do
      count = state.count + by
      {:reply, count, %{state | count: count}}
    end

    def handle_call(:unencodable, _from, state), do: {:reply, self(), state}
    def handle_call(:invalid_utf8, _from, state), do: {:reply, <<255>>, state}
    def handle_call(:wait, _from, state), do: {:noreply, state}

    @impl true
    def handle_cast({:add, by}, state) do
      send(state.owner, {:cast_applied, by})
      {:noreply, %{state | count: state.count + by}}
    end
  end

  defmodule ManualGet do
    use Snodo.Tool, name: "manual_get", description: "Read the counter"
    input_schema(%{"type" => "object", "additionalProperties" => false})

    output_schema(%{
      "type" => "object",
      "properties" => %{"value" => %{"type" => "integer"}},
      "required" => ["value"]
    })

    @impl true
    def call(_arguments, _context) do
      {:ok, Snodo.Result.structured(%{"value" => GenServer.call(Counter, :get)})}
    end
  end

  defmodule Server do
    use Snodo.Server, name: "genserver-tools-test", version: "1.0.0"
    import Snodo.Tool.GenServer

    tool(ManualGet)

    genserver_call("counter_get",
      target: Counter,
      description: "Read the counter",
      input_schema: %{"type" => "object", "additionalProperties" => false},
      output_schema: %{
        "type" => "object",
        "properties" => %{"value" => %{"type" => "integer"}},
        "required" => ["value"]
      },
      message: :get,
      encode_reply: fn count -> %{"value" => count} end
    )

    genserver_call("counter_add",
      target: Counter,
      input_schema: %{
        "type" => "object",
        "properties" => %{"by" => %{"type" => "integer"}},
        "required" => ["by"],
        "additionalProperties" => false
      },
      message: fn %{"by" => by} -> {:add, by} end,
      encode_reply: fn count -> %{"value" => count} end
    )

    genserver_call("counter_wait",
      target: Counter,
      input_schema: %{"type" => "object", "additionalProperties" => false},
      message: :wait,
      encode_reply: fn count -> %{"value" => count} end,
      timeout: 30
    )

    genserver_call("counter_unencodable",
      target: Counter,
      input_schema: %{"type" => "object", "additionalProperties" => false},
      message: :unencodable,
      encode_reply: fn value -> %{"value" => value} end
    )

    genserver_call("counter_invalid_utf8",
      target: Counter,
      input_schema: %{"type" => "object", "additionalProperties" => false},
      message: :invalid_utf8,
      encode_reply: fn value -> %{"value" => value} end
    )

    genserver_call("counter_broad",
      target: Counter,
      input_schema: %{"type" => "object"},
      message: :get,
      encode_reply: fn count -> %{"value" => count} end
    )

    genserver_cast("counter_cast_add",
      target: Counter,
      input_schema: %{
        "type" => "object",
        "properties" => %{"by" => %{"type" => "integer"}},
        "required" => ["by"],
        "additionalProperties" => false
      },
      message: fn %{"by" => by} -> {:add, by} end
    )
  end

  setup do
    start_supervised!({Counter, self()})
    {:ok, client} = Client.direct(Server.runtime())
    %{client: client}
  end

  test "generated modules advertise and return the same schemas and call result", %{
    client: client
  } do
    assert {:ok, tools} = Client.list_tools(client)
    manual = Enum.find(tools, &(&1["name"] == "manual_get"))
    generated = Enum.find(tools, &(&1["name"] == "counter_get"))

    assert manual["inputSchema"] == generated["inputSchema"]
    assert manual["outputSchema"] == generated["outputSchema"]
    assert manual["description"] == generated["description"]
    assert Code.ensure_loaded?(Server.GenServerTools.CounterGet)

    assert {:ok, manual_result} = Client.call_tool(client, "manual_get")
    assert {:ok, generated_result} = Client.call_tool(client, "counter_get")
    assert manual_result == generated_result

    assert {:ok, %{"structuredContent" => %{"value" => 4}}} =
             Client.call_tool(client, "counter_add", %{"by" => 4})
  end

  test "invalid arguments are refused before building a message", %{client: client} do
    assert {:ok, %{"isError" => true}} =
             Client.call_tool(client, "counter_add", %{"by" => "four"})

    assert {:ok, %{"structuredContent" => %{"value" => 0}}} =
             Client.call_tool(client, "counter_get")

    assert {:ok, %Snodo.Result{kind: :error}} =
             Server.GenServerTools.CounterBroad.call(%{atom_key: 1}, nil)

    assert {:ok, %Snodo.Result{kind: :error}} =
             Server.GenServerTools.CounterBroad.call(%{"value" => <<255>>}, nil)
  end

  test "missing targets and timeouts become defined tool failures", %{client: client} do
    assert {:ok, %{"isError" => true, "content" => [%{"text" => "GenServer call timed out"}]}} =
             Client.call_tool(client, "counter_wait")

    :ok = stop_supervised(Counter)

    assert {:ok, %{"isError" => true, "content" => [%{"text" => "GenServer target unavailable"}]}} =
             Client.call_tool(client, "counter_get")

    assert {:ok, %{"isError" => true, "content" => [%{"text" => "GenServer target unavailable"}]}} =
             Client.call_tool(client, "counter_cast_add", %{"by" => 1})
  end

  test "an unencodable reply becomes a defined tool failure", %{client: client} do
    assert {:ok,
            %{
              "isError" => true,
              "content" => [%{"text" => "GenServer reply is not a JSON object"}]
            }} = Client.call_tool(client, "counter_unencodable")

    assert {:ok,
            %{
              "isError" => true,
              "content" => [%{"text" => "GenServer reply is not a JSON object"}]
            }} = Client.call_tool(client, "counter_invalid_utf8")
  end

  test "unsupported JSON Schema assertions fail when the tool compiles" do
    assert_raise CompileError, ~r/unsupported keyword "oneOf"/, fn ->
      Code.compile_string(~S'''
      defmodule Snodo.GenServerToolTest.UnsupportedSchema do
        use Snodo.Server, name: "unsupported-schema", version: "1"
        import Snodo.Tool.GenServer

        genserver_call "bad",
          target: Snodo.GenServerToolTest.Counter,
          input_schema: %{
            "type" => "object",
            "properties" => %{
              "value" => %{"type" => "integer", "oneOf" => [%{"minimum" => 1}]}
            }
          },
          message: :get,
          encode_reply: fn count -> %{"value" => count} end
      end
      ''')
    end
  end

  test "casts acknowledge sending without claiming processing", %{client: client} do
    assert {:ok, %{"structuredContent" => %{"sent" => true}}} =
             Client.call_tool(client, "counter_cast_add", %{"by" => 3})

    assert_receive {:cast_applied, 3}, 1_000
  end
end
