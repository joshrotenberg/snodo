defmodule Snodo.Extensions.Tasks.Store.SQLite.WriterQueue do
  @moduledoc false

  # One process per Repo (per dynamic repo, when an application uses
  # `put_dynamic_repo/1`) grants a single write slot to store writers in
  # arrival order. Exqlite waits out SQLite's busy timeout inside a native call
  # that holds the waiting connection's mutex, and finalizing a statement
  # prepared on that connection needs the same mutex. Ecto's query cache hands
  # prepared statements between pooled connections, so a writer holding the
  # database can block a scheduler thread on a waiter's statement until the
  # waiter's busy timeout ends. Store writers that wait here, in a `receive`,
  # hold no Exqlite mutex.
  #
  # The queue monitors the holder and every waiter. A dead holder releases the
  # slot, a dead waiter leaves the queue, and a release hands the slot directly
  # to the next waiter. If a queue process itself exits, a holder keeps running
  # its transaction while the next writer starts a new queue and can be granted
  # the slot, so for that overlap the two meet in SQLite's busy handler.

  use GenServer, restart: :temporary

  @type key :: {module(), atom() | pid()}
  @opaque slot :: {pid(), reference()}

  @doc false
  @spec key(module()) :: key()
  def key(repo), do: {repo, repo.get_dynamic_repo()}

  @doc """
  Waits for the write slot until the monotonic `deadline` in milliseconds.

  When the deadline has already passed, takes the slot only if it is free.
  Returns `{:error, :database_busy}` when the deadline passes, when
  `max_waiters` writers are already waiting, or when the queue stops, and
  `{:error, {:application_not_started, :snodo_tasks_sqlite}}` when the queue
  supervisor is not running.
  """
  @spec acquire(key(), integer(), non_neg_integer()) ::
          {:ok, slot()}
          | {:error, :database_busy | {:application_not_started, :snodo_tasks_sqlite}}
  def acquire(key, deadline, max_waiters) do
    with {:ok, queue} <- ensure_started(key) do
      remaining = deadline - System.monotonic_time(:millisecond)

      # With no waiters allowed, the queue grants a free slot or refuses at
      # once, so that wait needs no timeout.
      if remaining > 0,
        do: wait(queue, remaining, max_waiters),
        else: wait(queue, :infinity, 0)
    end
  end

  @doc "Releases a slot returned by `acquire/3`."
  @spec release(slot()) :: :ok
  def release({queue, ref}) do
    send(queue, {:release, ref})
    Process.demonitor(ref, [:flush])
    :ok
  end

  @doc false
  @spec waiting(key()) :: non_neg_integer()
  def waiting(key) do
    case __MODULE__.Registry.lookup(key) do
      {:ok, queue} -> GenServer.call(queue, :waiting)
      _missing -> 0
    end
  end

  @doc false
  def start_link(key), do: GenServer.start_link(__MODULE__, key)

  defp wait(queue, remaining, max_waiters) do
    ref = Process.monitor(queue)
    send(queue, {:acquire, self(), ref, max_waiters})

    receive do
      {^ref, :granted} ->
        {:ok, {queue, ref}}

      {^ref, :full} ->
        Process.demonitor(ref, [:flush])
        {:error, :database_busy}

      {:DOWN, ^ref, :process, _queue, _reason} ->
        {:error, :database_busy}
    after
      remaining -> cancel(queue, ref)
    end
  end

  defp ensure_started(key) do
    case __MODULE__.Registry.lookup(key) do
      {:ok, queue} -> {:ok, queue}
      :error -> start_queue(key)
      :not_started -> {:error, {:application_not_started, :snodo_tasks_sqlite}}
    end
  end

  # The registry or the queue supervisor may be restarting.
  defp start_queue(key) do
    case __MODULE__.Registry.start_queue(key) do
      {:ok, queue} -> {:ok, queue}
      {:error, _reason} -> {:error, :database_busy}
    end
  catch
    :exit, _reason -> {:error, :database_busy}
  end

  # The holder may have been granted the slot after the deadline passed. The
  # cancel call is ordered after any grant, so the slot is handed on either way
  # and a late grant is flushed from the mailbox.
  defp cancel(queue, ref) do
    try do
      GenServer.call(queue, {:cancel, ref}, :infinity)
    catch
      :exit, _reason -> :ok
    end

    Process.demonitor(ref, [:flush])

    receive do
      {^ref, _reply} -> :ok
    after
      0 -> :ok
    end

    {:error, :database_busy}
  end

  @impl GenServer
  def init({_repo, dynamic_repo}) do
    # A dynamic repo started as an anonymous process has no lasting name, so
    # its queue stops with it.
    _monitor = if is_pid(dynamic_repo), do: Process.monitor(dynamic_repo)
    {:ok, %{holder: nil, waiters: :queue.new(), count: 0, dynamic_repo: dynamic_repo}}
  end

  @impl GenServer
  def handle_call({:cancel, ref}, _from, state), do: {:reply, :ok, release_or_remove(state, ref)}
  def handle_call(:waiting, _from, state), do: {:reply, state.count, state}

  @impl GenServer
  def handle_info({:acquire, pid, ref, max_waiters}, state) do
    cond do
      state.holder == nil ->
        {:noreply, grant(state, {ref, pid, Process.monitor(pid)})}

      state.count >= max_waiters ->
        send(pid, {ref, :full})
        {:noreply, state}

      true ->
        waiter = {ref, pid, Process.monitor(pid)}
        {:noreply, %{state | waiters: :queue.in(waiter, state.waiters), count: state.count + 1}}
    end
  end

  def handle_info({:release, ref}, state), do: {:noreply, release_or_remove(state, ref)}

  def handle_info({:DOWN, _monitor, :process, pid, _reason}, %{dynamic_repo: pid} = state),
    do: {:stop, :normal, state}

  def handle_info({:DOWN, monitor, :process, _pid, _reason}, state) do
    case state.holder do
      {_ref, ^monitor} -> {:noreply, grant_next(%{state | holder: nil})}
      _other -> {:noreply, remove_waiter(state, fn {_ref, _pid, waiter} -> waiter == monitor end)}
    end
  end

  defp release_or_remove(state, ref) do
    case state.holder do
      {^ref, monitor} ->
        Process.demonitor(monitor, [:flush])
        grant_next(%{state | holder: nil})

      _other ->
        remove_waiter(state, fn {waiter, _pid, _monitor} -> waiter == ref end)
    end
  end

  defp remove_waiter(state, match?) do
    {removed, kept} = state.waiters |> :queue.to_list() |> Enum.split_with(match?)
    Enum.each(removed, fn {_ref, _pid, monitor} -> Process.demonitor(monitor, [:flush]) end)
    %{state | waiters: :queue.from_list(kept), count: length(kept)}
  end

  defp grant_next(state) do
    case :queue.out(state.waiters) do
      {{:value, waiter}, waiters} ->
        grant(%{state | waiters: waiters, count: state.count - 1}, waiter)

      {:empty, _waiters} ->
        state
    end
  end

  defp grant(state, {ref, pid, monitor}) do
    send(pid, {ref, :granted})
    %{state | holder: {ref, monitor}}
  end
end
