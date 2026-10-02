defmodule Snodo.Proxy.Supervisor do
  @moduledoc false

  use Supervisor

  @doc false
  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))
  end

  @doc false
  def child(proxy, id) do
    proxy
    |> Supervisor.which_children()
    |> Enum.find_value(fn
      {^id, pid, _type, _modules} -> pid
      _other -> nil
    end)
  end

  @doc false
  def ref(proxy, kind), do: via(proxy, kind)

  @impl true
  def init(opts) do
    key = self()
    hub = via(key, :hub)
    backend_supervisor = via(key, :backends)

    children = [
      {Snodo.Subscription.Hub, name: hub},
      {DynamicSupervisor, strategy: :one_for_one, name: backend_supervisor},
      {Snodo.Proxy.Manager,
       [
         backends: Keyword.get(opts, :backends, []),
         name: via(key, :manager),
         proxy: key,
         backend_supervisor: backend_supervisor,
         hub: hub,
         health_interval_ms: Keyword.get(opts, :health_interval_ms, 30_000),
         max_backends: Keyword.get(opts, :max_backends, 32),
         max_catalog_items: Keyword.get(opts, :max_catalog_items, 1_000)
       ]}
    ]

    Supervisor.init(children, strategy: :one_for_all)
  end

  defp via(key, kind), do: {:via, Registry, {Snodo.Proxy.Registry, {key, kind}}}
end
