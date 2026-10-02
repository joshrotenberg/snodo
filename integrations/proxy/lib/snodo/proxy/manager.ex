defmodule Snodo.Proxy.Manager do
  @moduledoc false

  use GenServer

  alias Snodo.Proxy.Backend
  alias Snodo.Proxy.Catalog
  alias Snodo.Subscription.Event
  alias Snodo.Subscription.Hub

  @id_pattern ~r/\A[A-Za-z][A-Za-z0-9_-]*\z/
  @reconnect_ms 1_000

  @doc false
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))

  @doc false
  def catalog(proxy) do
    case Registry.lookup(Snodo.Proxy.Registry, {proxy, :catalog}) do
      [{_owner, catalog}] -> catalog
      [] -> raise ArgumentError, "proxy catalog is unavailable"
    end
  end

  @doc false
  def health(manager), do: GenServer.call(manager, :health)

  @doc false
  def add(manager, backend), do: GenServer.call(manager, {:add, backend}, :infinity)

  @doc false
  def remove(manager, id), do: GenServer.call(manager, {:remove, id})

  @doc false
  def refresh(manager, id), do: GenServer.call(manager, {:refresh, id}, :infinity)

  @impl true
  def init(opts) do
    max_backends = Keyword.fetch!(opts, :max_backends)
    max_catalog_items = Keyword.fetch!(opts, :max_catalog_items)
    health_interval_ms = Keyword.fetch!(opts, :health_interval_ms)
    validate_limits!(max_backends, max_catalog_items, health_interval_ms)
    catalog_key = {Keyword.fetch!(opts, :proxy), :catalog}
    {:ok, _owner} = Registry.register(Snodo.Proxy.Registry, catalog_key, %Catalog{})

    state = %{
      backends: %{},
      catalog: %Catalog{},
      catalog_key: catalog_key,
      backend_supervisor: Keyword.fetch!(opts, :backend_supervisor),
      hub: Keyword.fetch!(opts, :hub),
      health_interval_ms: health_interval_ms,
      max_backends: max_backends,
      max_catalog_items: max_catalog_items
    }

    opts
    |> Keyword.fetch!(:backends)
    |> Enum.reduce_while({:ok, state}, fn backend, {:ok, current} ->
      case add_backend(current, backend) do
        {:ok, next} -> {:cont, {:ok, next}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, ready} -> {:ok, ready}
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call(:health, _from, state) do
    health =
      Map.new(state.backends, fn {id, backend} ->
        status =
          cond do
            not is_pid(backend.pid) or not Process.alive?(backend.pid) -> :down
            not is_nil(backend.error) -> :degraded
            true -> :up
          end

        {id, %{status: status, error: backend.error}}
      end)

    {:reply, health, state}
  end

  def handle_call({:add, backend}, _from, state) do
    case add_backend(state, backend) do
      {:ok, next} -> {:reply, :ok, next}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:remove, id}, _from, state) do
    case Map.pop(state.backends, id) do
      {nil, _backends} ->
        {:reply, {:error, :not_found}, state}

      {%{pid: pid}, backends} ->
        _termination =
          if is_pid(pid), do: DynamicSupervisor.terminate_child(state.backend_supervisor, pid)

        {:ok, catalog} = build_catalog(backends, state.max_catalog_items)
        {:reply, :ok, install_catalog(state, backends, catalog)}
    end
  end

  def handle_call({:refresh, id}, _from, state) do
    case refresh_backend(state, id) do
      {:ok, next} -> {:reply, :ok, next}
      {:error, reason, next} -> {:reply, {:error, reason}, next}
    end
  end

  defp refresh_backend(state, id) do
    case Map.get(state.backends, id) do
      %{pid: pid} when is_pid(pid) ->
        refresh_active_backend(state, id, pid)

      _missing_or_down ->
        {:error, :not_found, state}
    end
  end

  defp refresh_active_backend(state, id, pid) do
    case Backend.refresh(pid) do
      {:ok, snapshot} ->
        case replace_snapshot(state, id, snapshot) do
          {:ok, next} -> {:ok, next}
          {:error, reason} -> {:error, reason, put_error(state, id, reason)}
        end

      {:error, reason} ->
        {:error, reason, put_error(state, id, reason)}
    end
  end

  @impl true
  def handle_info({:backend_catalog, id, pid, snapshot, method}, state) do
    case Map.get(state.backends, id) do
      %{pid: ^pid} ->
        case replace_snapshot(state, id, snapshot) do
          {:ok, next} ->
            :ok = relay_unchanged(state, next, method)
            {:noreply, next}

          {:error, reason} ->
            {:noreply, put_error(state, id, reason)}
        end

      _stale ->
        {:noreply, state}
    end
  end

  def handle_info({:backend_error, id, pid, reason}, state) do
    case Map.get(state.backends, id) do
      %{pid: ^pid} -> {:noreply, put_error(state, id, reason)}
      _stale -> {:noreply, state}
    end
  end

  def handle_info(
        {:backend_event, id, pid, "notifications/resources/updated", %{"uri" => uri}},
        state
      )
      when is_binary(uri) do
    public_uri = Catalog.uri(id, uri)

    _publication =
      case {Map.get(state.backends, id), Catalog.lookup_resource(state.catalog, public_uri)} do
        {%{pid: ^pid}, {:ok, %{backend_pid: ^pid}, _original_uri}} ->
          Hub.publish(state.hub, Event.resource_updated(public_uri))

        _stale_or_unknown ->
          :ok
      end

    {:noreply, state}
  end

  def handle_info({:DOWN, _ref, :process, pid, reason}, state) do
    case Enum.find(state.backends, fn {_id, backend} -> backend.pid == pid end) do
      {id, backend} ->
        error = if reason == :normal, do: backend.error || reason, else: reason

        backends =
          Map.put(state.backends, id, %{backend | pid: nil, snapshot: nil, error: error})

        {:ok, catalog} = build_catalog(backends, state.max_catalog_items)
        Process.send_after(self(), {:reconnect, id}, @reconnect_ms)
        {:noreply, install_catalog(state, backends, catalog)}

      nil ->
        {:noreply, state}
    end
  end

  def handle_info({:reconnect, id}, state) do
    case Map.get(state.backends, id) do
      %{pid: nil, config: config} ->
        case restart_backend(state, id, config) do
          {:ok, next} ->
            {:noreply, next}

          {:error, reason} ->
            Process.send_after(self(), {:reconnect, id}, @reconnect_ms)
            {:noreply, put_error(state, id, reason)}
        end

      _removed_or_up ->
        {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp add_backend(state, raw_backend) do
    with {:ok, config} <- normalize_backend(raw_backend),
         :ok <- available(state, config.id) do
      restart_backend(state, config.id, config)
    end
  end

  defp restart_backend(state, id, config) do
    child =
      {Backend,
       [
         id: id,
         prefix: config.prefix,
         target: config.target,
         client_options: config.client_options,
         health_interval_ms: state.health_interval_ms,
         manager: self()
       ]}

    with {:ok, pid} <- DynamicSupervisor.start_child(state.backend_supervisor, child) do
      snapshot = Backend.snapshot(pid)
      backend = %{pid: pid, snapshot: snapshot, config: config, error: nil}
      backends = Map.put(state.backends, id, backend)

      case build_catalog(backends, state.max_catalog_items) do
        {:ok, catalog} ->
          _ref = Process.monitor(pid)
          {:ok, install_catalog(state, backends, catalog)}

        {:error, reason} ->
          :ok = DynamicSupervisor.terminate_child(state.backend_supervisor, pid)
          {:error, reason}
      end
    end
  end

  defp replace_snapshot(state, id, snapshot) do
    backend = state.backends |> Map.fetch!(id) |> Map.merge(%{snapshot: snapshot, error: nil})
    backends = Map.put(state.backends, id, backend)

    case build_catalog(backends, state.max_catalog_items) do
      {:ok, catalog} ->
        {:ok, install_catalog(state, backends, catalog)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp build_catalog(backends, max_items) do
    snapshots = for {_id, %{snapshot: snapshot}} <- backends, not is_nil(snapshot), do: snapshot
    Catalog.new(snapshots, max_items)
  end

  defp available(state, id) do
    cond do
      Map.has_key?(state.backends, id) ->
        {:error, {:duplicate_backend, id}}

      map_size(state.backends) >= state.max_backends ->
        {:error, {:backend_limit, state.max_backends}}

      true ->
        :ok
    end
  end

  defp normalize_backend(backend) when is_list(backend) do
    if Keyword.keyword?(backend),
      do: normalize_backend(Map.new(backend)),
      else: {:error, :invalid_backend}
  end

  defp normalize_backend(%{id: id, target: target} = backend) when is_binary(id) do
    prefix = Map.get(backend, :prefix, id <> ".")
    client_options = Map.get(backend, :client_options, [])

    if Regex.match?(@id_pattern, id) and is_binary(prefix) and
         Keyword.keyword?(client_options) do
      {:ok, %{id: id, prefix: prefix, target: target, client_options: client_options}}
    else
      {:error, :invalid_backend}
    end
  end

  defp normalize_backend(_invalid), do: {:error, :invalid_backend}

  defp validate_limits!(max_backends, max_catalog_items, health_interval_ms) do
    unless is_integer(max_backends) and max_backends > 0 and
             is_integer(max_catalog_items) and max_catalog_items > 0 and
             is_integer(health_interval_ms) and health_interval_ms > 0 do
      raise ArgumentError,
            ":max_backends, :max_catalog_items, and :health_interval_ms must be positive integers"
    end
  end

  defp put_error(state, id, reason) do
    %{state | backends: Map.update!(state.backends, id, &%{&1 | error: reason})}
  end

  defp put_catalog(state, catalog) do
    _updated =
      Registry.update_value(Snodo.Proxy.Registry, state.catalog_key, fn _old -> catalog end)

    %{state | catalog: catalog}
  end

  defp install_catalog(state, backends, catalog) do
    next = put_catalog(%{state | backends: backends}, catalog)
    :ok = publish_changes(state.hub, state.catalog, catalog)
    next
  end

  defp publish_changes(hub, old, new) do
    changed = Catalog.changed_kinds(old, new)

    events =
      []
      |> maybe_event(:tools in changed, Event.tools_list_changed())
      |> maybe_event(:prompts in changed, Event.prompts_list_changed())
      |> maybe_event(
        :resources in changed or :resource_templates in changed,
        Event.resources_list_changed()
      )

    Enum.each(events, fn event -> {:ok, _report} = Hub.publish(hub, event) end)
    :ok
  end

  defp relay_unchanged(previous, current, method) do
    changed = Catalog.changed_kinds(previous.catalog, current.catalog)

    _result =
      case method do
        "notifications/tools/list_changed" ->
          if :tools not in changed,
            do: {:ok, _report} = Hub.publish(current.hub, Event.tools_list_changed())

        "notifications/prompts/list_changed" ->
          if :prompts not in changed,
            do: {:ok, _report} = Hub.publish(current.hub, Event.prompts_list_changed())

        "notifications/resources/list_changed" ->
          if :resources not in changed and :resource_templates not in changed,
            do: {:ok, _report} = Hub.publish(current.hub, Event.resources_list_changed())

        _other ->
          :ok
      end

    :ok
  end

  defp maybe_event(events, true, event), do: [event | events]
  defp maybe_event(events, false, _event), do: events
end
