defmodule Snodo.Proxy.RequestLock do
  @moduledoc false

  use GenServer, restart: :temporary

  alias Snodo.Error

  @queue_timeout 30_000

  @doc false
  def start_link(connection) do
    GenServer.start_link(__MODULE__, connection, name: name(connection))
  end

  @doc false
  def run(connection, fun, timeout \\ @queue_timeout) do
    lock = name(connection)

    case acquire(lock, timeout) do
      {:ok, ref} ->
        try do
          fun.()
        after
          release(lock, ref)
        end

      {:error, error} ->
        {:error, error}
    end
  end

  defp name(connection), do: {:via, Registry, {Snodo.Proxy.Registry, {__MODULE__, connection}}}

  defp acquire(lock, timeout) do
    GenServer.call(lock, {:acquire, timeout}, :infinity)
  catch
    :exit, _reason -> {:error, error("backend_unavailable")}
  end

  defp release(lock, ref) do
    GenServer.call(lock, {:release, ref})
  catch
    :exit, _reason -> :ok
  end

  @impl true
  def init(connection) do
    {:ok,
     %{
       connection: Process.monitor(connection),
       holder: nil,
       queue: :queue.new(),
       waiters: %{}
     }}
  end

  @impl true
  def handle_call({:acquire, _timeout}, {pid, _tag}, %{holder: nil} = state) do
    ref = Process.monitor(pid)
    {:reply, {:ok, ref}, %{state | holder: ref}}
  end

  def handle_call({:acquire, timeout}, {pid, _tag} = from, state) do
    ref = Process.monitor(pid)
    timer = Process.send_after(self(), {:expire, ref}, timeout)
    deadline = System.monotonic_time(:millisecond) + timeout
    waiter = {from, timer, deadline}

    {:noreply,
     %{state | queue: :queue.in(ref, state.queue), waiters: Map.put(state.waiters, ref, waiter)}}
  end

  def handle_call({:release, ref}, _from, %{holder: ref} = state) do
    Process.demonitor(ref, [:flush])
    {:reply, :ok, grant_next(%{state | holder: nil})}
  end

  def handle_call({:release, _ref}, _from, state), do: {:reply, :ok, state}

  @impl true
  def handle_info({:expire, ref}, state) do
    {:noreply, remove_waiter(state, ref, true)}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{connection: ref} = state) do
    {:stop, :normal, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{holder: ref} = state) do
    {:noreply, grant_next(%{state | holder: nil})}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    {:noreply, remove_waiter(state, ref, false)}
  end

  # Remove expired or dead callers from both structures, even while a holder
  # runs indefinitely. This keeps abandoned entries from accumulating.
  defp remove_waiter(state, ref, reply?) do
    case Map.pop(state.waiters, ref) do
      {nil, _waiters} ->
        state

      {{from, timer, _deadline}, waiters} ->
        _ = Process.cancel_timer(timer)
        Process.demonitor(ref, [:flush])
        if reply?, do: GenServer.reply(from, {:error, error("stdio_queue_timeout")})
        %{state | waiters: waiters, queue: :queue.delete(ref, state.queue)}
    end
  end

  defp grant_next(state) do
    case :queue.out(state.queue) do
      {:empty, _queue} ->
        state

      {{:value, ref}, queue} ->
        {from, timer, deadline} = Map.fetch!(state.waiters, ref)
        _ = Process.cancel_timer(timer)

        if System.monotonic_time(:millisecond) >= deadline do
          state |> remove_waiter(ref, true) |> grant_next()
        else
          GenServer.reply(from, {:ok, ref})
          %{state | holder: ref, queue: queue, waiters: Map.delete(state.waiters, ref)}
        end
    end
  end

  defp error(reason) do
    %{Error.internal("Stdio backend request unavailable") | data: %{"reason" => reason}}
  end
end
