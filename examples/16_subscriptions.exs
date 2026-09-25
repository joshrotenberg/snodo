defmodule Examples.Subscriptions.Hub do
  @moduledoc false
  use GenServer

  def start_link(owner), do: GenServer.start_link(__MODULE__, owner, name: __MODULE__)
  def publish(request_id, event), do: GenServer.call(__MODULE__, {:publish, request_id, event})
  def complete(request_id), do: GenServer.call(__MODULE__, {:complete, request_id})

  @impl true
  def init(owner), do: {:ok, %{owner: owner, subscriptions: %{}}}

  @impl true
  def handle_call({:open, request_id, filter}, _from, state) do
    token = make_ref()
    send(state.owner, {:opened, request_id, filter})
    subscription = %{request_id: request_id, queue: :queue.new(), waiter: nil, closed?: false}
    {:reply, {:ok, filter, token}, put_in(state, [:subscriptions, token], subscription)}
  end

  def handle_call({:next, token}, from, state) do
    subscription = Map.fetch!(state.subscriptions, token)
    send(state.owner, {:pull, subscription.request_id})

    case :queue.out(subscription.queue) do
      {{:value, value}, queue} ->
        {:reply, value, put_in(state, [:subscriptions, token, :queue], queue)}

      {:empty, _queue} when subscription.closed? ->
        {:reply, :closed, state}

      {:empty, _queue} ->
        {:noreply, put_in(state, [:subscriptions, token, :waiter], from)}
    end
  end

  def handle_call({:publish, request_id, event}, _from, state) do
    {:reply, :ok, deliver(state, request_id, {:ok, event})}
  end

  def handle_call({:complete, request_id}, _from, state) do
    {:reply, :ok, deliver(state, request_id, :closed)}
  end

  def handle_call({:close, token, reason}, _from, state) do
    {subscription, subscriptions} = Map.pop!(state.subscriptions, token)
    if subscription.waiter, do: GenServer.reply(subscription.waiter, :closed)
    send(state.owner, {:closed, subscription.request_id, reason})
    {:reply, :ok, %{state | subscriptions: subscriptions}}
  end

  defp deliver(state, request_id, value) do
    {token, subscription} =
      Enum.find(state.subscriptions, fn {_token, entry} -> entry.request_id == request_id end)

    subscription =
      case subscription.waiter do
        nil when value == :closed ->
          %{subscription | closed?: true}

        nil ->
          %{subscription | queue: :queue.in(value, subscription.queue)}

        waiter ->
          GenServer.reply(waiter, value)
          %{subscription | waiter: nil, closed?: value == :closed}
      end

    put_in(state, [:subscriptions, token], subscription)
  end
end

defmodule Examples.Subscriptions.Source do
  @moduledoc false
  @behaviour Snodo.Subscription.Source

  alias Examples.Subscriptions.Hub

  @impl true
  def open(filter, context, _options) do
    GenServer.call(Hub, {:open, context.request_id, filter})
  end

  @impl true
  def next(token, _options), do: GenServer.call(Hub, {:next, token}, :infinity)

  @impl true
  def close(token, reason, _options), do: GenServer.call(Hub, {:close, token, reason})
end

defmodule Examples.Subscriptions.Server do
  @moduledoc false

  use Snodo.Server,
    name: "subscriptions-example",
    version: "1.0.0",
    protocols: [Snodo.Protocol.V2026_07_28],
    capabilities: %{
      "tools" => %{"listChanged" => true},
      "resources" => %{"subscribe" => true}
    },
    subscription_source: Examples.Subscriptions.Source
end

defmodule Examples.Subscriptions.Runner do
  @moduledoc false

  alias Examples.Subscriptions.Hub
  alias Snodo.Subscription
  alias Snodo.Subscription.Event

  @subscription_id_key "io.modelcontextprotocol/subscriptionId"

  def run(mode) do
    {:ok, hub} = Hub.start_link(self())

    try do
      exercise(Examples.Subscriptions.Server.runtime())
      print_summary(mode)
    after
      if Process.alive?(hub), do: GenServer.stop(hub)
    end
  end

  defp exercise(runtime) do
    assert!(
      get_in(runtime.capabilities, ["resources", "subscribe"]) == true,
      "resource subscriptions were not advertised"
    )

    {:stream, subscription} = listen(runtime)
    {:opened, "example-sub", accepted} = receive_message!()

    assert!(
      accepted == %{
        "toolsListChanged" => true,
        "resourceSubscriptions" => ["demo://status"]
      },
      "the source did not acknowledge the supported subset"
    )

    {:ok, acknowledgement} = Subscription.acknowledgement(subscription)
    assert!(acknowledgement["method"] == "notifications/subscriptions/acknowledged", "bad ack")

    {worker, monitor} = Subscription.start_worker(subscription, self())
    Subscription.continue(worker)
    {:pull, "example-sub"} = receive_message!()

    Hub.publish("example-sub", Event.tools_list_changed())
    {:mcp_subscription, ^worker, {:ok, tools_event}} = receive_message!()
    refute_receive!({:pull, "example-sub"})

    {:ok, tools_notification} = Subscription.notification(subscription, tools_event)
    assert_subscription_id!(tools_notification)

    Subscription.continue(worker)
    {:pull, "example-sub"} = receive_message!()

    Hub.publish("example-sub", Event.resource_updated("demo://status"))
    {:mcp_subscription, ^worker, {:ok, resource_event}} = receive_message!()
    {:ok, resource_notification} = Subscription.notification(subscription, resource_event)
    assert!(resource_notification["params"]["uri"] == "demo://status", "resource URI changed")

    Subscription.continue(worker)
    {:pull, "example-sub"} = receive_message!()
    Hub.complete("example-sub")
    {:mcp_subscription, ^worker, :closed} = receive_message!()

    {:ok, completion} = Subscription.completion(subscription)
    assert!(completion["id"] == "example-sub", "completion lost request correlation")
    assert!(get_in(completion, ["result", "resultType"]) == "complete", "bad completion")

    Subscription.close(subscription, :complete)
    {:closed, "example-sub", :complete} = receive_message!()
    Subscription.stop_worker(worker, monitor)
  end

  defp listen(runtime) do
    Snodo.Test.dispatch(runtime,
      id: "example-sub",
      protocol: "2026-07-28",
      method: "subscriptions/listen",
      params: %{
        "notifications" => %{
          "toolsListChanged" => true,
          "promptsListChanged" => true,
          "resourceSubscriptions" => ["demo://status"]
        }
      }
    )
  end

  defp assert_subscription_id!(message) do
    assert!(
      get_in(message, ["params", "_meta", @subscription_id_key]) == "example-sub",
      "notification lost subscription metadata"
    )
  end

  defp receive_message! do
    receive do
      message -> message
    after
      1_000 -> raise "timed out waiting for a subscription message"
    end
  end

  defp refute_receive!(pattern) do
    receive do
      ^pattern -> raise "source was pulled before the prior event was acknowledged"
    after
      0 -> :ok
    end
  end

  defp assert!(true, _message), do: :ok
  defp assert!(false, message), do: raise(message)

  defp print_summary(:check), do: IO.puts("16_subscriptions: ok")

  defp print_summary(:walkthrough) do
    IO.puts("Acknowledged the application-supported subscription filter first.")
    IO.puts("Delivered bounded list/resource events and a correlated completion.")
  end
end

case System.argv() do
  ["--check"] -> Examples.Subscriptions.Runner.run(:check)
  [] -> Examples.Subscriptions.Runner.run(:walkthrough)
  _arguments -> raise "usage: mix run examples/16_subscriptions.exs [--check]"
end
