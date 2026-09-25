defmodule SnodoTest.TestSubscriptionHub do
  use GenServer

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts)
  end

  def emit(hub, request_id, event), do: GenServer.call(hub, {:emit, request_id, event})
  def complete(hub, request_id), do: GenServer.call(hub, {:complete, request_id})

  @impl true
  def init(opts) do
    {:ok, %{owner: Keyword.get(opts, :owner), subscriptions: %{}}}
  end

  @impl true
  def handle_call({:open, request_id, filter}, _from, state) do
    token = make_ref()
    notify(state.owner, {:subscription_opened, request_id, filter})

    subscription = %{request_id: request_id, queue: :queue.new(), waiter: nil, closed?: false}
    state = put_in(state, [:subscriptions, token], subscription)
    {:reply, {:ok, filter, {self(), token}}, state}
  end

  def handle_call({:next, token}, from, state) do
    subscription = get_in(state, [:subscriptions, token])
    notify(state.owner, {:subscription_next, subscription.request_id})

    case :queue.out(subscription.queue) do
      {{:value, value}, queue} ->
        {:reply, value, put_in(state, [:subscriptions, token, :queue], queue)}

      {:empty, _queue} when subscription.closed? ->
        {:reply, :closed, state}

      {:empty, _queue} ->
        {:noreply, put_in(state, [:subscriptions, token, :waiter], from)}
    end
  end

  def handle_call({:emit, request_id, event}, _from, state) do
    {reply, state} = deliver_by_request_id(state, request_id, {:ok, event})
    {:reply, reply, state}
  end

  def handle_call({:complete, request_id}, _from, state) do
    {reply, state} = deliver_by_request_id(state, request_id, :closed)
    {:reply, reply, state}
  end

  def handle_call({:close, token, reason}, _from, state) do
    case Map.pop(state.subscriptions, token) do
      {nil, _subscriptions} ->
        {:reply, :ok, state}

      {subscription, subscriptions} ->
        if subscription.waiter, do: GenServer.reply(subscription.waiter, :closed)
        notify(state.owner, {:subscription_closed, subscription.request_id, reason})
        {:reply, :ok, %{state | subscriptions: subscriptions}}
    end
  end

  defp deliver_by_request_id(state, request_id, value) do
    case Enum.find(state.subscriptions, fn {_token, subscription} ->
           subscription.request_id == request_id
         end) do
      nil ->
        {{:error, :not_found}, state}

      {token, %{waiter: waiter} = subscription} when not is_nil(waiter) ->
        GenServer.reply(waiter, value)

        subscription =
          subscription
          |> Map.put(:waiter, nil)
          |> maybe_mark_closed(value)

        {:ok, put_in(state, [:subscriptions, token], subscription)}

      {token, subscription} ->
        subscription =
          if value == :closed do
            %{subscription | closed?: true}
          else
            %{subscription | queue: :queue.in(value, subscription.queue)}
          end

        {:ok, put_in(state, [:subscriptions, token], subscription)}
    end
  end

  defp maybe_mark_closed(subscription, :closed), do: %{subscription | closed?: true}
  defp maybe_mark_closed(subscription, _event), do: subscription

  defp notify(owner, message) when is_pid(owner), do: send(owner, message)
  defp notify(_owner, _message), do: :ok
end

defmodule SnodoTest.TestSubscriptionSource do
  @behaviour Snodo.Subscription.Source

  @impl true
  def open(filter, context, hub) do
    GenServer.call(hub, {:open, context.request_id, filter})
  end

  @impl true
  def next({hub, token}, _hub), do: GenServer.call(hub, {:next, token}, :infinity)

  @impl true
  def close({hub, token}, reason, _hub), do: GenServer.call(hub, {:close, token, reason})
end
