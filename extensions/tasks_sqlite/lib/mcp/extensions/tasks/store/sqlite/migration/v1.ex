defmodule MCP.Extensions.Tasks.Store.SQLite.Migration.V1 do
  @moduledoc """
  Immutable SQLite schema-version-one migration.

  New installations should use `MCP.Extensions.Tasks.Store.SQLite.Migration`.
  This module remains available so applications and fixtures can identify and
  reproduce the historical version-one boundary before applying `V2`.
  """

  use Ecto.Migration

  alias MCP.Extensions.Tasks.Store.SQLite.Migration

  @schema_version 1
  @dialyzer {:nowarn_function, up: 0, down: 0}

  @spec current_version() :: pos_integer()
  def current_version, do: @schema_version

  @doc "Creates exactly the historical version-one schema."
  def up, do: Migration.up_v1()

  @doc "Drops exactly the historical version-one schema."
  def down, do: Migration.down_v1()
end
