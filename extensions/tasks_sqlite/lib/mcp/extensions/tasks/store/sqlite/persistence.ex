defmodule MCP.Extensions.Tasks.Store.SQLite.Persistence do
  @moduledoc false

  alias MCP.Extensions.Tasks.EffectCodec
  alias MCP.Extensions.Tasks.Event
  alias MCP.Extensions.Tasks.Snapshot
  alias MCP.Extensions.Tasks.Store.SQLite.EventRow
  alias MCP.Extensions.Tasks.Store.SQLite.TaskRow
  alias MCP.Extensions.Tasks.Store.SQLite.Timestamp
  alias MCP.Extensions.Tasks.Task, as: ProtocolTask
  alias MCP.JSONValue

  @row_format 1

  @spec row_format() :: pos_integer()
  def row_format, do: @row_format

  @spec project_snapshot(Snapshot.t()) :: {:ok, map()} | {:error, term()}
  def project_snapshot(%Snapshot{} = snapshot) do
    with :ok <- Snapshot.validate(snapshot),
         encoded <- Snapshot.to_map(snapshot),
         snapshot_format when is_integer(snapshot_format) and snapshot_format > 0 <-
           Map.get(encoded, "version"),
         {:ok, created_at_us} <- Timestamp.parse(snapshot.task.created_at),
         {:ok, expires_at_us} <- task_expiry(snapshot.task, created_at_us),
         {:ok, retry_at_us} <- Timestamp.optional(Map.get(encoded, "retryAt")),
         {:ok, encoded_snapshot} <- encode_json(encoded) do
      {:ok,
       %{
         row_format: @row_format,
         snapshot_format: snapshot_format,
         snapshot: encoded_snapshot,
         revision: snapshot.revision,
         status: Atom.to_string(snapshot.task.status),
         created_at_us: created_at_us,
         expires_at_us: expires_at_us,
         retry_at_us: retry_at_us
       }}
    else
      nil -> {:error, :invalid_snapshot_format}
      {:error, reason} -> {:error, reason}
    end
  rescue
    exception -> {:error, {:snapshot_projection_failed, exception}}
  end

  def project_snapshot(_snapshot), do: {:error, :invalid_snapshot}

  @spec decode_task_row(TaskRow.t()) :: {:ok, Snapshot.t()} | {:error, term()}
  def decode_task_row(%TaskRow{} = row) do
    with :ok <- equal(row.row_format, @row_format, :unsupported_row_format),
         {:ok, encoded_snapshot} <- decode_json(row.snapshot, :invalid_snapshot_json),
         {:ok, _authorization_scope} <- decode_authorization_scope(row.authorization_scope),
         {:ok, snapshot} <- Snapshot.from_map(encoded_snapshot),
         :ok <- equal(row.task_id, snapshot.task.id, :task_id_projection_mismatch),
         {:ok, projected} <- project_snapshot(snapshot),
         :ok <- equal(row.snapshot_format, projected.snapshot_format, :snapshot_format_mismatch),
         :ok <- equal(row.revision, projected.revision, :revision_projection_mismatch),
         :ok <- equal(row.status, projected.status, :status_projection_mismatch),
         :ok <- equal(row.created_at_us, projected.created_at_us, :created_at_projection_mismatch),
         :ok <- equal(row.expires_at_us, projected.expires_at_us, :expires_at_projection_mismatch),
         :ok <- equal(row.retry_at_us, projected.retry_at_us, :retry_at_projection_mismatch),
         :ok <- validate_claim_projection(row) do
      {:ok, snapshot}
    end
  end

  def decode_task_row(_row), do: {:error, :invalid_task_row}

  @spec encode_json(term()) :: {:ok, String.t()} | {:error, term()}
  def encode_json(value) do
    case Jason.encode(value) do
      {:ok, encoded} -> {:ok, encoded}
      {:error, reason} -> {:error, {:json_encode_failed, reason}}
    end
  rescue
    exception -> {:error, {:json_encode_failed, exception}}
  end

  @spec decode_authorization_scope(term()) :: {:ok, map()} | {:error, term()}
  def decode_authorization_scope(encoded_scope) do
    with {:ok, scope} <- decode_json(encoded_scope, :invalid_authorization_scope_json),
         :ok <- validate_authorization_scope(scope) do
      {:ok, scope}
    end
  end

  @spec authorization_scope_matches?(term(), map()) :: boolean()
  def authorization_scope_matches?(encoded_scope, expected_scope) do
    case decode_authorization_scope(encoded_scope) do
      {:ok, actual_scope} -> actual_scope == expected_scope
      _invalid -> false
    end
  end

  @spec encode_effects(map()) :: {:ok, String.t()} | {:error, term()}
  def encode_effects(effects) do
    with {:ok, encoded} <- EffectCodec.encode(effects) do
      encode_json(encoded)
    end
  end

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
         {:ok, encoded_event} <- decode_json(row.event, :invalid_event_json),
         {:ok, event} <- Event.from_map(encoded_event),
         :ok <- equal(row.event_id, event.id, :event_id_projection_mismatch),
         :ok <- equal(row.event_kind, Atom.to_string(event.kind), :event_kind_projection_mismatch),
         {:ok, revision} <- positive_integer(row.event_revision),
         {:ok, encoded_effects} <- decode_json(row.effects, :invalid_effects_json),
         {:ok, effects} <- EffectCodec.decode(encoded_effects),
         {:ok, committed_at} <- Timestamp.format(row.committed_at_us),
         {:ok, projected_committed_at_us} <- Timestamp.parse(committed_at),
         :ok <-
           equal(
             row.committed_at_us,
             projected_committed_at_us,
             :committed_at_projection_mismatch
           ) do
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

  defp task_expiry(%ProtocolTask{ttl_ms: nil}, _created_at_us), do: {:ok, nil}

  defp task_expiry(%ProtocolTask{ttl_ms: ttl_ms}, created_at_us)
       when is_integer(ttl_ms) and ttl_ms > 0 do
    Timestamp.add_milliseconds(created_at_us, ttl_ms)
  end

  defp task_expiry(_task, _created_at_us), do: {:error, :invalid_task_ttl}

  defp positive_integer(value) when is_integer(value) and value > 0, do: {:ok, value}
  defp positive_integer(_value), do: {:error, :invalid_positive_integer}

  defp decode_json(value, tag) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, reason} -> {:error, {tag, reason}}
    end
  rescue
    exception -> {:error, {tag, exception}}
  end

  defp decode_json(_value, tag), do: {:error, tag}

  defp equal(value, value, _reason), do: :ok
  defp equal(_left, _right, reason), do: {:error, reason}

  defp validate_authorization_scope(%{"version" => 1, "value" => scope} = encoded)
       when map_size(encoded) == 2 do
    if JSONValue.valid?(scope), do: :ok, else: {:error, :invalid_authorization_scope}
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
    is_nil(row.claim_owner) and is_nil(row.claim_token) and is_nil(row.claim_expires_at_us)
  end

  defp active_claim_projection?(row) do
    is_binary(row.claim_owner) and row.claim_owner != "" and
      match?({:ok, _uuid}, Ecto.UUID.cast(row.claim_token)) and
      is_integer(row.claim_expires_at_us)
  end

  defp valid_generation?(row, minimum) do
    is_integer(row.lease_generation) and row.lease_generation >= minimum
  end
end
