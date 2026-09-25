defmodule Snodo.Extensions.Tasks.Store.Postgres.Migration.V1 do
  @moduledoc """
  Immutable PostgreSQL schema-version-one migration.

  New installations should use `Snodo.Extensions.Tasks.Store.Postgres.Migration`.
  This module remains available so applications and fixtures can identify and
  reproduce the historical version-one boundary before applying `V2`.
  """

  use Ecto.Migration

  alias Snodo.Extensions.Tasks.Store.Postgres.Migration

  @schema_version 1
  @dialyzer {:nowarn_function, up: 0, up: 1, down: 0, down: 1}

  @spec current_version() :: pos_integer()
  def current_version, do: @schema_version

  @doc "Creates exactly the historical version-one schema."
  def up(opts \\ []) when is_list(opts), do: Migration.up_v1(opts)

  @doc "Drops exactly the historical version-one schema."
  def down(opts \\ []) when is_list(opts), do: Migration.down_v1(opts)
end
