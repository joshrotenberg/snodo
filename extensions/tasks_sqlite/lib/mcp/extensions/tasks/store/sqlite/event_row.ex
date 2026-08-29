defmodule MCP.Extensions.Tasks.Store.SQLite.EventRow do
  @moduledoc false

  use Ecto.Schema

  @type t :: %__MODULE__{}

  @primary_key false
  schema "mcp_task_events" do
    field :task_id, :string, primary_key: true
    field :event_id, :string, primary_key: true
    field :row_format, :integer
    field :event, :string
    field :event_kind, :string
    field :event_revision, :integer
    field :committed_at_us, :integer
    field :effects, :string
  end
end
