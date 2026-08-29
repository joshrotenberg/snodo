defmodule MCP.Extensions.Tasks.Store.SQLite.Migration do
  @moduledoc """
  Current SQLite migration for `MCP.Extensions.Tasks.Store.SQLite`.

  A fresh install composes every schema step through version two. Existing
  version-one installations should run `Migration.V2` as a separate
  application-owned migration. The adapter never runs either path itself, so
  the application retains control of the database file, deployment order, and
  rollback policy.

  SQLite does not support Ecto table prefixes or adding table constraints with
  `ALTER TABLE`, so this migration intentionally has no prefix option and
  creates its complete constraints with the original tables.
  """

  use Ecto.Migration

  alias MCP.Extensions.Tasks.Store.SQLite.Migration.V2

  @initial_schema_version 1
  @schema_version 2
  @dialyzer {:nowarn_function, up: 0, down: 0, up_v1: 0, down_v1: 0}

  @spec current_version() :: pos_integer()
  def current_version, do: @schema_version

  @doc "Creates the current Tasks schema from an empty database."
  def up do
    up_v1()
    flush()
    V2.up()
  end

  @doc false
  def up_v1 do
    execute("""
    CREATE TABLE mcp_task_store_metadata (
      singleton INTEGER NOT NULL PRIMARY KEY,
      schema_version INTEGER NOT NULL,
      CONSTRAINT mcp_task_store_metadata_singleton
        CHECK (singleton = 1 AND typeof(singleton) = 'integer'),
      CONSTRAINT mcp_task_store_metadata_version
        CHECK (schema_version > 0 AND typeof(schema_version) = 'integer')
    )
    """)

    execute("""
    CREATE TABLE mcp_tasks (
      task_id TEXT NOT NULL PRIMARY KEY,
      row_format INTEGER NOT NULL DEFAULT 1,
      snapshot_format INTEGER NOT NULL,
      snapshot TEXT NOT NULL,
      authorization_scope TEXT NOT NULL,
      revision INTEGER NOT NULL,
      status TEXT NOT NULL,
      created_at_us INTEGER NOT NULL,
      expires_at_us INTEGER,
      retry_at_us INTEGER,
      claim_owner TEXT,
      claim_token TEXT,
      lease_generation INTEGER NOT NULL DEFAULT 0,
      claim_expires_at_us INTEGER,

      CONSTRAINT mcp_tasks_task_id_nonempty
        CHECK (task_id <> '' AND typeof(task_id) = 'text'),
      CONSTRAINT mcp_tasks_row_format
        CHECK (row_format = 1 AND typeof(row_format) = 'integer'),
      CONSTRAINT mcp_tasks_snapshot_format
        CHECK (snapshot_format > 0 AND typeof(snapshot_format) = 'integer'),
      CONSTRAINT mcp_tasks_snapshot_object
        CHECK (
          typeof(snapshot) = 'text' AND
          json_valid(snapshot) AND
          json_type(snapshot) = 'object'
        ),
      CONSTRAINT mcp_tasks_scope_object
        CHECK (
          typeof(authorization_scope) = 'text' AND
          json_valid(authorization_scope) AND
          json_type(authorization_scope) = 'object'
        ),
      CONSTRAINT mcp_tasks_revision
        CHECK (revision >= 0 AND typeof(revision) = 'integer'),
      CONSTRAINT mcp_tasks_status
        CHECK (status IN ('working', 'input_required', 'completed', 'failed', 'cancelled')),
      CONSTRAINT mcp_tasks_created_at
        CHECK (typeof(created_at_us) = 'integer'),
      CONSTRAINT mcp_tasks_expiry
        CHECK (
          expires_at_us IS NULL OR
          (typeof(expires_at_us) = 'integer' AND expires_at_us >= created_at_us)
        ),
      CONSTRAINT mcp_tasks_retry_at
        CHECK (retry_at_us IS NULL OR typeof(retry_at_us) = 'integer'),
      CONSTRAINT mcp_tasks_generation
        CHECK (lease_generation >= 0 AND typeof(lease_generation) = 'integer'),
      CONSTRAINT mcp_tasks_claim_shape
        CHECK (
          (
            claim_owner IS NULL AND
            claim_token IS NULL AND
            claim_expires_at_us IS NULL
          )
          OR
          (
            claim_owner IS NOT NULL AND
            typeof(claim_owner) = 'text' AND
            claim_owner <> '' AND
            claim_token IS NOT NULL AND
            typeof(claim_token) = 'text' AND
            length(claim_token) = 36 AND
            claim_expires_at_us IS NOT NULL AND
            typeof(claim_expires_at_us) = 'integer' AND
            lease_generation > 0
          )
        )
    )
    """)

    execute("""
    CREATE INDEX mcp_tasks_recovery_queue
      ON mcp_tasks (claim_expires_at_us, created_at_us, task_id)
      WHERE status IN ('working', 'input_required')
    """)

    execute("""
    CREATE INDEX mcp_tasks_retry_queue
      ON mcp_tasks (retry_at_us, created_at_us, task_id)
      WHERE status IN ('working', 'input_required') AND retry_at_us IS NOT NULL
    """)

    execute("""
    CREATE INDEX mcp_tasks_ttl
      ON mcp_tasks (expires_at_us, task_id)
      WHERE expires_at_us IS NOT NULL
    """)

    execute("""
    CREATE TABLE mcp_task_events (
      task_id TEXT NOT NULL,
      event_id TEXT NOT NULL,
      row_format INTEGER NOT NULL DEFAULT 1,
      event TEXT NOT NULL,
      event_kind TEXT NOT NULL,
      event_revision INTEGER NOT NULL,
      committed_at_us INTEGER NOT NULL,
      effects TEXT NOT NULL,

      PRIMARY KEY (task_id, event_id),
      FOREIGN KEY (task_id) REFERENCES mcp_tasks(task_id) ON DELETE CASCADE,

      CONSTRAINT mcp_task_events_task_id_nonempty
        CHECK (task_id <> '' AND typeof(task_id) = 'text'),
      CONSTRAINT mcp_task_events_event_id_nonempty
        CHECK (event_id <> '' AND typeof(event_id) = 'text'),
      CONSTRAINT mcp_task_events_row_format
        CHECK (row_format = 1 AND typeof(row_format) = 'integer'),
      CONSTRAINT mcp_task_events_event_object
        CHECK (
          typeof(event) = 'text' AND
          json_valid(event) AND
          json_type(event) = 'object'
        ),
      CONSTRAINT mcp_task_events_event_kind
        CHECK (
          event_kind IN (
            'input_requested',
            'input_responses_accepted',
            'retry_requested',
            'completed',
            'failed',
            'cancelled'
          )
        ),
      CONSTRAINT mcp_task_events_revision
        CHECK (event_revision > 0 AND typeof(event_revision) = 'integer'),
      CONSTRAINT mcp_task_events_committed_at
        CHECK (typeof(committed_at_us) = 'integer'),
      CONSTRAINT mcp_task_events_effects_object
        CHECK (
          typeof(effects) = 'text' AND
          json_valid(effects) AND
          json_type(effects) = 'object'
        )
    )
    """)

    execute("""
    CREATE UNIQUE INDEX mcp_task_events_task_revision
      ON mcp_task_events (task_id, event_revision)
    """)

    execute(
      "INSERT INTO mcp_task_store_metadata (singleton, schema_version) " <>
        "VALUES (1, #{@initial_schema_version})"
    )
  end

  @doc "Drops the current Tasks schema, including all task data."
  def down do
    V2.down()
    flush()
    down_v1()
  end

  @doc false
  def down_v1 do
    execute("DROP TABLE mcp_task_events")
    execute("DROP TABLE mcp_tasks")
    execute("DROP TABLE mcp_task_store_metadata")
  end
end
