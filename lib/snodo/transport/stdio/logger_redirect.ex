defmodule Snodo.Transport.Stdio.LoggerRedirect do
  @moduledoc false

  use GenServer

  def start_link(_opts) do
    case GenServer.start_link(__MODULE__, :ok, name: __MODULE__) do
      {:error, {:already_started, _pid}} -> :ignore
      result -> result
    end
  end

  def acquire do
    case GenServer.call(coordinator(), :acquire, :infinity) do
      {:ok, pid} ->
        pid

      :unchanged ->
        nil

      {:error, reason} ->
        raise "could not redirect the default Logger handler: #{inspect(reason)}"
    end
  end

  def release(nil), do: :ok

  def release(coordinator) do
    GenServer.call(coordinator, :release, :infinity)
  catch
    :exit, _reason -> :ok
  end

  defp coordinator do
    Process.whereis(__MODULE__) || start_standalone()
  end

  # Standalone scripts can serve with only the compiled modules on the code path.
  # Their coordinator is unsupervised and lives until the VM exits.
  defp start_standalone do
    case GenServer.start(__MODULE__, :ok, name: __MODULE__) do
      {:ok, pid} -> pid
      {:error, {:already_started, pid}} -> pid
    end
  end

  @impl true
  def init(:ok) do
    Process.flag(:trap_exit, true)
    {:ok, %{owners: %{}, redirect: nil}}
  end

  @impl true
  def handle_call(:acquire, {pid, _tag}, state) do
    case state.redirect || redirect() do
      {:redirected, original, installed} ->
        owners = Map.put_new_lazy(state.owners, pid, fn -> Process.monitor(pid) end)
        {:reply, {:ok, self()}, %{owners: owners, redirect: {:redirected, original, installed}}}

      result ->
        {:reply, result, state}
    end
  end

  def handle_call(:release, {pid, _tag}, state) do
    {:reply, :ok, release_owner(state, pid)}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
    case state.owners do
      %{^pid => ^ref} -> {:noreply, release_owner(state, pid)}
      _owners -> {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state), do: restore(state.redirect)

  defp release_owner(state, pid) do
    {ref, owners} = Map.pop!(state.owners, pid)
    Process.demonitor(ref, [:flush])

    if map_size(owners) == 0 do
      _result = restore(state.redirect)
      %{owners: owners, redirect: nil}
    else
      %{state | owners: owners}
    end
  end

  defp redirect do
    case :logger.get_handler_config(:default) do
      {:ok, %{module: :logger_std_h, config: %{type: :standard_io}} = original} ->
        with :ok <- :logger.remove_handler(:default), do: install_redirect(original)

      _other ->
        :unchanged
    end
  end

  defp install_redirect(original) do
    # The saved config already includes the handler defaults.
    replacement = put_in(original, [:config, :type], :standard_error)

    case add_handler(replacement) do
      :ok ->
        {:redirected, original, replacement}

      {:error, _reason} = error ->
        _result = add_handler(original)
        error
    end
  end

  defp restore(nil), do: :ok

  defp restore({:redirected, original, installed}) do
    case :logger.get_handler_config(:default) do
      {:ok, ^installed} ->
        with :ok <- :logger.remove_handler(:default), do: add_handler(original)

      _other ->
        :ok
    end
  end

  defp add_handler(%{id: id, module: module} = handler) do
    :logger.add_handler(id, module, Map.drop(handler, [:id, :module]))
  end
end
