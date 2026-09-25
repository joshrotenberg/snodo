defmodule Snodo.Extensions.Tasks.Store.Postgres.Migration do
  @moduledoc """
  Current PostgreSQL migration for `Snodo.Extensions.Tasks.Store.Postgres`.

  A fresh install composes every schema step through version two. Existing
  version-one installations should run `Migration.V2` as a separate
  application-owned migration. The adapter never runs either path itself, so
  the application retains control of deployment order, credentials, and
  rollback policy.
  """

  use Ecto.Migration

  alias Snodo.Extensions.Tasks.Store.Postgres.Migration.V2

  @initial_schema_version 1
  @schema_version 2
  @dialyzer {:nowarn_function,
             up: 0, up: 1, down: 0, down: 1, up_v1: 0, up_v1: 1, down_v1: 0, down_v1: 1}

  @spec current_version() :: pos_integer()
  def current_version, do: @schema_version

  @doc "Creates the current Tasks schema from an empty database."
  def up(opts \\ []) when is_list(opts) do
    up_v1(opts)
    flush()
    V2.up(opts)
  end

  @doc false
  def up_v1(opts \\ []) when is_list(opts) do
    table_prefix = Keyword.get(opts, :prefix, prefix())

    create table(:mcp_task_store_metadata, primary_key: false, prefix: table_prefix) do
      add(:singleton, :boolean, primary_key: true)
      add(:schema_version, :smallint, null: false)

      add(:installed_at, :timestamptz,
        null: false,
        default: fragment("clock_timestamp()")
      )
    end

    create(
      constraint(:mcp_task_store_metadata, :mcp_task_store_metadata_singleton,
        prefix: table_prefix,
        check: "singleton"
      )
    )

    create(
      constraint(:mcp_task_store_metadata, :mcp_task_store_metadata_version,
        prefix: table_prefix,
        check: "schema_version > 0"
      )
    )

    create table(:mcp_tasks, primary_key: false, prefix: table_prefix) do
      add(:task_id, :text, primary_key: true)
      add(:row_format, :smallint, null: false, default: 1)
      add(:snapshot_format, :smallint, null: false)
      add(:snapshot, :map, null: false)
      add(:authorization_scope, :map, null: false)
      add(:revision, :bigint, null: false)
      add(:status, :text, null: false)
      add(:created_at, :timestamptz, null: false)
      add(:expires_at, :timestamptz)
      add(:retry_at, :timestamptz)
      add(:claim_owner, :text)
      add(:claim_token, :uuid)
      add(:lease_generation, :bigint, null: false, default: 0)
      add(:claim_expires_at, :timestamptz)

      add(:inserted_at, :timestamptz,
        null: false,
        default: fragment("clock_timestamp()")
      )

      add(:updated_at, :timestamptz,
        null: false,
        default: fragment("clock_timestamp()")
      )
    end

    create(
      constraint(:mcp_tasks, :mcp_tasks_task_id_nonempty,
        prefix: table_prefix,
        check: "task_id <> ''"
      )
    )

    create(
      constraint(:mcp_tasks, :mcp_tasks_row_format,
        prefix: table_prefix,
        check: "row_format = 1"
      )
    )

    create(
      constraint(:mcp_tasks, :mcp_tasks_snapshot_format,
        prefix: table_prefix,
        check: "snapshot_format > 0"
      )
    )

    create(
      constraint(:mcp_tasks, :mcp_tasks_snapshot_object,
        prefix: table_prefix,
        check: "jsonb_typeof(snapshot) = 'object'"
      )
    )

    create(
      constraint(:mcp_tasks, :mcp_tasks_scope_object,
        prefix: table_prefix,
        check: "jsonb_typeof(authorization_scope) = 'object'"
      )
    )

    create(
      constraint(:mcp_tasks, :mcp_tasks_revision,
        prefix: table_prefix,
        check: "revision >= 0"
      )
    )

    create(
      constraint(:mcp_tasks, :mcp_tasks_status,
        prefix: table_prefix,
        check: "status IN ('working', 'input_required', 'completed', 'failed', 'cancelled')"
      )
    )

    create(
      constraint(:mcp_tasks, :mcp_tasks_expiry,
        prefix: table_prefix,
        check: "expires_at IS NULL OR expires_at >= created_at"
      )
    )

    create(
      constraint(:mcp_tasks, :mcp_tasks_generation,
        prefix: table_prefix,
        check: "lease_generation >= 0"
      )
    )

    create(
      constraint(:mcp_tasks, :mcp_tasks_claim_shape,
        prefix: table_prefix,
        check: """
        (claim_owner IS NULL AND claim_token IS NULL AND claim_expires_at IS NULL)
        OR
        (claim_owner IS NOT NULL AND claim_owner <> '' AND
         claim_token IS NOT NULL AND claim_expires_at IS NOT NULL AND
         lease_generation > 0)
        """
      )
    )

    create(
      index(:mcp_tasks, [:claim_expires_at, :created_at, :task_id],
        prefix: table_prefix,
        name: :mcp_tasks_recovery_queue,
        where: "status IN ('working', 'input_required')"
      )
    )

    create(
      index(:mcp_tasks, [:retry_at, :created_at, :task_id],
        prefix: table_prefix,
        name: :mcp_tasks_retry_queue,
        where: "status IN ('working', 'input_required') AND retry_at IS NOT NULL"
      )
    )

    create(
      index(:mcp_tasks, [:expires_at, :task_id],
        prefix: table_prefix,
        name: :mcp_tasks_ttl,
        where: "expires_at IS NOT NULL"
      )
    )

    create table(:mcp_task_events, primary_key: false, prefix: table_prefix) do
      add(
        :task_id,
        references(:mcp_tasks,
          column: :task_id,
          type: :text,
          on_delete: :delete_all
        ),
        primary_key: true,
        null: false
      )

      add(:event_id, :text, primary_key: true)
      add(:row_format, :smallint, null: false, default: 1)
      add(:event, :map, null: false)
      add(:event_kind, :text, null: false)
      add(:event_revision, :bigint, null: false)
      add(:committed_at, :timestamptz, null: false)
      add(:effects, :map, null: false)
    end

    create(
      constraint(:mcp_task_events, :mcp_task_events_event_id_nonempty,
        prefix: table_prefix,
        check: "event_id <> ''"
      )
    )

    create(
      constraint(:mcp_task_events, :mcp_task_events_row_format,
        prefix: table_prefix,
        check: "row_format = 1"
      )
    )

    create(
      constraint(:mcp_task_events, :mcp_task_events_event_object,
        prefix: table_prefix,
        check: "jsonb_typeof(event) = 'object'"
      )
    )

    create(
      constraint(:mcp_task_events, :mcp_task_events_event_kind,
        prefix: table_prefix,
        check: """
        event_kind IN (
          'input_requested',
          'input_responses_accepted',
          'retry_requested',
          'completed',
          'failed',
          'cancelled'
        )
        """
      )
    )

    create(
      constraint(:mcp_task_events, :mcp_task_events_revision,
        prefix: table_prefix,
        check: "event_revision > 0"
      )
    )

    create(
      constraint(:mcp_task_events, :mcp_task_events_effects_object,
        prefix: table_prefix,
        check: "jsonb_typeof(effects) = 'object'"
      )
    )

    create(
      unique_index(:mcp_task_events, [:task_id, :event_revision],
        prefix: table_prefix,
        name: :mcp_task_events_task_revision
      )
    )

    flush()

    execute(
      "INSERT INTO #{qualified_table(table_prefix, "mcp_task_store_metadata")} " <>
        "(singleton, schema_version) VALUES (TRUE, #{@initial_schema_version})"
    )
  end

  @doc "Drops the current Tasks schema, including all task data."
  def down(opts \\ []) when is_list(opts) do
    V2.down(opts)
    flush()
    down_v1(opts)
  end

  @doc false
  def down_v1(opts \\ []) when is_list(opts) do
    table_prefix = Keyword.get(opts, :prefix, prefix())

    drop(table(:mcp_task_events, prefix: table_prefix))
    drop(table(:mcp_tasks, prefix: table_prefix))
    drop(table(:mcp_task_store_metadata, prefix: table_prefix))
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
