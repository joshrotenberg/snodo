defmodule Examples.Instrumentation.Sink do
  @moduledoc false
  @behaviour Snodo.Instrumentation

  @impl true
  def handle_event(event_name, measurements, metadata, owner) do
    send(owner, {:observed, event_name, measurements, metadata})
    :ok
  end
end

defmodule Examples.Instrumentation.Echo do
  @moduledoc false

  use Snodo.Tool, name: "observed_echo"

  @impl true
  def call(%{"text" => text}, _context), do: {:ok, Snodo.Result.text(text)}
end

defmodule Examples.Instrumentation.Server do
  @moduledoc false

  use Snodo.Server,
    name: "instrumentation-example",
    version: "1.0.0",
    protocols: [Snodo.Protocol.V2026_07_28],
    capabilities: %{"tools" => %{"listChanged" => true}}

  tool(Examples.Instrumentation.Echo)
end

defmodule Examples.Instrumentation.Runner do
  @moduledoc false

  alias Examples.Instrumentation.Server
  alias Examples.Instrumentation.Sink
  alias Snodo.Subscription
  alias Snodo.Subscription.Hub

  def run(mode) do
    sink = {Sink, self()}
    {:ok, hub} = Hub.start_link(max_buffer: 1, instrumentation: sink)

    try do
      runtime =
        Server.runtime(
          instrumentation: sink,
          subscription_source: Hub.source(hub)
        )

      exercise(runtime, hub)
      print_summary(mode)
    after
      if Process.alive?(hub), do: GenServer.stop(hub)
    end
  end

  defp exercise(runtime, hub) do
    {:ok, %{"result" => %{"tools" => [_tool]}}} =
      dispatch(runtime, "list", "tools/list")

    assert_event!([:snodo, :server, :dispatch, :start], fn measurements, metadata ->
      is_integer(measurements.system_time) and metadata.method == "tools/list"
    end)

    assert_event!([:snodo, :server, :dispatch, :stop], fn measurements, metadata ->
      measurements.duration >= 0 and metadata.outcome == :ok
    end)

    {:stream, subscription} =
      dispatch(runtime, "observed-sub", "subscriptions/listen", %{
        "notifications" => %{"toolsListChanged" => true}
      })

    assert_event!([:snodo, :server, :dispatch, :start], fn _measurements, metadata ->
      metadata.request_id == "observed-sub"
    end)

    assert_event!([:snodo, :subscription, :open], fn measurements, metadata ->
      measurements.subscriptions == 1 and metadata.filter_keys == ["toolsListChanged"]
    end)

    assert_event!([:snodo, :server, :dispatch, :stop], fn _measurements, metadata ->
      metadata.outcome == :stream
    end)

    {:ok, %{dropped: 0}} = Hub.notify_tools_list_changed(hub)
    assert_event!([:snodo, :subscription, :publish], &no_drop?/2)

    {:ok, %{dropped: 1}} = Hub.notify_tools_list_changed(hub)
    assert_event!([:snodo, :subscription, :publish], &one_drop?/2)
    assert_event!([:snodo, :subscription, :overflow], &oldest_overflow?/2)

    :ok = Hub.complete(hub)

    assert_event!([:snodo, :subscription, :complete], fn measurements, _metadata ->
      measurements.subscriptions == 1 and measurements.queued == 1
    end)

    :ok = Subscription.close(subscription, :complete)

    assert_event!([:snodo, :subscription, :close], fn measurements, metadata ->
      measurements.subscriptions == 0 and metadata.reason == :complete
    end)
  end

  defp dispatch(runtime, id, method, params \\ %{}) do
    Snodo.Test.dispatch(runtime,
      id: id,
      protocol: "2026-07-28",
      method: method,
      params: params
    )
  end

  defp no_drop?(measurements, metadata) do
    measurements.matched == 1 and measurements.dropped == 0 and
      metadata.event_kind == :tools_list_changed
  end

  defp one_drop?(measurements, _metadata) do
    measurements.dropped == 1 and measurements.queued == 1
  end

  defp oldest_overflow?(measurements, metadata) do
    measurements.dropped == 1 and metadata.policy == :drop_oldest
  end

  defp assert_event!(event_name, predicate) do
    receive do
      {:observed, ^event_name, measurements, metadata} ->
        unless predicate.(measurements, metadata), do: raise("unexpected instrumentation event")
    after
      1_000 -> raise "timed out waiting for #{inspect(event_name)}"
    end
  end

  defp print_summary(:check), do: IO.puts("19_instrumentation: ok")

  defp print_summary(:walkthrough) do
    IO.puts("Observed bounded dispatch and subscription lifecycle measurements.")
    IO.puts("Sink configuration added no runtime dependency or protocol metadata.")
  end
end

case System.argv() do
  ["--check"] -> Examples.Instrumentation.Runner.run(:check)
  [] -> Examples.Instrumentation.Runner.run(:walkthrough)
  _arguments -> raise "usage: mix run examples/19_instrumentation.exs [--check]"
end
