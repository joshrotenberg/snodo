defmodule Snodo.Extensions.Tasks.Store.SQLite.Application do
  @moduledoc false

  use Application

  @impl Application
  def start(_type, _args) do
    Supervisor.start_link([Snodo.Extensions.Tasks.Store.SQLite.Supervisor],
      strategy: :one_for_one,
      name: Snodo.Extensions.Tasks.Store.SQLite.Application.Supervisor
    )
  end
end
