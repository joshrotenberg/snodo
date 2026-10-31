defmodule Snodo.Session.Registry.Local do
  @moduledoc """
  The default `Snodo.Session.Registry`: an Elixir `Registry` on the local node.

  Its options are the name of the `Registry`, which `Snodo.Session.Manager`
  chooses. Entries are removed when a session process exits.
  """

  @behaviour Snodo.Session.Registry

  @impl true
  def child_spec(name), do: {Registry, keys: :unique, name: name}

  @impl true
  def register(name, id, pid) when pid == self() do
    case Registry.register(name, id, nil) do
      {:ok, _owner} -> :ok
      {:error, {:already_registered, _pid}} -> {:error, :taken}
    end
  end

  @impl true
  def lookup(name, id) do
    case Registry.lookup(name, id) do
      [{pid, _value}] -> {:ok, pid}
      [] -> :error
    end
  end

  @impl true
  def unregister(name, id) do
    Registry.unregister(name, id)
  end
end
