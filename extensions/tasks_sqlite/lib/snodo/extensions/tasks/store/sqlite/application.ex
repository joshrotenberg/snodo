defmodule Snodo.Extensions.Tasks.Store.SQLite.Application do
  @moduledoc false

  use Application

  alias Snodo.Extensions.Tasks.Store.SQLite.WriterQueue

  @impl Application
  def start(_type, _args) do
    children = [
      {Registry, keys: :unique, name: WriterQueue.Registry},
      {DynamicSupervisor, name: WriterQueue.Supervisor, strategy: :one_for_one}
    ]

    # A writer queue registers itself in the Registry, so the queues restart
    # with it.
    Supervisor.start_link(children,
      strategy: :rest_for_one,
      name: Snodo.Extensions.Tasks.Store.SQLite.Supervisor
    )
  end
end
