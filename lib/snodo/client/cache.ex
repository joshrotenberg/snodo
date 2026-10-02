defmodule Snodo.Client.Cache do
  @moduledoc false

  use GenServer

  @max_entries 256
  @max_bytes 16 * 1024 * 1024

  @doc false
  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @doc false
  def lookup_public(base), do: GenServer.call(__MODULE__, {:lookup, {:public, base}})

  @doc false
  def lookup_private(base, credential),
    do: GenServer.call(__MODULE__, {:lookup, {:private, base, credential}})

  @doc false
  def put(base, credential, generation, result) do
    case {Map.get(result, "ttlMs"), Map.get(result, "cacheScope")} do
      {ttl, "private"} when is_integer(ttl) and ttl > 0 and is_nil(credential) ->
        :ok

      {ttl, scope} when is_integer(ttl) and ttl > 0 and scope in ["public", "private"] ->
        key = if scope == "public", do: {:public, base}, else: {:private, base, credential}
        GenServer.call(__MODULE__, {:put, key, generation, ttl, result})

      _uncacheable ->
        :ok
    end
  end

  @doc false
  def invalidate(nil, _method, _params), do: :ok

  def invalidate(namespace, method, params),
    do: GenServer.call(__MODULE__, {:invalidate, namespace, method, params})

  @impl true
  def init(:ok), do: {:ok, %{entries: %{}, bytes: 0, clock: 0, generation: 0}}

  @impl true
  def handle_call({:lookup, key}, _from, state) do
    current_time = now()

    case Map.fetch(state.entries, key) do
      {:ok, %{expires: expires} = entry} when expires > current_time ->
        clock = state.clock + 1
        entry = %{entry | used: clock}
        state = %{state | entries: Map.put(state.entries, key, entry), clock: clock}
        {:reply, {:hit, entry.result}, state}

      {:ok, _expired} ->
        {:reply, {:miss, state.generation}, delete(state, key)}

      :error ->
        {:reply, {:miss, state.generation}, state}
    end
  end

  def handle_call({:put, key, generation, ttl, result}, _from, state) do
    size = :erlang.external_size({key, result})

    state =
      if generation == state.generation and size <= @max_bytes do
        state = delete(state, key)
        clock = state.clock + 1
        entry = %{result: result, expires: now() + ttl, size: size, used: clock}

        %{
          state
          | entries: Map.put(state.entries, key, entry),
            bytes: state.bytes + size,
            clock: clock
        }
        |> evict()
      else
        state
      end

    {:reply, :ok, state}
  end

  def handle_call({:invalidate, namespace, method, params}, _from, state) do
    case invalidated_method(method, params) do
      nil ->
        {:reply, :ok, state}

      affected ->
        state = %{state | generation: state.generation + 1}
        {:reply, :ok, drop_affected(state, namespace, affected)}
    end
  end

  defp drop_affected(state, namespace, affected) do
    Enum.reduce(Map.keys(state.entries), state, fn key, state ->
      if key_namespace(key) == namespace and affected?(key, affected),
        do: delete(state, key),
        else: state
    end)
  end

  defp now, do: System.monotonic_time(:millisecond)

  defp key_namespace(
         {:public, {namespace, _version, _variant, _capabilities, _info, _method, _params}}
       ),
       do: namespace

  defp key_namespace({:private, base, _credential}), do: key_namespace({:public, base})

  defp affected?({:private, base, _credential}, affected),
    do: affected?({:public, base}, affected)

  defp affected?(
         {:public, {_namespace, _version, _variant, _capabilities, _info, method, params}},
         {:resource, uri}
       ),
       do: method == "resources/read" and Map.get(params, "uri") == uri

  defp affected?(
         {:public, {_namespace, _version, _variant, _capabilities, _info, method, _params}},
         methods
       ),
       do: method in methods

  defp invalidated_method("notifications/tools/list_changed", _params), do: ["tools/list"]
  defp invalidated_method("notifications/prompts/list_changed", _params), do: ["prompts/list"]

  defp invalidated_method("notifications/resources/list_changed", _params),
    do: ["resources/list", "resources/templates/list"]

  defp invalidated_method("notifications/resources/updated", %{"uri" => uri})
       when is_binary(uri),
       do: {:resource, uri}

  defp invalidated_method(_method, _params), do: nil

  defp delete(state, key) do
    case Map.pop(state.entries, key) do
      {nil, _entries} -> state
      {%{size: size}, entries} -> %{state | entries: entries, bytes: state.bytes - size}
    end
  end

  defp evict(state) when map_size(state.entries) <= @max_entries and state.bytes <= @max_bytes,
    do: state

  defp evict(state) do
    {oldest, _entry} = Enum.min_by(state.entries, fn {_key, entry} -> entry.used end)
    state |> delete(oldest) |> evict()
  end
end
