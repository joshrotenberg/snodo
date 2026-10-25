defmodule Snodo.Proxy.Backend do
  @moduledoc false

  use GenServer, restart: :temporary

  alias Snodo.Client
  alias Snodo.Client.Stdio
  alias Snodo.Client.Subscription
  alias Snodo.Error
  alias Snodo.Proxy.RequestLock
  alias Snodo.Server.Runtime

  @listen_filter %{
    "toolsListChanged" => true,
    "promptsListChanged" => true,
    "resourcesListChanged" => true
  }

  @doc false
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  # The manager never waits on a backend. A backend connects after start and
  # reports {:backend_ready, id, pid, snapshot} or {:backend_failed, id, pid,
  # reason}; a refresh is answered with {:backend_refreshed, id, pid, ref,
  # result}.

  @doc false
  def refresh(pid, ref), do: GenServer.cast(pid, {:refresh, ref})

  # Stdio log messages have no request ID. Keep finite requests on that
  # connection mutually exclusive, including background calls with callbacks.
  # The function runs in its caller so logging retains the handler's context.
  @doc false
  def request(%Client{transport: {Stdio, pid}}, fun) do
    RequestLock.run(pid, fun)
  end

  def request(%Client{}, fun), do: fun.()

  @impl true
  def init(opts) do
    state = %{
      id: Keyword.fetch!(opts, :id),
      prefix: Keyword.fetch!(opts, :prefix),
      manager: Keyword.fetch!(opts, :manager),
      client: nil,
      catalog: nil,
      health_interval_ms: Keyword.fetch!(opts, :health_interval_ms),
      queue_timeout_ms: Keyword.get(opts, :queue_timeout_ms, 30_000),
      listener: nil,
      resource_listeners: %{}
    }

    target = Keyword.fetch!(opts, :target)
    client_options = Keyword.get(opts, :client_options, [])
    {:ok, state, {:continue, {:connect, target, client_options}}}
  end

  @impl true
  def handle_continue({:connect, target, client_options}, state) do
    with {:ok, client} <- connect(target, client_options),
         :ok <- start_request_lock(client),
         {:ok, catalog} <- fetch_catalog_or_close(client) do
      state = %{
        state
        | client: client,
          catalog: catalog,
          listener: maybe_listen(client, @listen_filter),
          resource_listeners: open_resource_listeners(client, catalog)
      }

      Process.send_after(self(), :health_check, state.health_interval_ms)
      send(state.manager, {:backend_ready, state.id, self(), snapshot_state(state)})
      {:noreply, state}
    else
      {:error, reason} ->
        send(state.manager, {:backend_failed, state.id, self(), reason})
        {:stop, :normal, state}
    end
  end

  @impl true
  def handle_cast({:refresh, ref}, state) do
    {reply, state} =
      case fetch_catalog(state.client, state.queue_timeout_ms) do
        {:ok, catalog} ->
          state = update_catalog(state, catalog)
          {{:ok, snapshot_state(state)}, state}

        {:error, reason} ->
          {{:error, reason}, state}
      end

    send(state.manager, {:backend_refreshed, state.id, self(), ref, reply})
    {:noreply, state}
  end

  @impl true
  def handle_info(:listen, %{listener: nil} = state) do
    {:noreply, %{state | listener: maybe_listen(state.client, @listen_filter)}}
  end

  def handle_info(:listen_resources, state) do
    close_resource_listeners(state.resource_listeners)
    state = %{state | resource_listeners: open_resource_listeners(state.client, state.catalog)}
    notify_snapshot(state, nil)
    {:noreply, state}
  end

  def handle_info(:health_check, state) do
    case probe_client(state.client, state.queue_timeout_ms) do
      :ok ->
        if is_nil(state.listener), do: send(self(), :listen)
        state = refresh_and_notify(state, nil)
        {:noreply, schedule_health_check(state)}

      {:error, %Error{code: -32_603, data: %{"reason" => "stdio_queue_timeout"}}} ->
        {:noreply, schedule_health_check(state)}

      {:error, reason} ->
        send(state.manager, {:backend_error, state.id, self(), reason})
        {:stop, :normal, state}
    end
  end

  def handle_info(
        {:snodo_subscription, ref, {:notification, method, params}},
        %{listener: %Subscription{ref: ref} = listener} = state
      ) do
    state =
      case method do
        "notifications/tools/list_changed" ->
          refresh_and_notify(state, method)

        "notifications/prompts/list_changed" ->
          refresh_and_notify(state, method)

        "notifications/resources/list_changed" ->
          refresh_and_notify(state, method)

        "notifications/resources/updated" ->
          send(state.manager, {:backend_event, state.id, self(), method, params})
          state

        _other ->
          state
      end

    :ok = Subscription.demand(listener, 1)
    {:noreply, state}
  end

  def handle_info(
        {:snodo_subscription, ref, {:dropped, _count}},
        %{listener: %Subscription{ref: ref}} = state
      ) do
    {:noreply, refresh_and_notify(state, nil)}
  end

  def handle_info(
        {:snodo_subscription, ref, {:closed, _reason}},
        %{listener: %Subscription{ref: ref}} = state
      ) do
    Process.send_after(self(), :listen, 1_000)
    {:noreply, %{state | listener: nil}}
  end

  def handle_info({:snodo_subscription, ref, payload}, state) do
    case Map.fetch(state.resource_listeners, ref) do
      {:ok, subscription} ->
        {:noreply, handle_resource_event(state, subscription, payload)}

      :error ->
        {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if state.listener, do: safe_close(state.listener)
    close_resource_listeners(state.resource_listeners)
    if state.client, do: safe_close(state.client)
    :ok
  end

  defp connect({:direct, %Runtime{} = runtime}, opts), do: Client.direct(runtime, opts)
  defp connect(target, opts), do: Client.connect(target, opts)

  defp fetch_catalog_or_close(client) do
    case fetch_catalog(client) do
      {:ok, catalog} ->
        {:ok, catalog}

      {:error, reason} ->
        safe_close(client)
        {:error, reason}
    end
  end

  defp start_request_lock(%Client{transport: {Stdio, pid}}) do
    case RequestLock.start_link(pid) do
      {:ok, _lock} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp start_request_lock(%Client{}), do: :ok

  # Background requests without callbacks cannot capture another request's logs.
  defp background_request(%Client{on_log: nil}, fun, _timeout), do: fun.()

  defp background_request(%Client{transport: {Stdio, pid}}, fun, timeout),
    do: RequestLock.run(pid, fun, timeout)

  defp background_request(%Client{}, fun, _timeout), do: fun.()

  defp fetch_catalog(client, timeout \\ 30_000),
    do: background_request(client, fn -> do_fetch_catalog(client) end, timeout)

  defp do_fetch_catalog(client) do
    with {:ok, tools} <- optional_list(Client.list_tools(client)),
         {:ok, resources} <- optional_list(Client.list_resources(client)),
         {:ok, resource_templates} <- optional_list(Client.list_resource_templates(client)),
         {:ok, prompts} <- optional_list(Client.list_prompts(client)) do
      {:ok,
       %{
         tools: tools,
         resources: resources,
         resource_templates: resource_templates,
         prompts: prompts
       }}
    end
  end

  defp optional_list({:ok, list}) when is_list(list), do: {:ok, list}
  defp optional_list({:error, %{code: -32_601}}), do: {:ok, []}
  defp optional_list({:error, error}), do: {:error, error}

  defp schedule_health_check(state) do
    Process.send_after(self(), :health_check, state.health_interval_ms)
    state
  end

  defp probe_client(client, timeout),
    do: background_request(client, fn -> do_probe_client(client) end, timeout)

  defp do_probe_client(%Client{protocol: "2026-07-28"} = client) do
    case Client.discover(client, timeout: 5_000) do
      {:ok, _discovery} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  defp do_probe_client(client) do
    case Client.request(client, "ping", %{}, timeout: 5_000) do
      {:ok, _result} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  defp snapshot_state(state) do
    state
    |> Map.take([:id, :prefix, :client, :catalog])
    |> Map.put(:pid, self())
    |> Map.put(:subscribed_uris, accepted_resource_uris(state.resource_listeners))
  end

  defp refresh_and_notify(state, method) do
    case fetch_catalog(state.client, state.queue_timeout_ms) do
      {:ok, catalog} ->
        state = update_catalog(state, catalog)
        notify_snapshot(state, method)
        state

      {:error, %Error{code: -32_603, data: %{"reason" => "stdio_queue_timeout"}}} ->
        state

      {:error, reason} ->
        send(state.manager, {:backend_error, state.id, self(), reason})
        state
    end
  end

  defp maybe_listen(client, filter) do
    case Client.listen(client, filter) do
      {:ok, subscription} ->
        :ok = Subscription.demand(subscription, 1)
        subscription

      {:error, _unsupported} ->
        nil
    end
  rescue
    _error -> nil
  end

  defp open_resource_listeners(client, catalog) do
    catalog.resources
    |> Enum.map(& &1["uri"])
    |> Enum.filter(&is_binary/1)
    |> Enum.chunk_every(100)
    |> Enum.reduce(%{}, fn uris, listeners ->
      case maybe_listen(client, %{"resourceSubscriptions" => uris}) do
        %Subscription{ref: ref} = subscription -> Map.put(listeners, ref, subscription)
        nil -> listeners
      end
    end)
  end

  defp close_resource_listeners(listeners) do
    Enum.each(listeners, fn {_ref, subscription} -> safe_close(subscription) end)
  end

  defp update_catalog(state, catalog) do
    if state.catalog.resources == catalog.resources and
         resource_listeners_complete?(state.resource_listeners, catalog) do
      %{state | catalog: catalog}
    else
      close_resource_listeners(state.resource_listeners)

      %{
        state
        | catalog: catalog,
          resource_listeners: open_resource_listeners(state.client, catalog)
      }
    end
  end

  defp resource_listeners_complete?(listeners, catalog) do
    expected = MapSet.new(catalog.resources, & &1["uri"])
    MapSet.subset?(expected, accepted_resource_uris(listeners))
  end

  defp accepted_resource_uris(listeners) do
    Enum.reduce(listeners, MapSet.new(), fn {_ref, subscription}, accepted ->
      subscription.accepted
      |> Map.get("resourceSubscriptions", [])
      |> Enum.reduce(accepted, &MapSet.put(&2, &1))
    end)
  end

  defp notify_snapshot(state, method) do
    send(state.manager, {:backend_catalog, state.id, self(), snapshot_state(state), method})
  end

  defp handle_resource_event(state, subscription, {:notification, method, params}) do
    if method == "notifications/resources/updated" do
      send(state.manager, {:backend_event, state.id, self(), method, params})
    end

    :ok = Subscription.demand(subscription, 1)
    state
  end

  defp handle_resource_event(state, _subscription, {:dropped, count}) do
    send(state.manager, {:backend_error, state.id, self(), {:dropped_resource_events, count}})
    state
  end

  defp handle_resource_event(state, subscription, {:closed, _reason}) do
    Process.send_after(self(), :listen_resources, 1_000)
    state = %{state | resource_listeners: Map.delete(state.resource_listeners, subscription.ref)}
    notify_snapshot(state, nil)
    state
  end

  defp safe_close(handle) do
    case handle do
      %Subscription{} -> Subscription.close(handle)
      %Client{} -> Client.close(handle)
    end
  catch
    _kind, _reason -> :ok
  end
end
