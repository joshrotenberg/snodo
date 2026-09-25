defmodule Snodo.Subscription.Hub do
  @moduledoc """
  An opt-in, application-supervised `Snodo.Subscription.Source`.

  A hub broadcasts protocol-neutral `Snodo.Subscription.Event` values to every
  listener whose accepted filter selects the event. Each listener has its own
  bounded queue, so a client that stops reading cannot make the hub's memory
  usage grow without limit. The default overflow policy keeps the newest
  information by dropping the oldest queued event; applications may instead
  configure `overflow: :drop_newest`.

  The hub is application state, not router state. Start it under the
  application's supervision tree and pass `source/1` to `Snodo.Server.runtime/1`:

      children = [{Snodo.Subscription.Hub, name: MyApp.SubscriptionHub}]

      runtime =
        MyServer.runtime(
          subscription_source: Snodo.Subscription.Hub.source(MyApp.SubscriptionHub)
        )

  Publishers may send an existing event with `publish/2` or use the core event
  helpers such as `notify_tools_list_changed/2`. Extensions publish their own
  `Snodo.Subscription.Event.extension/4` values through the same `publish/2`
  function; the negotiated extension remains responsible for filter admission
  and wire shaping.
  """

  use GenServer

  alias Snodo.Instrumentation
  alias Snodo.Subscription.Event
  alias Snodo.Subscription.Filter

  @behaviour Snodo.Subscription.Source

  @default_max_buffer 100
  @overflow_policies [:drop_oldest, :drop_newest]

  @type server :: GenServer.server()
  @type overflow_policy :: :drop_oldest | :drop_newest
  @type delivery_report :: %{
          matched: non_neg_integer(),
          delivered: non_neg_integer(),
          buffered: non_neg_integer(),
          dropped: non_neg_integer()
        }

  @doc """
  Starts an application-owned subscription hub.

  Options are:

    * `:name` - a standard `GenServer` registered name;
    * `:max_buffer` - the positive per-listener queue bound, defaulting to
      `#{@default_max_buffer}`;
    * `:overflow` - either `:drop_oldest` (the default) or `:drop_newest`.
    * `:instrumentation` - an optional `Snodo.Instrumentation` sink.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) when is_list(opts) do
    validate_options!(opts)

    config = %{
      max_buffer: Keyword.get(opts, :max_buffer, @default_max_buffer),
      overflow: Keyword.get(opts, :overflow, :drop_oldest),
      instrumentation: opts |> Keyword.get(:instrumentation) |> Instrumentation.normalize!()
    }

    GenServer.start_link(__MODULE__, config, Keyword.take(opts, [:name]))
  end

  @doc "Returns a source configuration suitable for `Snodo.Server.runtime/1`."
  @spec source(server()) :: {module(), server()}
  def source(hub), do: {__MODULE__, hub}

  @doc """
  Publishes one protocol-neutral event to every matching listener.

  The report distinguishes events delivered directly to a blocked pull from
  events placed in a listener queue. `:dropped` counts per-listener overflow,
  so one publication can be dropped more than once.
  """
  @spec publish(server(), Event.t()) ::
          {:ok, delivery_report()} | {:error, {:invalid_event, String.t()}}
  def publish(hub, %Event{} = event) do
    case Event.validate(event) do
      :ok -> GenServer.call(hub, {:publish, event})
      {:error, message} -> {:error, {:invalid_event, message}}
    end
  end

  def publish(_hub, _invalid) do
    {:error, {:invalid_event, "subscription producer requires an Snodo.Subscription.Event"}}
  end

  @doc "Publishes a tool-list change event."
  @spec notify_tools_list_changed(server(), keyword()) ::
          {:ok, delivery_report()} | {:error, {:invalid_event, String.t()}}
  def notify_tools_list_changed(hub, opts \\ []) do
    publish(hub, Event.tools_list_changed(opts))
  end

  @doc "Publishes a prompt-list change event."
  @spec notify_prompts_list_changed(server(), keyword()) ::
          {:ok, delivery_report()} | {:error, {:invalid_event, String.t()}}
  def notify_prompts_list_changed(hub, opts \\ []) do
    publish(hub, Event.prompts_list_changed(opts))
  end

  @doc "Publishes a resource-list change event."
  @spec notify_resources_list_changed(server(), keyword()) ::
          {:ok, delivery_report()} | {:error, {:invalid_event, String.t()}}
  def notify_resources_list_changed(hub, opts \\ []) do
    publish(hub, Event.resources_list_changed(opts))
  end

  @doc "Publishes an update event for one absolute resource URI."
  @spec notify_resource_updated(server(), String.t(), keyword()) ::
          {:ok, delivery_report()} | {:error, {:invalid_event, String.t()}}
  def notify_resource_updated(hub, uri, opts \\ []) do
    publish(hub, Event.resource_updated(uri, opts))
  end

  @doc "Gracefully completes every listener currently attached to the hub."
  @spec complete(server()) :: :ok
  def complete(hub), do: GenServer.call(hub, :complete)

  @doc "Returns bounded-queue and listener counts for operational inspection."
  @spec stats(server()) :: %{
          subscriptions: non_neg_integer(),
          closing: non_neg_integer(),
          queued: non_neg_integer(),
          dropped: non_neg_integer(),
          max_buffer: pos_integer(),
          overflow: overflow_policy()
        }
  def stats(hub), do: GenServer.call(hub, :stats)

  @impl Snodo.Subscription.Source
  def open(requested_filter, context, hub) do
    if Filter.valid?(requested_filter) do
      metadata = %{
        filter_keys: requested_filter |> Map.keys() |> Enum.sort(),
        request_id: context.request_id,
        transport: context.transport.transport
      }

      GenServer.call(hub, {:open, requested_filter, metadata})
    else
      {:error, :invalid_filter}
    end
  end

  @impl Snodo.Subscription.Source
  def next({hub, token}, _hub), do: GenServer.call(hub, {:next, token}, :infinity)

  @impl Snodo.Subscription.Source
  def close({hub, token}, reason, _hub), do: GenServer.call(hub, {:close, token, reason})

  @impl GenServer
  def init(config) do
    {:ok,
     %{
       subscriptions: %{},
       max_buffer: config.max_buffer,
       overflow: config.overflow,
       instrumentation: config.instrumentation,
       dropped: 0
     }}
  end

  @impl GenServer
  def handle_call({:open, filter, metadata}, _from, state) do
    token = make_ref()
    subscription = %{filter: filter, queue: :queue.new(), waiter: nil, closed?: false}
    subscriptions = Map.put(state.subscriptions, token, subscription)
    next = %{state | subscriptions: subscriptions}

    Instrumentation.emit(
      state.instrumentation,
      [:snodo, :subscription, :open],
      %{subscriptions: map_size(subscriptions)},
      metadata
    )

    {:reply, {:ok, filter, {self(), token}}, next}
  end

  def handle_call({:next, token}, from, state) do
    case Map.fetch(state.subscriptions, token) do
      :error ->
        {:reply, :closed, state}

      {:ok, %{waiter: waiter}} when not is_nil(waiter) ->
        {:reply, {:error, :pull_already_pending}, state}

      {:ok, subscription} ->
        next_event(state, token, subscription, from)
    end
  end

  def handle_call({:close, token, reason}, _from, state) do
    case Map.pop(state.subscriptions, token) do
      {nil, _subscriptions} ->
        {:reply, :ok, state}

      {%{waiter: waiter}, subscriptions} ->
        if waiter, do: GenServer.reply(waiter, :closed)

        Instrumentation.emit(
          state.instrumentation,
          [:snodo, :subscription, :close],
          %{subscriptions: map_size(subscriptions)},
          %{reason: classify_close_reason(reason)}
        )

        {:reply, :ok, %{state | subscriptions: subscriptions}}
    end
  end

  def handle_call({:publish, event}, _from, state) do
    {subscriptions, report} = publish_to_subscriptions(state, event)

    next_state = %{
      state
      | subscriptions: subscriptions,
        dropped: state.dropped + report.dropped
    }

    measurements = Map.put(report, :queued, queued_count(subscriptions))
    metadata = event_metadata(event)

    Instrumentation.emit(
      state.instrumentation,
      [:snodo, :subscription, :publish],
      measurements,
      metadata
    )

    if report.dropped > 0 do
      Instrumentation.emit(
        state.instrumentation,
        [:snodo, :subscription, :overflow],
        %{dropped: report.dropped, queued: measurements.queued},
        Map.put(metadata, :policy, state.overflow)
      )
    end

    {:reply, {:ok, report}, next_state}
  end

  def handle_call(:complete, _from, state) do
    subscriptions =
      Map.new(state.subscriptions, fn {token, subscription} ->
        if subscription.waiter, do: GenServer.reply(subscription.waiter, :closed)
        {token, %{subscription | closed?: true, waiter: nil}}
      end)

    Instrumentation.emit(
      state.instrumentation,
      [:snodo, :subscription, :complete],
      %{subscriptions: map_size(subscriptions), queued: queued_count(subscriptions)},
      %{}
    )

    {:reply, :ok, %{state | subscriptions: subscriptions}}
  end

  def handle_call(:stats, _from, state) do
    closing = Enum.count(state.subscriptions, fn {_token, entry} -> entry.closed? end)

    queued =
      Enum.sum(Enum.map(state.subscriptions, fn {_token, entry} -> :queue.len(entry.queue) end))

    stats = %{
      subscriptions: map_size(state.subscriptions),
      closing: closing,
      queued: queued,
      dropped: state.dropped,
      max_buffer: state.max_buffer,
      overflow: state.overflow
    }

    {:reply, stats, state}
  end

  defp next_event(state, token, subscription, from) do
    case :queue.out(subscription.queue) do
      {{:value, event}, queue} ->
        subscriptions = put_in(state.subscriptions, [token, :queue], queue)
        {:reply, {:ok, event}, %{state | subscriptions: subscriptions}}

      {:empty, _queue} when subscription.closed? ->
        {:reply, :closed, state}

      {:empty, _queue} ->
        subscriptions = put_in(state.subscriptions, [token, :waiter], from)
        {:noreply, %{state | subscriptions: subscriptions}}
    end
  end

  defp publish_to_subscriptions(state, event) do
    initial_report = %{matched: 0, delivered: 0, buffered: 0, dropped: 0}

    Enum.reduce(state.subscriptions, {%{}, initial_report}, fn {token, subscription},
                                                               {subscriptions, report} ->
      {subscription, report} = deliver(subscription, event, state, report)
      {Map.put(subscriptions, token, subscription), report}
    end)
  end

  defp deliver(%{closed?: true} = subscription, _event, _state, report),
    do: {subscription, report}

  defp deliver(subscription, event, state, report) do
    if selected?(subscription.filter, event) do
      deliver_selected(subscription, event, state, increment(report, :matched))
    else
      {subscription, report}
    end
  end

  defp deliver_selected(%{waiter: waiter} = subscription, event, _state, report)
       when not is_nil(waiter) do
    GenServer.reply(waiter, {:ok, event})
    {%{subscription | waiter: nil}, increment(report, :delivered)}
  end

  defp deliver_selected(subscription, event, state, report) do
    if :queue.len(subscription.queue) < state.max_buffer do
      buffered = %{subscription | queue: :queue.in(event, subscription.queue)}
      {buffered, increment(report, :buffered)}
    else
      overflow(subscription, event, state.overflow, report)
    end
  end

  defp overflow(subscription, event, :drop_oldest, report) do
    {{:value, _dropped}, queue} = :queue.out(subscription.queue)
    buffered = %{subscription | queue: :queue.in(event, queue)}
    {buffered, report |> increment(:buffered) |> increment(:dropped)}
  end

  defp overflow(subscription, _event, :drop_newest, report) do
    {subscription, increment(report, :dropped)}
  end

  defp selected?(filter, %Event{kind: :tools_list_changed}),
    do: Map.get(filter, "toolsListChanged") == true

  defp selected?(filter, %Event{kind: :prompts_list_changed}),
    do: Map.get(filter, "promptsListChanged") == true

  defp selected?(filter, %Event{kind: :resources_list_changed}),
    do: Map.get(filter, "resourcesListChanged") == true

  defp selected?(filter, %Event{kind: :resource_updated, uri: uri}),
    do: uri in Map.get(filter, "resourceSubscriptions", [])

  defp selected?(filter, %Event{kind: :extension, selector: selector}),
    do: Filter.subset?(selector, filter)

  defp increment(report, key), do: Map.update!(report, key, &(&1 + 1))

  defp validate_options!(opts) do
    unknown = Keyword.keys(opts) -- [:name, :max_buffer, :overflow, :instrumentation]

    if unknown != [] do
      raise ArgumentError, "unknown subscription hub options: #{inspect(Enum.uniq(unknown))}"
    end

    max_buffer = Keyword.get(opts, :max_buffer, @default_max_buffer)
    overflow = Keyword.get(opts, :overflow, :drop_oldest)

    unless is_integer(max_buffer) and max_buffer > 0 do
      raise ArgumentError, "subscription hub max_buffer must be a positive integer"
    end

    unless overflow in @overflow_policies do
      raise ArgumentError,
            "subscription hub overflow must be :drop_oldest or :drop_newest"
    end
  end

  defp queued_count(subscriptions) do
    Enum.sum(Enum.map(subscriptions, fn {_token, entry} -> :queue.len(entry.queue) end))
  end

  defp event_metadata(%Event{kind: :extension} = event),
    do: %{event_kind: :extension, extension_id: event.extension_id}

  defp event_metadata(%Event{kind: kind}), do: %{event_kind: kind}

  defp classify_close_reason({:cancelled, _reason}), do: :cancelled
  defp classify_close_reason({:disconnected, _reason}), do: :disconnected
  defp classify_close_reason({:error, _reason}), do: :error

  defp classify_close_reason(reason) when reason in [:cancelled, :disconnected, :complete],
    do: reason

  defp classify_close_reason(_reason), do: :other
end
