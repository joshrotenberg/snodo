defmodule SnodoTest.TestSubscriptionHub do
  use GenServer

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts)
  end

  def emit(hub, request_id, event), do: GenServer.call(hub, {:emit, request_id, event})
  def complete(hub, request_id), do: GenServer.call(hub, {:complete, request_id})
  def fail(hub, request_id, reason), do: GenServer.call(hub, {:fail, request_id, reason})

  @doc "Delivers `value` to every open subscription; see `emit/3`, `complete/2`, and `fail/3`."
  def emit_all(hub, event), do: GenServer.call(hub, {:all, {:ok, event}})
  def complete_all(hub), do: GenServer.call(hub, {:all, :closed})
  def fail_all(hub, reason), do: GenServer.call(hub, {:all, {:error, reason}})

  @doc "The number of open subscriptions, closing ones included."
  def count(hub), do: GenServer.call(hub, :count)

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

  # The worker closes the handle when its owner exits while the puller may
  # still be sending a pull, so a pull can arrive after the close.
  def handle_call({:next, token}, from, state) do
    case Map.fetch(state.subscriptions, token) do
      :error ->
        {:reply, :closed, state}

      {:ok, subscription} ->
        notify(state.owner, {:subscription_next, subscription.request_id})
        next_value(state, token, subscription, from)
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

  def handle_call({:fail, request_id, reason}, _from, state) do
    {reply, state} = deliver_by_request_id(state, request_id, {:error, reason})
    {:reply, reply, state}
  end

  def handle_call({:all, value}, _from, state) do
    state =
      Enum.reduce(state.subscriptions, state, fn {_token, subscription}, state ->
        {_reply, state} = deliver_by_request_id(state, subscription.request_id, value)
        state
      end)

    {:reply, :ok, state}
  end

  def handle_call(:count, _from, state), do: {:reply, map_size(state.subscriptions), state}

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

  defp next_value(state, token, subscription, from) do
    case :queue.out(subscription.queue) do
      {{:value, value}, queue} ->
        {:reply, value, put_in(state, [:subscriptions, token, :queue], queue)}

      {:empty, _queue} when subscription.closed? ->
        {:reply, :closed, state}

      {:empty, _queue} ->
        {:noreply, put_in(state, [:subscriptions, token, :waiter], from)}
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

defmodule SnodoTest.SubscriptionWorker do
  @moduledoc false

  @doc "Returns the puller a subscription worker links as it starts."
  def puller(worker, deadline \\ deadline()) do
    case Process.info(worker, :links) do
      {:links, [puller]} ->
        puller

      {:links, []} ->
        if System.monotonic_time(:millisecond) > deadline,
          do: raise("subscription worker #{inspect(worker)} started no puller")

        Process.sleep(5)
        puller(worker, deadline)
    end
  end

  @doc """
  Monitors each pid and returns `{pid, monitor}` pairs once every target has
  recorded its monitor.

  A monitor request can be overtaken by a kill sent from another process.
  `Process.info/2` is a signal from this process too, so it returns only after
  the target has handled the monitor request sent before it.
  """
  def monitor_confirmed(pids) do
    for pid <- pids do
      monitor = Process.monitor(pid)
      true = self() in monitored_by(pid)
      {pid, monitor}
    end
  end

  @doc "Waits until `watcher` monitors `pid`."
  def await_monitor(pid, watcher, deadline \\ deadline()) do
    cond do
      watcher in monitored_by(pid) ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        raise "#{inspect(watcher)} did not monitor #{inspect(pid)}"

      true ->
        Process.sleep(5)
        await_monitor(pid, watcher, deadline)
    end
  end

  defp monitored_by(pid) do
    {:monitored_by, watchers} = Process.info(pid, :monitored_by)
    watchers
  end

  defp deadline, do: System.monotonic_time(:millisecond) + 1_000
end
