defmodule MCP.Extensions.Tasks.Store.Postgres.Persistence do
  @moduledoc false

  alias MCP.Extensions.Tasks.EffectCodec
  alias MCP.Extensions.Tasks.Event
  alias MCP.Extensions.Tasks.Snapshot
  alias MCP.Extensions.Tasks.Store.Postgres.EventRow
  alias MCP.Extensions.Tasks.Store.Postgres.TaskRow
  alias MCP.Extensions.Tasks.Task, as: ProtocolTask
  alias MCP.JSONValue

  @row_format 1

  @spec row_format() :: pos_integer()
  def row_format, do: @row_format

  @spec project_snapshot(Snapshot.t()) :: {:ok, map()} | {:error, term()}
  def project_snapshot(%Snapshot{} = snapshot) do
    with :ok <- Snapshot.validate(snapshot),
         encoded = Snapshot.to_map(snapshot),
         {:ok, snapshot_format} <- positive_integer(Map.get(encoded, "version")),
         {:ok, created_at} <- parse_timestamp(snapshot.task.created_at),
         {:ok, expires_at} <- task_expiry(snapshot.task, created_at),
         {:ok, retry_at} <- optional_timestamp(Map.get(encoded, "retryAt")) do
      {:ok,
       %{
         row_format: @row_format,
         snapshot_format: snapshot_format,
         snapshot: encoded,
         revision: snapshot.revision,
         status: Atom.to_string(snapshot.task.status),
         created_at: created_at,
         expires_at: expires_at,
         retry_at: retry_at
       }}
    end
  rescue
    exception -> {:error, {:snapshot_projection_failed, exception}}
  end

  def project_snapshot(_snapshot), do: {:error, :invalid_snapshot}

  @spec decode_task_row(TaskRow.t()) :: {:ok, Snapshot.t()} | {:error, term()}
  def decode_task_row(%TaskRow{} = row) do
    with :ok <- equal(row.row_format, @row_format, :unsupported_row_format),
         {:ok, snapshot} <- Snapshot.from_map(row.snapshot),
         :ok <- equal(row.task_id, snapshot.task.id, :task_id_projection_mismatch),
         :ok <- validate_authorization_scope(row.authorization_scope),
         {:ok, projected} <- project_snapshot(snapshot),
         :ok <- equal(row.snapshot_format, projected.snapshot_format, :snapshot_format_mismatch),
         :ok <- equal(row.revision, projected.revision, :revision_projection_mismatch),
         :ok <- equal(row.status, projected.status, :status_projection_mismatch),
         :ok <-
           datetime_equal(row.created_at, projected.created_at, :created_at_projection_mismatch),
         :ok <-
           datetime_equal(row.expires_at, projected.expires_at, :expires_at_projection_mismatch),
         :ok <- datetime_equal(row.retry_at, projected.retry_at, :retry_at_projection_mismatch),
         :ok <- validate_claim_projection(row) do
      {:ok, snapshot}
    end
  end

  def decode_task_row(_row), do: {:error, :invalid_task_row}

  @spec encode_effects(map()) :: {:ok, map()} | {:error, term()}
  defdelegate encode_effects(effects), to: EffectCodec, as: :encode

  @spec decode_event_row(EventRow.t()) ::
          {:ok,
           %{
             task_id: String.t(),
             event: Event.t(),
             effects: map(),
             revision: pos_integer(),
             committed_at: String.t()
           }}
          | {:error, term()}
  def decode_event_row(%EventRow{} = row) do
    with :ok <- equal(row.row_format, @row_format, :unsupported_event_row_format),
         {:ok, event} <- Event.from_map(row.event),
         :ok <- equal(row.event_id, event.id, :event_id_projection_mismatch),
         :ok <-
           equal(row.event_kind, Atom.to_string(event.kind), :event_kind_projection_mismatch),
         {:ok, revision} <- positive_integer(row.event_revision),
         {:ok, effects} <- EffectCodec.decode(row.effects),
         {:ok, committed_at} <- timestamp_to_string(row.committed_at) do
      {:ok,
       %{
         task_id: row.task_id,
         event: event,
         effects: effects,
         revision: revision,
         committed_at: committed_at
       }}
    end
  end

  def decode_event_row(_row), do: {:error, :invalid_event_row}

  @spec timestamp_to_string(DateTime.t()) :: {:ok, String.t()} | {:error, term()}
  def timestamp_to_string(%DateTime{} = datetime), do: {:ok, DateTime.to_iso8601(datetime)}
  def timestamp_to_string(_datetime), do: {:error, :invalid_database_timestamp}

  defp task_expiry(%ProtocolTask{ttl_ms: nil}, _created_at), do: {:ok, nil}

  defp task_expiry(%ProtocolTask{ttl_ms: ttl_ms}, created_at)
       when is_integer(ttl_ms) and ttl_ms > 0 do
    {:ok, DateTime.add(created_at, ttl_ms, :millisecond)}
  rescue
    ArgumentError -> {:error, :invalid_task_expiry}
  end

  defp task_expiry(_task, _created_at), do: {:error, :invalid_task_ttl}

  defp optional_timestamp(nil), do: {:ok, nil}
  defp optional_timestamp(timestamp), do: parse_timestamp(timestamp)

  defp parse_timestamp(timestamp) when is_binary(timestamp) do
    case DateTime.from_iso8601(timestamp) do
      {:ok, datetime, _offset} -> {:ok, ecto_usec(datetime)}
      {:error, _reason} -> {:error, :invalid_timestamp}
    end
  end

  defp parse_timestamp(_timestamp), do: {:error, :invalid_timestamp}

  # Ecto's :utc_datetime_usec type requires precision 6 even when the wire
  # timestamp intentionally carries only millisecond precision.
  defp ecto_usec(%DateTime{microsecond: {microsecond, _precision}} = datetime),
    do: %{datetime | microsecond: {microsecond, 6}}

  defp positive_integer(value) when is_integer(value) and value > 0, do: {:ok, value}
  defp positive_integer(_value), do: {:error, :invalid_positive_integer}

  defp equal(value, value, _reason), do: :ok
  defp equal(_left, _right, reason), do: {:error, reason}

  defp datetime_equal(nil, nil, _reason), do: :ok

  defp datetime_equal(%DateTime{} = left, %DateTime{} = right, reason) do
    if DateTime.compare(left, right) == :eq, do: :ok, else: {:error, reason}
  end

  defp datetime_equal(_left, _right, reason), do: {:error, reason}

  defp validate_authorization_scope(%{"version" => 1, "value" => scope} = authorization_scope)
       when map_size(authorization_scope) == 2 do
    if JSONValue.valid?(scope),
      do: :ok,
      else: {:error, :invalid_authorization_scope}
  end

  defp validate_authorization_scope(_authorization_scope),
    do: {:error, :invalid_authorization_scope}

  defp validate_claim_projection(%TaskRow{} = row) do
    cond do
      unclaimed_projection?(row) and valid_generation?(row, 0) ->
        :ok

      active_claim_projection?(row) and valid_generation?(row, 1) ->
        :ok

      true ->
        {:error, :invalid_claim_projection}
    end
  end

  defp unclaimed_projection?(row) do
    Enum.all?([row.claim_owner, row.claim_token, row.claim_expires_at], &is_nil/1)
  end

  defp active_claim_projection?(row) do
    is_binary(row.claim_owner) and row.claim_owner != "" and is_binary(row.claim_token) and
      is_struct(row.claim_expires_at, DateTime)
  end

  defp valid_generation?(row, minimum) do
    is_integer(row.lease_generation) and row.lease_generation >= minimum
  end
end
