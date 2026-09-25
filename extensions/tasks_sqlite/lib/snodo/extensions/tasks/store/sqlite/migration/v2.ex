defmodule Snodo.Extensions.Tasks.Store.SQLite.Migration.V2 do
  @moduledoc """
  Data-preserving SQLite upgrade from Tasks schema version one to two.

  Version two adds the event commit-time lookup index used by operational
  ledger scans. Apply this module as its own application migration when
  upgrading an existing version-one installation.
  """

  use Ecto.Migration

  @schema_version 2
  @dialyzer {:nowarn_function, up: 0, down: 0}

  @spec current_version() :: pos_integer()
  def current_version, do: @schema_version

  @doc "Upgrades a version-one schema without rewriting task or event rows."
  def up do
    create(
      index(:mcp_task_events, [:committed_at_us, :task_id], name: :mcp_task_events_committed)
    )

    flush()

    execute("""
    UPDATE mcp_task_store_metadata
    SET schema_version = #{@schema_version}
    WHERE singleton = 1 AND schema_version = 1
    """)

    assert_version!(@schema_version)
  end

  @doc "Rolls schema version two back to one without deleting task data."
  def down do
    execute("""
    UPDATE mcp_task_store_metadata
    SET schema_version = 1
    WHERE singleton = 1 AND schema_version = #{@schema_version}
    """)

    assert_version!(1)

    drop(index(:mcp_task_events, [:committed_at_us, :task_id], name: :mcp_task_events_committed))
  end

  defp assert_version!(version) do
    execute("""
    INSERT INTO mcp_task_store_metadata (singleton, schema_version)
    SELECT 0, 0
    WHERE NOT EXISTS (
      SELECT 1 FROM mcp_task_store_metadata
      WHERE singleton = 1 AND schema_version = #{version}
    )
    """)
  end
end
