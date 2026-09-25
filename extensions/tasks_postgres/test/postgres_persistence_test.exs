defmodule Snodo.Extensions.Tasks.Postgres.PersistenceTest do
  use ExUnit.Case, async: true

  @moduletag mcp_contract: ["tasks-postgres-adapter"]

  alias Snodo.Extensions.Tasks.Event
  alias Snodo.Extensions.Tasks.Snapshot
  alias Snodo.Extensions.Tasks.Store.Postgres.EventRow
  alias Snodo.Extensions.Tasks.Store.Postgres.Persistence
  alias Snodo.Extensions.Tasks.Store.Postgres.TaskRow
  alias Snodo.Extensions.Tasks.Task, as: ProtocolTask
  alias Snodo.Extensions.Tasks.Work

  @created_at "2026-08-25T10:00:00.000Z"

  test "task row decoding binds the database key and exact authorization envelope" do
    snapshot = Snapshot.new(task("task-key"), work("task-key"))
    row = task_row(snapshot)

    assert {:ok, ^snapshot} = Persistence.decode_task_row(row)

    assert {:error, :task_id_projection_mismatch} =
             row
             |> Map.put(:task_id, "forged-key")
             |> Persistence.decode_task_row()

    invalid_scopes = [
      %{"version" => 2, "value" => "tenant-a"},
      %{"version" => 1, "value" => "tenant-a", "extra" => true},
      %{"version" => 1},
      %{version: 1, value: "tenant-a"},
      %{"version" => 1, "value" => {:tenant, "a"}}
    ]

    for invalid_scope <- invalid_scopes do
      assert {:error, :invalid_authorization_scope} =
               row
               |> Map.put(:authorization_scope, invalid_scope)
               |> Persistence.decode_task_row()
    end
  end

  test "event row decoding binds ledger rows to the requested aggregate" do
    event = event!(Event.completed(%{"ok" => true}, id: "completed-event"))

    event_row =
      struct!(EventRow, %{
        task_id: "task-key",
        event_id: event.id,
        row_format: 1,
        event: Event.to_map(event),
        event_kind: "completed",
        event_revision: 1,
        committed_at: ~U[2026-08-25 10:00:01.000Z],
        effects: %{"version" => 1, "kind" => "none"}
      })

    assert {:ok, %{task_id: "task-key"}} = Persistence.decode_event_row(event_row)
  end

  defp task(id) do
    ProtocolTask.new!(
      id: id,
      created_at: @created_at,
      ttl_ms: nil,
      poll_interval_ms: 50,
      status_message: "accepted"
    )
  end

  defp work(id), do: Work.new!(id, "test/work", %{"taskId" => id})

  defp task_row(snapshot) do
    {:ok, projected} = Persistence.project_snapshot(snapshot)

    struct!(TaskRow, %{
      task_id: snapshot.task.id,
      row_format: projected.row_format,
      snapshot_format: projected.snapshot_format,
      snapshot: projected.snapshot,
      authorization_scope: %{"version" => 1, "value" => "tenant-a"},
      revision: projected.revision,
      status: projected.status,
      created_at: projected.created_at,
      expires_at: projected.expires_at,
      retry_at: projected.retry_at,
      claim_owner: nil,
      claim_token: nil,
      lease_generation: 0,
      claim_expires_at: nil
    })
  end

  defp event!({:ok, %Event{} = event}), do: event
end
