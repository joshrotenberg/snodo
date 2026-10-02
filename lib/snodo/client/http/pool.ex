defmodule Snodo.Client.HTTP.Pool do
  @moduledoc false

  use GenServer

  @doc false
  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @doc false
  def checkout(key, limits, timeout) do
    id = make_ref()

    try do
      GenServer.call(__MODULE__, {:checkout, key, limits, id}, timeout)
    catch
      :exit, {:timeout, _call} ->
        GenServer.cast(__MODULE__, {:cancel, id})
        {:error, :timeout}
    end
  end

  @doc false
  def checkin(id, socket) do
    {module, raw_socket} = socket

    with :ok <- GenServer.call(__MODULE__, {:prepare_checkin, id, socket}),
         :ok <- module.controlling_process(raw_socket, Process.whereis(__MODULE__)) do
      GenServer.call(__MODULE__, {:complete_checkin, id})
    else
      {:error, _reason} -> discard(id, socket)
    end
  end

  @doc false
  def discard(id, socket) do
    if socket != nil, do: close_socket(socket)
    GenServer.call(__MODULE__, {:discard, id})
  end

  @doc false
  def detach(id), do: GenServer.call(__MODULE__, {:discard, id})

  @doc false
  def close(key), do: GenServer.call(__MODULE__, {:close, key})

  @impl true
  def init(:ok), do: {:ok, %{buckets: %{}, leases: %{}, monitors: %{}}}

  @impl true
  def handle_call({:checkout, key, limits, id}, from, state) do
    bucket = Map.get(state.buckets, key, new_bucket(limits))

    if bucket.closed do
      {:reply, {:error, :closed}, state}
    else
      checkout_or_wait(key, id, from, bucket, state)
    end
  end

  def handle_call({:prepare_checkin, id, socket}, {owner, _tag}, state) do
    case Map.fetch(state.leases, id) do
      {:ok, %{owner: ^owner} = lease} ->
        lease = %{lease | socket: socket}
        {:reply, :ok, %{state | leases: Map.put(state.leases, id, lease)}}

      _missing_or_wrong_owner ->
        {:reply, {:error, :missing_lease}, state}
    end
  end

  def handle_call({:complete_checkin, id}, {owner, _tag}, state) do
    case Map.fetch(state.leases, id) do
      {:ok, %{owner: ^owner} = lease} ->
        socket = lease.socket
        state = end_lease(state, id, lease)
        bucket = Map.fetch!(state.buckets, lease.key)
        uses = lease.uses + 1

        bucket =
          if bucket.closed or uses >= bucket.max_requests do
            close_socket(socket)
            %{bucket | total: bucket.total - 1}
          else
            timer =
              Process.send_after(self(), {:idle_expired, lease.key, id}, bucket.idle_timeout)

            %{bucket | idle: bucket.idle ++ [%{id: id, socket: socket, uses: uses, timer: timer}]}
          end

        state =
          state
          |> put_bucket(lease.key, bucket)
          |> serve_waiters(lease.key)
          |> maybe_drop_bucket(lease.key)

        {:reply, :ok, state}

      _missing_or_wrong_owner ->
        {:reply, :ok, state}
    end
  end

  def handle_call({:discard, id}, _from, state) do
    {:reply, :ok, release_lease(state, id)}
  end

  def handle_call({:close, key}, _from, state) do
    case Map.fetch(state.buckets, key) do
      :error ->
        {:reply, :ok, state}

      {:ok, bucket} ->
        Enum.each(bucket.idle, fn entry ->
          _remaining = Process.cancel_timer(entry.timer)
          close_socket(entry.socket)
        end)

        Enum.each(bucket.waiters, fn waiter ->
          Process.demonitor(waiter.monitor, [:flush])
          GenServer.reply(waiter.from, {:error, :closed})
        end)

        monitors = Enum.reduce(bucket.waiters, state.monitors, &Map.delete(&2, &1.monitor))

        bucket = %{
          bucket
          | idle: [],
            waiters: [],
            total: bucket.total - length(bucket.idle),
            closed: true
        }

        state = %{state | monitors: monitors} |> put_bucket(key, bucket) |> maybe_drop_bucket(key)
        {:reply, :ok, state}
    end
  end

  @impl true
  def handle_cast({:cancel, id}, state) do
    case Map.fetch(state.leases, id) do
      {:ok, lease} ->
        close_if_owned(lease)
        {:noreply, release_lease(state, id)}

      :error ->
        {:noreply, cancel_waiter(state, id)}
    end
  end

  @impl true
  def handle_info({:DOWN, monitor, :process, _pid, _reason}, state) do
    case Map.pop(state.monitors, monitor) do
      {{:lease, id}, monitors} ->
        close_if_owned(Map.fetch!(state.leases, id))
        {:noreply, release_lease(%{state | monitors: monitors}, id)}

      {{:waiter, key, id}, monitors} ->
        {:noreply, remove_waiter(%{state | monitors: monitors}, key, id)}

      {nil, _monitors} ->
        {:noreply, state}
    end
  end

  def handle_info({:idle_expired, key, id}, state) do
    case Map.fetch(state.buckets, key) do
      {:ok, bucket} ->
        {expired, idle} = Enum.split_with(bucket.idle, &(&1.id == id))
        Enum.each(expired, &close_socket(&1.socket))
        bucket = %{bucket | idle: idle, total: bucket.total - length(expired)}

        {:noreply,
         state |> put_bucket(key, bucket) |> serve_waiters(key) |> maybe_drop_bucket(key)}

      :error ->
        {:noreply, state}
    end
  end

  defp new_bucket({size, idle_timeout, max_requests}) do
    %{
      size: size,
      idle_timeout: idle_timeout,
      max_requests: max_requests,
      total: 0,
      idle: [],
      waiters: [],
      closed: false
    }
  end

  defp checkout_or_wait(key, id, from, bucket, state) do
    owner = elem(from, 0)
    {entry, bucket} = take_idle(bucket, owner)

    cond do
      entry != nil ->
        state =
          state |> put_bucket(key, bucket) |> add_lease(key, id, owner, entry.uses, entry.socket)

        {:reply, {:ok, entry.socket, id}, state}

      bucket.total < bucket.size ->
        bucket = %{bucket | total: bucket.total + 1}
        state = state |> put_bucket(key, bucket) |> add_lease(key, id, owner, 0)
        {:reply, {:open, id}, state}

      true ->
        monitor = Process.monitor(owner)
        waiter = %{id: id, from: from, monitor: monitor}
        bucket = %{bucket | waiters: bucket.waiters ++ [waiter]}
        state = %{state | monitors: Map.put(state.monitors, monitor, {:waiter, key, id})}
        {:noreply, put_bucket(state, key, bucket)}
    end
  end

  defp take_idle(%{idle: []} = bucket, _owner), do: {nil, bucket}

  defp take_idle(%{idle: [entry | rest]} = bucket, owner) do
    _remaining = Process.cancel_timer(entry.timer)
    bucket = %{bucket | idle: rest}
    {module, socket} = entry.socket

    if socket_available?(entry.socket) and module.controlling_process(socket, owner) == :ok do
      {entry, bucket}
    else
      close_socket(entry.socket)
      take_idle(%{bucket | total: bucket.total - 1}, owner)
    end
  end

  defp socket_available?({module, socket}), do: module.recv(socket, 0, 0) == {:error, :timeout}

  defp add_lease(state, key, id, owner, uses, socket \\ nil, monitor \\ nil) do
    monitor = monitor || Process.monitor(owner)
    lease = %{key: key, owner: owner, monitor: monitor, uses: uses, socket: socket}

    %{
      state
      | leases: Map.put(state.leases, id, lease),
        monitors: Map.put(state.monitors, monitor, {:lease, id})
    }
  end

  defp end_lease(state, id, lease) do
    Process.demonitor(lease.monitor, [:flush])

    %{
      state
      | leases: Map.delete(state.leases, id),
        monitors: Map.delete(state.monitors, lease.monitor)
    }
  end

  defp release_lease(state, id) do
    case Map.fetch(state.leases, id) do
      {:ok, lease} ->
        state = end_lease(state, id, lease)
        bucket = Map.fetch!(state.buckets, lease.key)
        bucket = %{bucket | total: bucket.total - 1}

        state
        |> put_bucket(lease.key, bucket)
        |> serve_waiters(lease.key)
        |> maybe_drop_bucket(lease.key)

      :error ->
        state
    end
  end

  defp cancel_waiter(state, id) do
    Enum.reduce(Map.keys(state.buckets), state, fn key, state ->
      bucket = Map.fetch!(state.buckets, key)

      case Enum.find(bucket.waiters, &(&1.id == id)) do
        nil ->
          state

        waiter ->
          Process.demonitor(waiter.monitor, [:flush])
          state = %{state | monitors: Map.delete(state.monitors, waiter.monitor)}
          remove_waiter(state, key, id)
      end
    end)
  end

  defp remove_waiter(state, key, id) do
    bucket = Map.fetch!(state.buckets, key)
    bucket = %{bucket | waiters: Enum.reject(bucket.waiters, &(&1.id == id))}
    state |> put_bucket(key, bucket) |> maybe_drop_bucket(key)
  end

  defp serve_waiters(state, key) do
    bucket = Map.fetch!(state.buckets, key)

    case bucket.waiters do
      [waiter | rest] when not bucket.closed ->
        bucket = %{bucket | waiters: rest}
        {entry, bucket} = take_idle(bucket, elem(waiter.from, 0))

        cond do
          entry != nil ->
            state =
              state
              |> put_bucket(key, bucket)
              |> add_lease(
                key,
                waiter.id,
                elem(waiter.from, 0),
                entry.uses,
                entry.socket,
                waiter.monitor
              )

            GenServer.reply(waiter.from, {:ok, entry.socket, waiter.id})
            serve_waiters(state, key)

          bucket.total < bucket.size ->
            bucket = %{bucket | total: bucket.total + 1}

            state =
              state
              |> put_bucket(key, bucket)
              |> add_lease(key, waiter.id, elem(waiter.from, 0), 0, nil, waiter.monitor)

            GenServer.reply(waiter.from, {:open, waiter.id})
            serve_waiters(state, key)

          true ->
            put_bucket(state, key, %{bucket | waiters: [waiter | rest]})
        end

      _empty_or_closed ->
        state
    end
  end

  defp maybe_drop_bucket(state, key) do
    bucket = Map.fetch!(state.buckets, key)

    if bucket.total == 0 and bucket.waiters == [] do
      %{state | buckets: Map.delete(state.buckets, key)}
    else
      state
    end
  end

  defp put_bucket(state, key, bucket), do: %{state | buckets: Map.put(state.buckets, key, bucket)}

  defp close_if_owned(%{socket: nil}), do: :ok
  defp close_if_owned(%{socket: socket}), do: close_socket(socket)

  defp close_socket({module, socket}), do: module.close(socket)
end
