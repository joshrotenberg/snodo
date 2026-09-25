defmodule Examples.SubscriptionHub.Status do
  @moduledoc false

  alias Snodo.Subscription.Hub

  @uri "demo://status"

  def start_link(hub) do
    Agent.start_link(fn -> %{"state" => "starting", "revision" => 0} end, name: __MODULE__)
    |> case do
      {:ok, state} -> {:ok, %{hub: hub, state: state}}
      error -> error
    end
  end

  def put(%{hub: hub}, value) do
    revision =
      Agent.get_and_update(__MODULE__, fn current ->
        revision = current["revision"] + 1
        {revision, %{"state" => value, "revision" => revision}}
      end)

    Hub.notify_resource_updated(hub, @uri, metadata: %{"com.example/revision" => revision})
  end

  def get, do: Agent.get(__MODULE__, & &1)
  def uri, do: @uri
end

defmodule Examples.SubscriptionHub.StatusResource do
  @moduledoc false

  alias Examples.SubscriptionHub.Status

  use Snodo.Resource,
    uri: "demo://status",
    name: "Application status",
    mime_type: "application/json"

  @impl true
  def read(%{"uri" => uri}, _context) do
    {:ok, Snodo.Result.resource_read(Snodo.Resource.json(uri, Status.get()))}
  end
end

defmodule Examples.SubscriptionHub.Server do
  @moduledoc false

  use Snodo.Server,
    name: "subscription-hub-example",
    version: "1.0.0",
    protocols: [Snodo.Protocol.V2026_07_28],
    capabilities: %{"resources" => %{"subscribe" => true}}

  resource(Examples.SubscriptionHub.StatusResource)
end

defmodule Examples.SubscriptionHub.Runner do
  @moduledoc false

  alias Examples.SubscriptionHub.Server
  alias Examples.SubscriptionHub.Status
  alias Snodo.Subscription
  alias Snodo.Subscription.Event
  alias Snodo.Subscription.Hub

  @subscription_id_key "io.modelcontextprotocol/subscriptionId"

  def run(mode) do
    {:ok, hub} = Hub.start_link(max_buffer: 2)
    {:ok, status} = Status.start_link(hub)

    try do
      runtime = Server.runtime(subscription_source: Hub.source(hub))
      exercise(runtime, hub, status)
      print_summary(mode)
    after
      stop_if_alive(status.state)
      stop_if_alive(hub)
    end
  end

  defp exercise(runtime, hub, status) do
    {:stream, subscription} = listen(runtime)
    {:ok, acknowledgement} = Subscription.acknowledgement(subscription)

    assert!(
      get_in(acknowledgement, ["params", "notifications"]) == %{
        "resourceSubscriptions" => [Status.uri()]
      },
      "hub did not acknowledge the supported resource filter"
    )

    {worker, monitor} = Subscription.start_worker(subscription, self())
    :ok = Subscription.continue(worker)

    {:ok, report} = Status.put(status, "ready")
    assert!(report.matched == 1, "resource update did not match its listener")
    assert!(report.dropped == 0, "resource update overflowed unexpectedly")

    event = receive_event!(worker)

    assert!(
      event == %Event{
        kind: :resource_updated,
        uri: Status.uri(),
        metadata: %{"com.example/revision" => 1}
      },
      "application event changed"
    )

    {:ok, notification} = Subscription.notification(subscription, event)
    assert!(notification["method"] == "notifications/resources/updated", "wrong method")
    assert!(notification["params"]["uri"] == Status.uri(), "wrong resource URI")

    assert!(
      get_in(notification, ["params", "_meta", @subscription_id_key]) == "hub-sub",
      "notification lost subscription correlation"
    )

    resource = dispatch(runtime, "read", "resources/read", %{"uri" => Status.uri()})
    assert!(decode(resource) == %{"state" => "ready", "revision" => 1}, "read was stale")

    :ok = Hub.complete(hub)
    :ok = Subscription.continue(worker)
    receive_closed!(worker)
    {:ok, completion} = Subscription.completion(subscription)
    assert!(get_in(completion, ["result", "resultType"]) == "complete", "bad completion")

    :ok = Subscription.close(subscription, :complete)
    :ok = Subscription.stop_worker(worker, monitor)
    assert!(Hub.stats(hub).subscriptions == 0, "completed listener leaked")
  end

  defp listen(runtime) do
    Snodo.Test.dispatch(runtime,
      id: "hub-sub",
      protocol: "2026-07-28",
      method: "subscriptions/listen",
      params: %{"notifications" => %{"resourceSubscriptions" => [Status.uri()]}}
    )
  end

  defp dispatch(runtime, id, method, params) do
    {:ok, response} =
      Snodo.Test.dispatch(runtime,
        id: id,
        protocol: "2026-07-28",
        method: method,
        params: params
      )

    response
  end

  defp decode(response) do
    response
    |> get_in(["result", "contents", Access.at(0), "text"])
    |> JSON.decode!()
  end

  defp receive_event!(worker) do
    receive do
      {:mcp_subscription, ^worker, {:ok, event}} -> event
    after
      1_000 -> raise "timed out waiting for the application event"
    end
  end

  defp receive_closed!(worker) do
    receive do
      {:mcp_subscription, ^worker, :closed} -> :ok
    after
      1_000 -> raise "timed out waiting for subscription completion"
    end
  end

  defp stop_if_alive(pid) do
    if Process.alive?(pid), do: GenServer.stop(pid)
  end

  defp assert!(true, _message), do: :ok
  defp assert!(false, message), do: raise(message)

  defp print_summary(:check), do: IO.puts("18_subscription_hub: ok")

  defp print_summary(:walkthrough) do
    IO.puts("Published a mutable application resource through the bounded subscription hub.")
    IO.puts("The correlated notification led to a fresh resource read and a clean completion.")
  end
end

case System.argv() do
  ["--check"] -> Examples.SubscriptionHub.Runner.run(:check)
  [] -> Examples.SubscriptionHub.Runner.run(:walkthrough)
  _arguments -> raise "usage: mix run examples/18_subscription_hub.exs [--check]"
end
