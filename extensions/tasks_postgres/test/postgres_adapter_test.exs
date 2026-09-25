defmodule Snodo.Extensions.Tasks.Postgres.FakeRepo do
  def __adapter__, do: Ecto.Adapters.Postgres
end

defmodule Snodo.Extensions.Tasks.Postgres.WrongAdapterRepo do
  def __adapter__, do: :not_postgres
end

defmodule Snodo.Extensions.Tasks.Postgres.AdapterTest do
  use ExUnit.Case, async: true

  @moduletag mcp_contract: ["tasks-postgres-adapter"]

  alias Snodo.Context
  alias Snodo.Extensions.Tasks.Event
  alias Snodo.Extensions.Tasks.RetryPolicy
  alias Snodo.Extensions.Tasks.Snapshot
  alias Snodo.Extensions.Tasks.Store
  alias Snodo.Extensions.Tasks.Store.Postgres
  alias Snodo.Extensions.Tasks.Store.Postgres.Access
  alias Snodo.Extensions.Tasks.Store.Postgres.Config
  alias Snodo.Extensions.Tasks.Store.Postgres.EventRow
  alias Snodo.Extensions.Tasks.Store.Postgres.Migration
  alias Snodo.Extensions.Tasks.Store.Postgres.Migration.V1, as: MigrationV1
  alias Snodo.Extensions.Tasks.Store.Postgres.Migration.V2, as: MigrationV2
  alias Snodo.Extensions.Tasks.Store.Postgres.Persistence
  alias Snodo.Extensions.Tasks.Store.Postgres.TaskRow
  alias Snodo.Extensions.Tasks.Task, as: ProtocolTask
  alias Snodo.Extensions.Tasks.Transition
  alias Snodo.Extensions.Tasks.Work
  alias Snodo.Protocol.V2026_07_28
  alias Snodo.Transport.Context, as: TransportContext

  @created_at "2026-08-25T10:00:00.000Z"
  @committed_at "2026-08-25T10:00:01.000Z"

  test "configuration requires an application-owned PostgreSQL Repo" do
    assert {:ok, %Config{} = config} = Postgres.new(repo: fake_repo())
    assert config.repo == fake_repo()
    assert config.prefix == nil
    assert is_reference(config.identity)
    assert {Postgres, config} == Store.validate_ref!({Postgres, config})

    assert {:error, :repo_must_use_ecto_postgres} =
             Postgres.new(repo: Snodo.Extensions.Tasks.Postgres.WrongAdapterRepo)

    assert {:error, :repo_must_use_ecto_postgres} = Postgres.new(repo: :missing_repo)
    assert {:error, :invalid_prefix} = Postgres.new(repo: fake_repo(), prefix: "")

    assert {:error, {:invalid_positive_option, :reap_batch_size}} =
             Postgres.new(repo: fake_repo(), reap_batch_size: 0)

    assert {:error, :invalid_options} = Postgres.new(repo: fake_repo(), unknown: true)
  end

  test "authorization normalizes and wraps scalar JSON scopes" do
    config = Postgres.new!(repo: fake_repo(), scope: fn _context -> "tenant-a" end)
    store = {Postgres, config}

    assert {:ok,
            %Access{
              scope: "tenant-a",
              encoded_scope: %{"version" => 1, "value" => "tenant-a"},
              action: {:get, "task-a"}
            }} = Store.authorize(store, context(), {:get, "task-a"})
  end

  test "authorization rejects non-JSON scopes before persistence" do
    invalid = Postgres.new!(repo: fake_repo(), scope: fn _context -> {:tenant, "a"} end)

    assert {:error, :invalid_scope} =
             Store.authorize({Postgres, invalid}, context(), {:get, "task-a"})

    crashing = Postgres.new!(repo: fake_repo(), scope: fn _context -> raise "scope failed" end)

    assert {:error, {:scope_exception, %RuntimeError{}, _stacktrace}} =
             Store.authorize({Postgres, crashing}, context(), {:get, "task-a"})
  end

  test "snapshot projections preserve TTL and retry availability using typed UTC values" do
    initial = Snapshot.new(task("projected", 2_000), work("projected"))
    assert {:ok, projected} = Postgres.project_snapshot(initial)

    assert projected.snapshot_format == 3
    assert projected.revision == 0
    assert projected.status == "working"
    assert projected.created_at == ~U[2026-08-25 10:00:00.000000Z]
    assert projected.expires_at == ~U[2026-08-25 10:00:02.000000Z]
    assert projected.retry_at == nil

    retry_policy = RetryPolicy.fixed!(1_500, 1)
    retry_work = Work.new!("retry", "test", %{}, retry_policy: retry_policy)
    retry_initial = Snapshot.new(task("retry", nil), retry_work)
    retry_event = event!(Event.retry_requested(error(), "try again", id: "retry-event"))

    assert {:ok, %Transition{snapshot: retry_snapshot, effects: retry_effects}} =
             Transition.apply(retry_initial, retry_event, @committed_at)

    assert {:ok, retry_projection} = Postgres.project_snapshot(retry_snapshot)
    assert retry_projection.retry_at == ~U[2026-08-25 10:00:02.500000Z]

    row =
      struct!(TaskRow, %{
        task_id: "retry",
        row_format: retry_projection.row_format,
        snapshot_format: retry_projection.snapshot_format,
        snapshot: retry_projection.snapshot,
        authorization_scope: %{"version" => 1, "value" => "tenant-a"},
        revision: retry_projection.revision,
        status: retry_projection.status,
        created_at: retry_projection.created_at,
        expires_at: retry_projection.expires_at,
        retry_at: retry_projection.retry_at,
        claim_owner: nil,
        claim_token: nil,
        lease_generation: 0,
        claim_expires_at: nil
      })

    assert {:ok, ^retry_snapshot} = Persistence.decode_task_row(row)
    assert {:ok, encoded_effects} = Persistence.encode_effects(retry_effects)
    assert encoded_effects["kind"] == "retry"

    event_row =
      struct!(EventRow, %{
        task_id: "retry",
        event_id: retry_event.id,
        row_format: 1,
        event: Event.to_map(retry_event),
        event_kind: "retry_requested",
        event_revision: 1,
        committed_at: ~U[2026-08-25 10:00:01.000Z],
        effects: encoded_effects
      })

    assert {:ok, %{effects: ^retry_effects}} = Persistence.decode_event_row(event_row)
  end

  test "normal public Task timestamps project at Ecto microsecond precision" do
    public_timestamp = ProtocolTask.timestamp()

    public_task =
      ProtocolTask.new!(
        id: "public-timestamp",
        created_at: public_timestamp,
        ttl_ms: 1_000,
        poll_interval_ms: 50
      )

    assert {:ok, projected} =
             public_task
             |> Snapshot.new(work("public-timestamp"))
             |> Postgres.project_snapshot()

    assert elem(projected.created_at.microsecond, 1) == 6
    assert elem(projected.expires_at.microsecond, 1) == 6
    assert DateTime.to_iso8601(projected.created_at) == pad_milliseconds(public_timestamp)
  end

  test "projection mismatches and unsupported effects fail closed" do
    snapshot = Snapshot.new(task("corrupt", nil), work("corrupt"))
    {:ok, projected} = Postgres.project_snapshot(snapshot)

    row =
      struct!(TaskRow, %{
        task_id: "corrupt",
        row_format: projected.row_format,
        snapshot_format: projected.snapshot_format,
        snapshot: projected.snapshot,
        authorization_scope: %{"version" => 1, "value" => nil},
        revision: 9,
        status: projected.status,
        created_at: projected.created_at,
        expires_at: projected.expires_at,
        retry_at: projected.retry_at,
        lease_generation: 0
      })

    assert {:error, :revision_projection_mismatch} = Persistence.decode_task_row(row)
    assert {:error, :invalid_transition_effects} = Persistence.encode_effects(%{unknown: true})
  end

  test "the explicit migration exposes its immutable upgrade chain and is never implicit" do
    assert MigrationV1.current_version() == 1
    assert MigrationV2.current_version() == 2
    assert Migration.current_version() == 2
    assert function_exported?(Migration, :up, 1)
    assert function_exported?(Migration, :down, 1)
  end

  defp fake_repo, do: Snodo.Extensions.Tasks.Postgres.FakeRepo

  defp task(id, ttl_ms) do
    ProtocolTask.new!(
      id: id,
      created_at: @created_at,
      ttl_ms: ttl_ms,
      poll_interval_ms: 50,
      status_message: "accepted"
    )
  end

  defp work(id), do: Work.new!(id, "test/work", %{"taskId" => id})

  defp error do
    %{"code" => -32_603, "message" => "temporary failure"}
  end

  defp event!({:ok, %Event{} = event}), do: event

  defp pad_milliseconds(timestamp), do: String.replace_suffix(timestamp, "Z", "000Z")

  defp context do
    %Context{
      protocol_version: V2026_07_28.version(),
      protocol: V2026_07_28,
      transport: %TransportContext{transport: :direct}
    }
  end
end
