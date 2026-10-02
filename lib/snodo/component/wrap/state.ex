defmodule Snodo.Component.Wrap.State do
  @moduledoc false

  use GenServer

  @name __MODULE__

  @doc false
  def start_link(_opts), do: GenServer.start_link(__MODULE__, %{}, name: @name)

  @doc false
  # A timed-out caller cannot cancel a queued acquire, which could orphan a lease.
  def acquire(scope, key, limit, owner),
    do: GenServer.call(@name, {:acquire, scope, key, limit, owner}, :infinity)

  @doc false
  def release(lease), do: GenServer.call(@name, {:release, lease}, :infinity)

  @doc false
  def consume(scope, key, limit, window_ms, max_keys),
    do: GenServer.call(@name, {:consume, scope, key, limit, window_ms, max_keys}, :infinity)

  @impl true
  def init(_opts) do
    {:ok, %{active: %{}, leases: %{}, monitors: %{}, rates: %{}}}
  end

  @impl true
  def handle_call({:acquire, scope, key, limit, owner}, _from, state) do
    id = {scope, key}
    active = Map.get(state.active, id, 0)

    if active >= limit do
      {:reply, {:error, :limited}, state}
    else
      lease = make_ref()
      monitor = Process.monitor(owner)

      state = %{
        state
        | active: Map.put(state.active, id, active + 1),
          leases: Map.put(state.leases, lease, {id, monitor}),
          monitors: Map.put(state.monitors, monitor, lease)
      }

      {:reply, {:ok, lease}, state}
    end
  end

  def handle_call({:release, lease}, _from, state) do
    {:reply, :ok, release_lease(state, lease, true)}
  end

  def handle_call({:consume, scope, key, limit, window_ms, max_keys}, _from, state) do
    now = System.monotonic_time(:millisecond)
    {entries, expiry} = Map.get(state.rates, scope, {%{}, :queue.new()})
    {entries, expiry} = drop_expired(entries, expiry, now, window_ms)

    case Map.get(entries, key) do
      {_started, count} when count >= limit ->
        {:reply, {:error, :limited}, put_rates(state, scope, entries, expiry)}

      {started, count} ->
        entries = Map.put(entries, key, {started, count + 1})
        {:reply, :ok, put_rates(state, scope, entries, expiry)}

      nil when map_size(entries) >= max_keys ->
        {:reply, {:error, :capacity}, put_rates(state, scope, entries, expiry)}

      nil ->
        entries = Map.put(entries, key, {now, 1})
        expiry = :queue.in({now, key}, expiry)
        {:reply, :ok, put_rates(state, scope, entries, expiry)}
    end
  end

  @impl true
  def handle_info({:DOWN, monitor, :process, _pid, _reason}, state) do
    case Map.fetch(state.monitors, monitor) do
      {:ok, lease} -> {:noreply, release_lease(state, lease, false)}
      :error -> {:noreply, state}
    end
  end

  defp release_lease(state, lease, demonitor?) do
    case Map.pop(state.leases, lease) do
      {nil, _leases} ->
        state

      {{id, monitor}, leases} ->
        if demonitor?, do: Process.demonitor(monitor, [:flush])
        active = Map.fetch!(state.active, id)

        active_map =
          if active == 1,
            do: Map.delete(state.active, id),
            else: Map.put(state.active, id, active - 1)

        %{
          state
          | active: active_map,
            leases: leases,
            monitors: Map.delete(state.monitors, monitor)
        }
    end
  end

  defp drop_expired(entries, expiry, now, window_ms) do
    case :queue.out(expiry) do
      {{:value, {started, key}}, rest} when now - started >= window_ms ->
        drop_expired(Map.delete(entries, key), rest, now, window_ms)

      _active_or_empty ->
        {entries, expiry}
    end
  end

  defp put_rates(state, scope, entries, expiry),
    do: %{state | rates: Map.put(state.rates, scope, {entries, expiry})}
end
