defmodule ContextAndState.Store do
  @moduledoc false

  def start_link do
    Agent.start_link(fn -> %{count: 0, observations: []} end, name: __MODULE__)
  end

  def increment(amount, observation) do
    Agent.get_and_update(__MODULE__, fn state ->
      count = state.count + amount
      {count, %{state | count: count, observations: state.observations ++ [observation]}}
    end)
  end

  def snapshot, do: Agent.get(__MODULE__, & &1)
end

defmodule ContextAndState.Increment do
  @moduledoc false

  use Snodo.Tool,
    name: "increment",
    description: "Increment an application-owned counter"

  input_schema(%{
    "type" => "object",
    "properties" => %{"amount" => %{"type" => "integer"}},
    "required" => ["amount"],
    "additionalProperties" => false
  })

  @impl true
  def call(%{"amount" => amount}, context) do
    observation = %{
      client_capabilities: context.client_capabilities,
      client_info: context.client_info,
      protocol_version: context.protocol_version,
      request_id: context.request_id,
      request_tag: context.metadata["example.dev/requestTag"],
      session: context.session,
      transport: context.transport.transport
    }

    count = ContextAndState.Store.increment(amount, observation)

    {:ok,
     Snodo.Result.structured(%{
       "count" => count,
       "requestTag" => observation.request_tag,
       "session" => observation.session
     })}
  end
end

defmodule ContextAndState.Server do
  @moduledoc false

  use Snodo.Server,
    name: "context-and-state-example",
    version: "0.1.0",
    protocols: [Snodo.Protocol.V2026_07_28]

  tool(ContextAndState.Increment)
end

defmodule ContextAndState.Example do
  @moduledoc false

  alias Snodo.Protocol.V2026_07_28, as: Protocol
  alias Snodo.Transport.Context, as: TransportContext

  def run(check?) do
    {:ok, store} = ContextAndState.Store.start_link()

    try do
      runtime = ContextAndState.Server.runtime()
      transport = %TransportContext{transport: :direct, connection_ref: :example_connection}

      first = dispatch(runtime, transport, "first", 2, "first-call")
      second = dispatch(runtime, transport, "second", 3, "second-call")
      snapshot = ContextAndState.Store.snapshot()

      assert!(structured_content(first) == expected_result(2, "first-call"), "first result")
      assert!(structured_content(second) == expected_result(5, "second-call"), "second result")
      assert!(snapshot.count == 5, "application-owned state persisted across requests")

      assert!(
        snapshot.observations == [
          %{
            client_capabilities: client_capabilities(),
            client_info: client_info(),
            protocol_version: "2026-07-28",
            request_id: "first",
            request_tag: "first-call",
            session: nil,
            transport: :direct
          },
          %{
            client_capabilities: client_capabilities(),
            client_info: client_info(),
            protocol_version: "2026-07-28",
            request_id: "second",
            request_tag: "second-call",
            session: nil,
            transport: :direct
          }
        ],
        "immutable request contexts preserved each request's metadata"
      )

      print_result(check?, snapshot)
    after
      if Process.alive?(store), do: Agent.stop(store)
    end
  end

  defp dispatch(runtime, transport, id, amount, request_tag) do
    metadata =
      Protocol.request_metadata(client_capabilities())
      |> Map.put(Protocol.client_info_key(), client_info())
      |> Map.put("example.dev/requestTag", request_tag)

    request = %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => "tools/call",
      "params" => %{
        "name" => "increment",
        "arguments" => %{"amount" => amount},
        "_meta" => metadata
      }
    }

    {:ok, %{"result" => result}} = Snodo.Server.dispatch(runtime, request, transport)
    result
  end

  defp structured_content(result), do: result["structuredContent"]

  defp expected_result(count, request_tag) do
    %{"count" => count, "requestTag" => request_tag, "session" => nil}
  end

  defp client_info do
    %{"name" => "context-example-client", "version" => "0.1.0"}
  end

  defp client_capabilities do
    %{"roots" => %{"listChanged" => false}}
  end

  defp assert!(true, _label), do: :ok
  defp assert!(false, label), do: raise("check failed: #{label}")

  defp print_result(true, _snapshot) do
    IO.puts("03_context_and_state: ok")
  end

  defp print_result(false, snapshot) do
    IO.puts("Application state finished at count #{snapshot.count}.")
    IO.puts("The two immutable contexts retained tags first-call and second-call.")

    IO.puts(
      "Both requests were sessionless: #{inspect(Enum.map(snapshot.observations, & &1.session))}"
    )
  end
end

case System.argv() do
  [] -> ContextAndState.Example.run(false)
  ["--check"] -> ContextAndState.Example.run(true)
  _arguments -> raise "usage: mix run examples/03_context_and_state.exs [--check]"
end
