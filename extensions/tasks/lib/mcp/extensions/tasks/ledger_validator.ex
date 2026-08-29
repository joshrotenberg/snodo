defmodule MCP.Extensions.Tasks.LedgerValidator do
  @moduledoc false

  alias MCP.Extensions.Tasks.Event
  alias MCP.Extensions.Tasks.RetryPolicy
  alias MCP.Extensions.Tasks.Snapshot
  alias MCP.Extensions.Tasks.Task, as: ProtocolTask
  alias MCP.Extensions.Tasks.Work

  @type ledger_record :: %{
          task_id: String.t(),
          event: Event.t(),
          effects: map(),
          revision: pos_integer(),
          committed_at: String.t()
        }

  @spec validate(Snapshot.t(), [ledger_record()], String.t()) :: :ok | {:error, term()}
  def validate(%Snapshot{} = snapshot, records, task_id)
      when is_list(records) and is_binary(task_id) and task_id != "" do
    with :ok <- Snapshot.validate(snapshot),
         :ok <- validate_snapshot_task_id(snapshot, task_id),
         :ok <- validate_records(records, task_id),
         :ok <- validate_revisions(records, snapshot.revision),
         :ok <- validate_event_ids(records),
         :ok <- validate_commit_order(records),
         :ok <- validate_history_semantics(snapshot, records),
         :ok <- validate_final_commit(snapshot, records) do
      validate_final_event(snapshot, records)
    end
  end

  def validate(_snapshot, _records, _task_id), do: {:error, :invalid_event_ledger}

  defp validate_snapshot_task_id(%Snapshot{task: %ProtocolTask{id: task_id}}, task_id), do: :ok

  defp validate_snapshot_task_id(_snapshot, _task_id),
    do: {:error, :event_ledger_task_id_mismatch}

  defp validate_records(records, task_id) do
    Enum.reduce_while(records, :ok, fn record, :ok ->
      case validate_record(record, task_id) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp validate_record(
         %{
           task_id: record_task_id,
           event: %Event{} = event,
           effects: effects,
           revision: revision,
           committed_at: committed_at
         } = record,
         task_id
       )
       when map_size(record) == 5 and is_map(effects) and is_integer(revision) and revision > 0 do
    cond do
      record_task_id != task_id ->
        {:error, :event_ledger_task_id_mismatch}

      not ProtocolTask.valid_timestamp?(committed_at) ->
        {:error, :invalid_event_ledger_timestamp}

      true ->
        Event.validate(event)
    end
  end

  defp validate_record(_record, _task_id), do: {:error, :invalid_event_ledger_record}

  defp validate_revisions(records, revision) do
    revisions = Enum.map(records, & &1.revision)
    expected = if revision == 0, do: [], else: Enum.to_list(1..revision)

    if revisions == expected,
      do: :ok,
      else: {:error, :event_ledger_revision_mismatch}
  end

  defp validate_event_ids(records) do
    ids = Enum.map(records, & &1.event.id)

    if MapSet.size(MapSet.new(ids)) == length(ids),
      do: :ok,
      else: {:error, :event_ledger_duplicate_id}
  end

  defp validate_commit_order(records) do
    records
    |> Enum.map(& &1.committed_at)
    |> Enum.reduce_while({:ok, nil}, fn timestamp, {:ok, previous} ->
      case parse_timestamp(timestamp) do
        {:ok, current} ->
          compare_commit_timestamp(previous, current)

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, _latest} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp compare_commit_timestamp(nil, current), do: {:cont, {:ok, current}}

  defp compare_commit_timestamp(previous, current) do
    if DateTime.compare(previous, current) == :lt,
      do: {:cont, {:ok, current}},
      else: {:halt, {:error, :event_ledger_timestamp_order_mismatch}}
  end

  defp validate_history_semantics(snapshot, records) do
    initial_state = %{
      exhausted?: false,
      terminal?: false,
      latest_failure: nil,
      latest_retry_at: nil,
      scheduled_count: 0
    }

    result =
      Enum.reduce_while(records, {:ok, initial_state}, fn record, {:ok, state} ->
        case validate_history_effect(record, retry_policy(snapshot), state, snapshot) do
          {:ok, next_state} -> {:cont, {:ok, next_state}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)

    with {:ok, state} <- result do
      validate_final_retry_state(snapshot, state)
    end
  end

  defp validate_history_effect(_record, _policy, %{terminal?: true}, _snapshot),
    do: {:error, :event_after_terminal_state}

  defp validate_history_effect(
         %{event: %Event{kind: :retry_requested}} = record,
         policy,
         state,
         snapshot
       ) do
    case record.effects do
      %{retry: retry} when map_size(record.effects) == 1 ->
        validate_retry_effect(record, retry, policy, state, snapshot)

      _invalid ->
        {:error, :event_effect_mismatch}
    end
  end

  defp validate_history_effect(
         %{
           event: %Event{kind: :input_responses_accepted, data: %{"responses" => offered}},
           effects: %{accepted_input_responses: accepted} = effects
         },
         _policy,
         state,
         _snapshot
       )
       when map_size(effects) == 1 and is_map(accepted) do
    if map_size(accepted) > 0 and Map.take(offered, Map.keys(accepted)) == accepted,
      do: {:ok, state},
      else: {:error, :event_effect_mismatch}
  end

  defp validate_history_effect(
         %{event: %Event{kind: kind}, effects: effects},
         _policy,
         state,
         _snapshot
       )
       when kind in [:completed, :failed, :cancelled] and map_size(effects) == 0 do
    {:ok, %{state | terminal?: true}}
  end

  defp validate_history_effect(
         %{event: %Event{kind: :input_requested}, effects: effects},
         _policy,
         state,
         _snapshot
       )
       when map_size(effects) == 0 do
    {:ok, state}
  end

  defp validate_history_effect(_record, _policy, _state, _snapshot),
    do: {:error, :event_effect_mismatch}

  defp validate_retry_effect(
         record,
         %{disposition: :scheduled} = retry,
         policy,
         state,
         _snapshot
       ) do
    expected_count = state.scheduled_count + 1

    cond do
      state.exhausted? or retry.retry_count != expected_count ->
        {:error, :retry_effect_sequence_mismatch}

      RetryPolicy.next_delay(policy, state.scheduled_count) != {:ok, retry.delay_ms} ->
        {:error, :retry_effect_policy_mismatch}

      not retry_timestamp_matches?(record.committed_at, retry.delay_ms, retry.retry_at) ->
        {:error, :retry_effect_timestamp_mismatch}

      true ->
        {:ok,
         %{
           state
           | latest_failure: retry_failure(record.event),
             latest_retry_at: retry.retry_at,
             scheduled_count: expected_count
         }}
    end
  end

  defp validate_retry_effect(
         record,
         %{disposition: :exhausted} = retry,
         policy,
         state,
         snapshot
       ) do
    cond do
      state.exhausted? or retry.retry_count != state.scheduled_count ->
        {:error, :retry_effect_sequence_mismatch}

      RetryPolicy.next_delay(policy, state.scheduled_count) != :exhausted ->
        {:error, :retry_effect_policy_mismatch}

      not exhausted_snapshot_matches?(snapshot, record) ->
        {:error, :retry_exhaustion_snapshot_mismatch}

      true ->
        {:ok,
         %{
           state
           | exhausted?: true,
             terminal?: true,
             latest_failure: retry_failure(record.event),
             latest_retry_at: nil
         }}
    end
  end

  defp validate_retry_effect(_record, _retry, _policy, _state, _snapshot),
    do: {:error, :event_effect_mismatch}

  defp validate_final_retry_state(snapshot, state) do
    cond do
      state.scheduled_count != snapshot.retry_count ->
        {:error, :retry_snapshot_count_mismatch}

      state.latest_failure != snapshot.last_failure ->
        {:error, :retry_snapshot_failure_mismatch}

      not ProtocolTask.terminal?(snapshot.task) and
          state.latest_retry_at != snapshot.retry_at ->
        {:error, :retry_snapshot_availability_mismatch}

      true ->
        :ok
    end
  end

  defp exhausted_snapshot_matches?(snapshot, record) do
    failure = retry_failure(record.event)

    record.revision == snapshot.revision and snapshot.task.status == :failed and
      snapshot.task.error == failure["error"] and
      snapshot.task.status_message == failure["statusMessage"] and is_nil(snapshot.retry_at)
  end

  defp validate_final_commit(%Snapshot{revision: 0}, []), do: :ok

  defp validate_final_commit(%Snapshot{} = snapshot, records) do
    case List.last(records) do
      %{committed_at: committed_at} ->
        if timestamps_equal?(committed_at, snapshot.task.last_updated_at),
          do: :ok,
          else: {:error, :event_ledger_final_timestamp_mismatch}

      nil ->
        {:error, :event_ledger_revision_mismatch}
    end
  end

  defp validate_final_event(%Snapshot{revision: 0}, []), do: :ok

  defp validate_final_event(%Snapshot{} = snapshot, records) do
    records
    |> List.last()
    |> validate_final_event_record(snapshot)
  end

  defp validate_final_event_record(
         %{event: %Event{kind: :completed, data: %{"result" => result}}},
         snapshot
       ) do
    final_snapshot_result(snapshot.task.status == :completed and snapshot.task.result == result)
  end

  defp validate_final_event_record(
         %{
           event: %Event{
             kind: :failed,
             data: %{"error" => error, "statusMessage" => status_message}
           }
         },
         snapshot
       ) do
    matches? =
      snapshot.task.status == :failed and snapshot.task.error == error and
        snapshot.task.status_message == status_message

    final_snapshot_result(matches?)
  end

  defp validate_final_event_record(%{event: %Event{kind: :cancelled}}, snapshot) do
    matches? =
      snapshot.task.status == :cancelled and
        snapshot.task.status_message == "Cancellation requested"

    final_snapshot_result(matches?)
  end

  defp validate_final_event_record(
         %{
           event: %Event{kind: :input_requested, data: %{"key" => key, "request" => request}}
         },
         snapshot
       ) do
    matches? =
      snapshot.task.status == :input_required and
        Map.get(snapshot.task.input_requests, key) == request and
        Map.get(snapshot.input_history, key) == request

    final_snapshot_result(matches?)
  end

  defp validate_final_event_record(
         %{
           event: %Event{kind: :input_responses_accepted},
           effects: %{accepted_input_responses: accepted}
         },
         snapshot
       ) do
    final_snapshot_result(final_input_responses_match?(snapshot, accepted))
  end

  defp validate_final_event_record(
         %{
           event: %Event{kind: :retry_requested},
           effects: %{retry: %{disposition: :scheduled} = retry}
         },
         snapshot
       ) do
    matches? =
      not ProtocolTask.terminal?(snapshot.task) and snapshot.retry_at == retry.retry_at and
        snapshot.retry_count == retry.retry_count

    final_snapshot_result(matches?)
  end

  defp validate_final_event_record(
         %{
           event: %Event{kind: :retry_requested},
           effects: %{retry: %{disposition: :exhausted}}
         },
         _snapshot
       ),
       do: :ok

  defp validate_final_event_record(_record, _snapshot),
    do: {:error, :invalid_event_ledger_record}

  defp final_input_responses_match?(snapshot, accepted) do
    expected_status =
      if map_size(snapshot.task.input_requests) == 0,
        do: :working,
        else: :input_required

    accepted_matches? =
      Map.take(snapshot.accepted_input_responses, Map.keys(accepted)) == accepted

    still_outstanding? =
      Enum.any?(Map.keys(accepted), &Map.has_key?(snapshot.task.input_requests, &1))

    snapshot.task.status == expected_status and accepted_matches? and not still_outstanding?
  end

  defp final_snapshot_result(true), do: :ok
  defp final_snapshot_result(false), do: {:error, :event_ledger_final_snapshot_mismatch}

  defp retry_failure(%Event{data: %{"error" => error, "statusMessage" => status_message}}) do
    %{"error" => error, "statusMessage" => status_message}
  end

  defp retry_policy(%Snapshot{work: %Work{retry_policy: policy}}), do: policy
  defp retry_policy(%Snapshot{}), do: RetryPolicy.none()

  defp retry_timestamp_matches?(committed_at, delay_ms, retry_at) do
    with {:ok, committed} <- parse_timestamp(committed_at),
         {:ok, scheduled} <- parse_timestamp(retry_at) do
      DateTime.compare(DateTime.add(committed, delay_ms, :millisecond), scheduled) == :eq
    else
      {:error, _reason} -> false
    end
  rescue
    ArgumentError -> false
  end

  defp timestamps_equal?(left, right) do
    with {:ok, left_at} <- parse_timestamp(left),
         {:ok, right_at} <- parse_timestamp(right) do
      DateTime.compare(left_at, right_at) == :eq
    else
      {:error, _reason} -> false
    end
  end

  defp parse_timestamp(timestamp) when is_binary(timestamp) do
    case DateTime.from_iso8601(timestamp) do
      {:ok, datetime, _offset} -> {:ok, datetime}
      {:error, _reason} -> {:error, :invalid_event_ledger_timestamp}
    end
  end

  defp parse_timestamp(_timestamp), do: {:error, :invalid_event_ledger_timestamp}
end
