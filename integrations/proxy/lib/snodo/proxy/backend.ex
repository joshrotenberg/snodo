defmodule Snodo.Proxy.Backend do
  @moduledoc false

  use GenServer, restart: :temporary

  alias Snodo.Client
  alias Snodo.Client.Subscription
  alias Snodo.Server.Runtime

  @listen_filter %{
    "toolsListChanged" => true,
    "promptsListChanged" => true,
    "resourcesListChanged" => true
  }

  @doc false
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc false
  def snapshot(pid), do: GenServer.call(pid, :snapshot)

  @doc false
  def refresh(pid), do: GenServer.call(pid, :refresh, :infinity)

  @impl true
  def init(opts) do
    target = Keyword.fetch!(opts, :target)
    client_options = Keyword.get(opts, :client_options, [])

    case connect(target, client_options) do
      {:ok, client} ->
        case fetch_catalog(client) do
          {:ok, catalog} ->
            listener = maybe_listen(client, @listen_filter)
            resource_listeners = open_resource_listeners(client, catalog)
            health_interval_ms = Keyword.fetch!(opts, :health_interval_ms)
            Process.send_after(self(), :health_check, health_interval_ms)

            {:ok,
             %{
               id: Keyword.fetch!(opts, :id),
               prefix: Keyword.fetch!(opts, :prefix),
               manager: Keyword.fetch!(opts, :manager),
               client: client,
               catalog: catalog,
               health_interval_ms: health_interval_ms,
               listener: listener,
               resource_listeners: resource_listeners
             }}

          {:error, reason} ->
            safe_close(client)
            {:stop, reason}
        end

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call(:snapshot, _from, state) do
    {:reply, snapshot_state(state), state}
  end

  def handle_call(:refresh, _from, state) do
    case fetch_catalog(state.client) do
      {:ok, catalog} ->
        state = update_catalog(state, catalog)
        {:reply, {:ok, snapshot_state(state)}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
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
    case probe_client(state.client) do
      :ok ->
        if is_nil(state.listener), do: send(self(), :listen)
        state = refresh_and_notify(state, nil)
        Process.send_after(self(), :health_check, state.health_interval_ms)
        {:noreply, state}

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
    safe_close(state.client)
    :ok
  end

  defp connect({:direct, %Runtime{} = runtime}, opts), do: Client.direct(runtime, opts)
  defp connect(target, opts), do: Client.connect(target, opts)

  defp fetch_catalog(client) do
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

  defp probe_client(%Client{protocol: "2026-07-28"} = client) do
    case Client.discover(client, timeout: 5_000) do
      {:ok, _discovery} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  defp probe_client(client) do
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
    case fetch_catalog(state.client) do
      {:ok, catalog} ->
        state = update_catalog(state, catalog)
        notify_snapshot(state, method)
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
