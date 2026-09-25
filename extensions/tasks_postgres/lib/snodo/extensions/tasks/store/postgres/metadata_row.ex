defmodule Snodo.Extensions.Tasks.Store.Postgres.MetadataRow do
  @moduledoc false

  use Ecto.Schema

  @primary_key false
  schema "mcp_task_store_metadata" do
    field :singleton, :boolean, primary_key: true
    field :schema_version, :integer
    field :installed_at, :utc_datetime_usec
  end
end
