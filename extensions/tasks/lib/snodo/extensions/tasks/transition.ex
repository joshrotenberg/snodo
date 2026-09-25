defmodule Snodo.Extensions.Tasks.Transition do
  @moduledoc """
  Pure application of a validated Task event to a revisioned snapshot.

  The reducer emits `:applied` only when durable state changes and advances the
  revision exactly once. `:unchanged` represents a valid no-op. Stores may use
  `:duplicate` when replaying a previously committed event; pure application
  does not emit that outcome because event history belongs to the store.
  """

  alias Snodo.Extensions.Tasks.Event
  alias Snodo.Extensions.Tasks.RetryPolicy
  alias Snodo.Extensions.Tasks.Snapshot
  alias Snodo.Extensions.Tasks.Task, as: ProtocolTask

  @type outcome :: :applied | :unchanged | :duplicate

  @type t :: %__MODULE__{
          outcome: outcome(),
          snapshot: Snapshot.t(),
          effects: map(),
          event_revision: non_neg_integer(),
          committed_at: String.t()
        }

  @enforce_keys [:outcome, :snapshot, :effects, :event_revision, :committed_at]
  defstruct [:outcome, :snapshot, :effects, :event_revision, :committed_at]

  @doc "Applies one event at the store-assigned commit timestamp."
  @spec apply(Snapshot.t(), Event.t(), String.t()) :: {:ok, t()} | {:error, term()}
  def apply(%Snapshot{} = snapshot, %Event{} = event, committed_at) do
    with :ok <- Snapshot.validate(snapshot),
         :ok <- Event.validate(event),
         :ok <- validate_committed_at(committed_at) do
      reduce(snapshot, event, committed_at)
    end
  end

  def apply(_snapshot, _event, _committed_at), do: {:error, :invalid_transition_arguments}

  defp reduce(%Snapshot{task: task} = snapshot, _event, committed_at)
       when task.status in [:completed, :failed, :cancelled] do
    unchanged(snapshot, committed_at)
  end

  defp reduce(snapshot, %Event{kind: :input_requested, data: data}, committed_at) do
    key = Map.fetch!(data, "key")
    request = Map.fetch!(data, "request")

    case ProtocolTask.add_input(
           snapshot.task,
           key,
           request,
           committed_at
         ) do
      {:ok, task} ->
        next_snapshot = %{
          snapshot
          | input_history: Map.put(snapshot.input_history, key, request)
        }

        applied(next_snapshot, task, committed_at, %{})

      {:error, :duplicate_input_key} ->
        {:error, :duplicate_input_key}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp reduce(
         snapshot,
         %Event{kind: :input_responses_accepted, data: %{"responses" => responses}},
         committed_at
       ) do
    matched = Map.take(responses, Map.keys(snapshot.task.input_requests))

    if map_size(matched) == 0 do
      unchanged(snapshot, committed_at, %{accepted_input_responses: %{}})
    else
      {:ok, task, _matched_keys} =
        ProtocolTask.fulfill_inputs(snapshot.task, Map.keys(matched), committed_at)

      next_snapshot = %{
        snapshot
        | accepted_input_responses: Map.merge(snapshot.accepted_input_responses, matched)
      }

      applied(next_snapshot, task, committed_at, %{accepted_input_responses: matched})
    end
  end

  defp reduce(
         snapshot,
         %Event{kind: :completed, data: %{"result" => result}},
         committed_at
       ) do
    case ProtocolTask.complete(snapshot.task, result, committed_at) do
      {:ok, task} -> applied(%{snapshot | retry_at: nil}, task, committed_at, %{})
      {:terminal, _task} -> unchanged(snapshot, committed_at)
    end
  end

  defp reduce(
         snapshot,
         %Event{
           kind: :retry_requested,
           data: %{"error" => error, "statusMessage" => status_message}
         },
         committed_at
       ) do
    failure = %{"error" => error, "statusMessage" => status_message}

    case next_retry_delay(snapshot) do
      {:ok, delay_ms} ->
        with {:ok, retry_at} <- add_milliseconds(committed_at, delay_ms) do
          next_snapshot = %{
            snapshot
            | retry_count: snapshot.retry_count + 1,
              retry_at: retry_at,
              last_failure: failure
          }

          touched = %{snapshot.task | last_updated_at: committed_at}

          effects = %{
            retry: %{
              disposition: :scheduled,
              retry_at: retry_at,
              delay_ms: delay_ms,
              retry_count: next_snapshot.retry_count
            }
          }

          applied(next_snapshot, touched, committed_at, effects)
        end

      :exhausted ->
        case ProtocolTask.fail(snapshot.task, error, committed_at, status_message) do
          {:ok, task} ->
            next_snapshot = %{snapshot | retry_at: nil, last_failure: failure}

            effects = %{
              retry: %{
                disposition: :exhausted,
                retry_at: nil,
                delay_ms: nil,
                retry_count: snapshot.retry_count
              }
            }

            applied(next_snapshot, task, committed_at, effects)

          {:terminal, _task} ->
            unchanged(snapshot, committed_at)
        end
    end
  end

  defp reduce(
         snapshot,
         %Event{
           kind: :failed,
           data: %{"error" => error, "statusMessage" => status_message}
         },
         committed_at
       ) do
    case ProtocolTask.fail(snapshot.task, error, committed_at, status_message) do
      {:ok, task} -> applied(%{snapshot | retry_at: nil}, task, committed_at, %{})
      {:terminal, _task} -> unchanged(snapshot, committed_at)
    end
  end

  defp reduce(snapshot, %Event{kind: :cancelled}, committed_at) do
    case ProtocolTask.cancel(snapshot.task, committed_at, "Cancellation requested") do
      {:ok, task} -> applied(%{snapshot | retry_at: nil}, task, committed_at, %{})
      {:terminal, _task} -> unchanged(snapshot, committed_at)
    end
  end

  defp applied(snapshot, task, committed_at, effects) do
    next_snapshot = %{
      snapshot
      | task: ProtocolTask.validate!(task),
        revision: snapshot.revision + 1
    }

    with :ok <- Snapshot.validate(next_snapshot) do
      {:ok,
       %__MODULE__{
         outcome: :applied,
         snapshot: next_snapshot,
         effects: effects,
         event_revision: next_snapshot.revision,
         committed_at: committed_at
       }}
    end
  rescue
    exception in ArgumentError -> {:error, {:invalid_transition_state, exception.message}}
  end

  defp unchanged(snapshot, committed_at, effects \\ %{}) do
    {:ok,
     %__MODULE__{
       outcome: :unchanged,
       snapshot: snapshot,
       effects: effects,
       event_revision: snapshot.revision,
       committed_at: committed_at
     }}
  end

  defp validate_committed_at(committed_at) do
    if ProtocolTask.valid_timestamp?(committed_at),
      do: :ok,
      else: {:error, :invalid_commit_timestamp}
  end

  defp next_retry_delay(%Snapshot{work: %{retry_policy: policy}, retry_count: retry_count}) do
    RetryPolicy.next_delay(policy, retry_count)
  end

  defp next_retry_delay(%Snapshot{}), do: :exhausted

  defp add_milliseconds(timestamp, milliseconds) do
    case DateTime.from_iso8601(timestamp) do
      {:ok, datetime, _offset} ->
        advanced =
          datetime
          |> DateTime.add(milliseconds, :millisecond)
          |> DateTime.to_iso8601()

        if ProtocolTask.valid_timestamp?(advanced),
          do: {:ok, advanced},
          else: {:error, :invalid_retry_timestamp}

      _invalid ->
        {:error, :invalid_retry_timestamp}
    end
  rescue
    ArgumentError -> {:error, :invalid_retry_timestamp}
  end
end
