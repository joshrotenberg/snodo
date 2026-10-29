defmodule Snodo.Session.Registry do
  @moduledoc """
  Behaviour for finding an initialize-era session process by its ID.

  `Snodo.Session.Manager` uses a registry to map each `Mcp-Session-Id` to the
  process that holds the session. The default, `Snodo.Session.Registry.Local`,
  keeps that map on the local node. A session process always runs on the node
  that handled `initialize`; a registry decides only how a request finds it.
  The core performs no cross-node routing, so a deployment with several nodes
  needs sticky load balancing that sends every request for a session to the
  node that created it, whatever registry it uses.

  Configure a registry with the manager's `:registry` option as a module or
  `{module, options}`. `options` is passed back unchanged to every callback.

  `child_spec/1` returns the process the registry needs, started under the
  manager before any session, or `nil` when it needs none. `register/3` runs in
  the session process that is registering itself. `unregister/2` runs in that
  process as it stops; a registry should also remove an entry when its process
  exits, since a killed session process cannot unregister.
  """

  @type options :: term()
  @type id :: String.t()

  @callback child_spec(options()) :: Supervisor.child_spec() | Supervisor.module_spec() | nil
  @callback register(options(), id(), pid()) :: :ok | {:error, :taken}
  @callback lookup(options(), id()) :: {:ok, pid()} | :error
  @callback unregister(options(), id()) :: :ok

  @doc false
  @spec normalize!(module() | {module(), options()}) :: {module(), options()}
  def normalize!({module, options}) when is_atom(module), do: validate!(module, options)
  def normalize!(module) when is_atom(module), do: validate!(module, [])

  def normalize!(_invalid),
    do: raise(ArgumentError, ":registry must be a module or {module, options}")

  defp validate!(module, options) do
    exported? =
      Code.ensure_loaded?(module) and
        Enum.all?([child_spec: 1, register: 3, lookup: 2, unregister: 2], fn {name, arity} ->
          function_exported?(module, name, arity)
        end)

    if exported?,
      do: {module, options},
      else:
        raise(
          ArgumentError,
          ":registry #{inspect(module)} must export child_spec/1, register/3, lookup/2, " <>
            "and unregister/2"
        )
  end
end
