defmodule MCP.Extensions.Tasks.Store.SQLite.TaskRow do
  @moduledoc false

  use Ecto.Schema

  @type t :: %__MODULE__{}

  @primary_key false
  schema "mcp_tasks" do
    field :task_id, :string, primary_key: true
    field :row_format, :integer
    field :snapshot_format, :integer
    field :snapshot, :string
    field :authorization_scope, :string
    field :revision, :integer
    field :status, :string
    field :created_at_us, :integer
    field :expires_at_us, :integer
    field :retry_at_us, :integer
    field :claim_owner, :string
    field :claim_token, :string
    field :lease_generation, :integer
    field :claim_expires_at_us, :integer
  end
end
