defmodule MCP.Extensions.Tasks.Store.Postgres.Migration.V2 do
  @moduledoc """
  Data-preserving PostgreSQL upgrade from Tasks schema version one to two.

  Version two adds the event commit-time lookup index used by operational
  ledger scans. Apply this module as its own application migration when
  upgrading an existing version-one installation.
  """

  use Ecto.Migration

  @schema_version 2
  @dialyzer {:nowarn_function, up: 0, up: 1, down: 0, down: 1}

  @spec current_version() :: pos_integer()
  def current_version, do: @schema_version

  @doc "Upgrades a version-one schema without rewriting task or event rows."
  def up(opts \\ []) when is_list(opts) do
    table_prefix = Keyword.get(opts, :prefix, prefix())

    create(
      index(:mcp_task_events, [:committed_at, :task_id],
        prefix: table_prefix,
        name: :mcp_task_events_committed
      )
    )

    flush()

    execute("""
    DO $$
    BEGIN
      UPDATE #{qualified_table(table_prefix, "mcp_task_store_metadata")}
      SET schema_version = #{@schema_version}
      WHERE singleton = TRUE AND schema_version = 1;

      IF NOT FOUND THEN
        RAISE EXCEPTION 'expected mcp_ex Tasks schema version 1';
      END IF;
    END
    $$
    """)
  end

  @doc "Rolls schema version two back to one without deleting task data."
  def down(opts \\ []) when is_list(opts) do
    table_prefix = Keyword.get(opts, :prefix, prefix())

    execute("""
    DO $$
    BEGIN
      UPDATE #{qualified_table(table_prefix, "mcp_task_store_metadata")}
      SET schema_version = 1
      WHERE singleton = TRUE AND schema_version = #{@schema_version};

      IF NOT FOUND THEN
        RAISE EXCEPTION 'expected mcp_ex Tasks schema version #{@schema_version}';
      END IF;
    END
    $$
    """)

    drop(
      index(:mcp_task_events, [:committed_at, :task_id],
        prefix: table_prefix,
        name: :mcp_task_events_committed
      )
    )
  end

  defp qualified_table(nil, table), do: quote_identifier(table)

  defp qualified_table(table_prefix, table) when is_binary(table_prefix) do
    quote_identifier(table_prefix) <> "." <> quote_identifier(table)
  end

  defp quote_identifier(identifier) do
    escaped = String.replace(identifier, "\"", "\"\"")
    "\"" <> escaped <> "\""
  end
end
