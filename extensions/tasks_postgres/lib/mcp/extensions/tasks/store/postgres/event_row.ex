defmodule MCP.Extensions.Tasks.Store.Postgres.EventRow do
  @moduledoc false

  use Ecto.Schema

  @type t :: %__MODULE__{}

  @primary_key false
  schema "mcp_task_events" do
    field :task_id, :string, primary_key: true
    field :event_id, :string, primary_key: true
    field :row_format, :integer
    field :event, :map
    field :event_kind, :string
    field :event_revision, :integer
    field :committed_at, :utc_datetime_usec
    field :effects, :map
  end
end
