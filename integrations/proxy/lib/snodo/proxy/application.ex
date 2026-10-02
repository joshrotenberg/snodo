defmodule Snodo.Proxy.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [{Registry, keys: :unique, name: Snodo.Proxy.Registry}]

    Supervisor.start_link(children,
      strategy: :one_for_one,
      name: Snodo.Proxy.ApplicationSupervisor
    )
  end
end
