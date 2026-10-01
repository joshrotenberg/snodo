defmodule Snodo.Extensions.Tasks.Store.SQLite.Supervisor do
  @moduledoc """
  Supervises the per-Repo writer queues that SQLite store mutations take their
  write slot from.

  The `:snodo_tasks_sqlite` application starts this supervisor, so nothing is
  needed when the application runs. An application that lists
  `:snodo_tasks_sqlite` under `:included_applications`, or starts the VM
  without starting applications, must start it itself, once per node:

      children = [
        Snodo.Extensions.Tasks.Store.SQLite.Supervisor,
        MyApp.Repo
      ]

  Without it, every store mutation returns
  `{:error, {:application_not_started, :snodo_tasks_sqlite}}`.
  """

  use Supervisor

  alias Snodo.Extensions.Tasks.Store.SQLite.WriterQueue

  @doc "Starts the writer-queue supervisor. It registers fixed local names."
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl Supervisor
  def init(_opts) do
    children = [
      WriterQueue.Registry,
      {DynamicSupervisor, name: WriterQueue.Supervisor, strategy: :one_for_one}
    ]

    # The registry's table names the queues, so when it restarts the queues
    # restart with it.
    Supervisor.init(children, strategy: :rest_for_one)
  end
end
