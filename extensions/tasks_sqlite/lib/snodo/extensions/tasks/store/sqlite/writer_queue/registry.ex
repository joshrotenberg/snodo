defmodule Snodo.Extensions.Tasks.Store.SQLite.WriterQueue.Registry do
  @moduledoc false

  # Maps a writer queue key to its process. Lookups read a public ETS table
  # owned by this process; starts go through it, so one key never gets two
  # queues. Elixir's Registry is not used because a brutally killed Registry
  # cannot be restarted while its partition is still exiting, which takes the
  # whole supervision tree down.

  use GenServer

  alias Snodo.Extensions.Tasks.Store.SQLite.WriterQueue

  @table __MODULE__

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @spec lookup(WriterQueue.key()) :: {:ok, pid()} | :error | :not_started
  def lookup(key) do
    case :ets.lookup(@table, key) do
      [{^key, queue}] -> {:ok, queue}
      [] -> :error
    end
  rescue
    ArgumentError -> :not_started
  end

  @spec start_queue(WriterQueue.key()) :: {:ok, pid()} | {:error, term()}
  def start_queue(key), do: GenServer.call(__MODULE__, {:start_queue, key})

  @impl GenServer
  def init(:ok) do
    _table = :ets.new(@table, [:named_table, :protected, read_concurrency: true])
    {:ok, %{}}
  end

  @impl GenServer
  def handle_call({:start_queue, key}, _from, monitors) do
    case :ets.lookup(@table, key) do
      [{^key, queue}] ->
        {:reply, {:ok, queue}, monitors}

      [] ->
        case DynamicSupervisor.start_child(WriterQueue.Supervisor, {WriterQueue, key}) do
          {:ok, queue} ->
            true = :ets.insert(@table, {key, queue})
            {:reply, {:ok, queue}, Map.put(monitors, Process.monitor(queue), key)}

          {:error, reason} ->
            {:reply, {:error, reason}, monitors}
        end
    end
  end

  @impl GenServer
  def handle_info({:DOWN, monitor, :process, _queue, _reason}, monitors) do
    {key, monitors} = Map.pop(monitors, monitor)
    true = :ets.delete(@table, key)
    {:noreply, monitors}
  end
end
