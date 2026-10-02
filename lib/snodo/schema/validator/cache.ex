defmodule Snodo.Schema.Validator.Cache do
  @moduledoc false

  use GenServer

  @table __MODULE__
  @max_entries 256

  @doc false
  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @doc false
  def fetch(key, compile) when is_function(compile, 0) do
    if :ets.whereis(@table) == :undefined do
      compile.()
    else
      result =
        case :ets.lookup(@table, key) do
          [{^key, value}] -> value
          [] -> GenServer.call(__MODULE__, {:fetch, key, compile}, :infinity)
        end

      case result do
        {:cache_compile_raised, kind, reason, stacktrace} ->
          :erlang.raise(kind, reason, stacktrace)

        value ->
          value
      end
    end
  end

  @impl true
  def init(:ok) do
    _table = :ets.new(@table, [:named_table, :protected, read_concurrency: true])
    {:ok, %{entries: :queue.new(), size: 0, in_flight: %{}, refs: %{}}}
  end

  @impl true
  def handle_call({:fetch, key, compile}, from, state) do
    case :ets.lookup(@table, key) do
      [{^key, value}] ->
        {:reply, value, state}

      [] ->
        start_or_join_compile(key, compile, from, state)
    end
  end

  defp start_or_join_compile(key, compile, from, state) do
    case Map.fetch(state.in_flight, key) do
      {:ok, waiters} ->
        {:noreply, put_in(state, [:in_flight, key], [from | waiters])}

      :error ->
        task = Task.Supervisor.async_nolink(__MODULE__.Tasks, fn -> compile_safely(compile) end)

        {:noreply,
         %{
           state
           | in_flight: Map.put(state.in_flight, key, [from]),
             refs: Map.put(state.refs, task.ref, key)
         }}
    end
  end

  @impl true
  def handle_info({ref, result}, state) when is_reference(ref) do
    case Map.pop(state.refs, ref) do
      {nil, _refs} ->
        {:noreply, state}

      {key, refs} ->
        Process.demonitor(ref, [:flush])
        {waiters, in_flight} = Map.pop!(state.in_flight, key)

        case result do
          {:ok, value} ->
            state = evict_if_full(state)
            true = :ets.insert(@table, {key, value})
            Enum.each(waiters, &GenServer.reply(&1, value))

            {:noreply,
             %{
               state
               | entries: :queue.in(key, state.entries),
                 size: state.size + 1,
                 in_flight: in_flight,
                 refs: refs
             }}

          {:raised, kind, reason, stacktrace} ->
            Enum.each(
              waiters,
              &GenServer.reply(&1, {:cache_compile_raised, kind, reason, stacktrace})
            )

            {:noreply, %{state | in_flight: in_flight, refs: refs}}
        end
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case Map.pop(state.refs, ref) do
      {nil, _refs} ->
        {:noreply, state}

      {key, refs} ->
        {waiters, in_flight} = Map.pop!(state.in_flight, key)
        Enum.each(waiters, &GenServer.reply(&1, {:cache_compile_raised, :exit, reason, []}))
        {:noreply, %{state | in_flight: in_flight, refs: refs}}
    end
  end

  defp compile_safely(compile) do
    {:ok, compile.()}
  catch
    kind, reason -> {:raised, kind, reason, __STACKTRACE__}
  end

  defp evict_if_full(%{size: @max_entries} = state) do
    {{:value, oldest}, entries} = :queue.out(state.entries)
    true = :ets.delete(@table, oldest)
    %{state | entries: entries, size: state.size - 1}
  end

  defp evict_if_full(state), do: state
end
