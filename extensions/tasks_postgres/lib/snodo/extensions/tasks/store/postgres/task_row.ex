defmodule Snodo.Extensions.Tasks.Store.Postgres.TaskRow do
  @moduledoc false

  use Ecto.Schema

  @type t :: %__MODULE__{}

  @primary_key false
  schema "mcp_tasks" do
    field :task_id, :string, primary_key: true
    field :row_format, :integer
    field :snapshot_format, :integer
    field :snapshot, :map
    field :authorization_scope, :map
    field :revision, :integer
    field :status, :string
    field :created_at, :utc_datetime_usec
    field :expires_at, :utc_datetime_usec
    field :retry_at, :utc_datetime_usec
    field :claim_owner, :string
    field :claim_token, Ecto.UUID
    field :lease_generation, :integer
    field :claim_expires_at, :utc_datetime_usec
    field :inserted_at, :utc_datetime_usec
    field :updated_at, :utc_datetime_usec
  end
end
