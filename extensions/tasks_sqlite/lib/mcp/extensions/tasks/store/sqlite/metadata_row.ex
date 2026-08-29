defmodule MCP.Extensions.Tasks.Store.SQLite.MetadataRow do
  @moduledoc false

  use Ecto.Schema

  @primary_key false
  schema "mcp_task_store_metadata" do
    field :singleton, :integer, primary_key: true
    field :schema_version, :integer
  end
end
