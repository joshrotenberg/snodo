defmodule MCP.Extensions.Tasks.Snapshot do
  @moduledoc """
  A revisioned Task aggregate used at persistence and compare-and-set boundaries.

  `work`, retry bookkeeping, `input_history`, and `accepted_input_responses` are
  private execution state and are never projected onto the Tasks wire shape.
  The original request for every lifetime-unique input key remains in
  `input_history`, allowing a recovered worker to distinguish an identical
  replay from an ambiguous key reuse. Accepted responses remain persisted when
  no local worker is available.
  """

  alias MCP.Extensions.Tasks.Task, as: ProtocolTask
  alias MCP.Extensions.Tasks.Work
  alias MCP.JSONValue

  @version 3

  @type retry_failure :: map()

  @type t :: %__MODULE__{
          task: ProtocolTask.t(),
          work: Work.t() | nil,
          revision: non_neg_integer(),
          retry_count: non_neg_integer(),
          retry_at: String.t() | nil,
          last_failure: retry_failure() | nil,
          input_history: %{optional(String.t()) => map()},
          accepted_input_responses: %{optional(String.t()) => map()}
        }

  @enforce_keys [:task]
  defstruct [
    :task,
    :work,
    :retry_at,
    :last_failure,
    revision: 0,
    retry_count: 0,
    input_history: %{},
    accepted_input_responses: %{}
  ]

  @doc "Creates the initial revision-zero snapshot for a durable Task."
  @spec new(ProtocolTask.t(), Work.t() | nil) :: t()
  def new(task, work \\ nil)

  def new(%ProtocolTask{} = task, work) when is_nil(work) or is_struct(work, Work) do
    task = ProtocolTask.validate!(task)
    snapshot = %__MODULE__{task: task, work: work}

    case validate(snapshot) do
      :ok -> snapshot
      {:error, reason} -> raise ArgumentError, "invalid initial snapshot: #{inspect(reason)}"
    end
  end

  def new(_task, _work), do: raise(ArgumentError, "snapshot requires a valid task and work")

  @doc false
  @spec validate(t()) :: :ok | {:error, term()}
  def validate(%__MODULE__{} = snapshot) do
    with :ok <- validate_task(snapshot.task),
         :ok <- validate_work(snapshot.work),
         :ok <- validate_revision(snapshot.revision),
         :ok <- validate_retry_count(snapshot),
         :ok <- validate_retry_at(snapshot),
         :ok <- validate_last_failure(snapshot.last_failure),
         :ok <- validate_retry_state(snapshot),
         :ok <- validate_input_history(snapshot.input_history),
         :ok <- validate_accepted_responses(snapshot.accepted_input_responses) do
      validate_input_identity(snapshot)
    end
  end

  def validate(_snapshot), do: {:error, :invalid_snapshot}

  @doc "Encodes the complete aggregate as a stable JSON-safe persistence map."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = snapshot) do
    case validate(snapshot) do
      :ok ->
        %{
          "version" => @version,
          "revision" => snapshot.revision,
          "task" => encode_task(snapshot.task),
          "work" => encode_work(snapshot.work),
          "retryCount" => snapshot.retry_count,
          "retryAt" => snapshot.retry_at,
          "lastFailure" => snapshot.last_failure,
          "inputHistory" => snapshot.input_history,
          "acceptedInputResponses" => snapshot.accepted_input_responses
        }

      {:error, reason} ->
        raise ArgumentError, "cannot encode invalid task snapshot: #{inspect(reason)}"
    end
  end

  @doc "Decodes and validates a persistence map produced by `to_map/1`."
  @spec from_map(term()) :: {:ok, t()} | {:error, term()}
  def from_map(
        %{
          "version" => @version,
          "revision" => revision,
          "task" => encoded_task,
          "work" => encoded_work,
          "retryCount" => retry_count,
          "retryAt" => retry_at,
          "lastFailure" => last_failure,
          "inputHistory" => input_history,
          "acceptedInputResponses" => accepted
        } = encoded
      )
      when map_size(encoded) == 9 do
    with {:ok, task} <- decode_task(encoded_task),
         {:ok, work} <- decode_work(encoded_work),
         snapshot = %__MODULE__{
           task: task,
           work: work,
           revision: revision,
           retry_count: retry_count,
           retry_at: retry_at,
           last_failure: last_failure,
           input_history: input_history,
           accepted_input_responses: accepted
         },
         :ok <- validate(snapshot) do
      {:ok, snapshot}
    end
  end

  def from_map(%{"version" => version}) when version != @version do
    {:error, {:unsupported_snapshot_version, version}}
  end

  def from_map(_encoded), do: {:error, :invalid_snapshot_encoding}

  @doc false
  @spec retry_due?(t(), String.t()) :: boolean()
  def retry_due?(%__MODULE__{} = snapshot, now),
    do: retry_availability(snapshot, now) == :due

  @doc false
  @spec retry_availability(t(), String.t()) :: :due | {:deferred, pos_integer()} | :invalid
  def retry_availability(%__MODULE__{retry_at: nil}, now) do
    if ProtocolTask.valid_timestamp?(now), do: :due, else: :invalid
  end

  def retry_availability(%__MODULE__{retry_at: retry_at}, now) do
    with true <- ProtocolTask.valid_timestamp?(now),
         {:ok, retry_datetime, _offset} <- DateTime.from_iso8601(retry_at),
         {:ok, now_datetime, _offset} <- DateTime.from_iso8601(now) do
      case DateTime.diff(retry_datetime, now_datetime, :microsecond) do
        remaining when remaining > 0 -> {:deferred, div(remaining + 999, 1_000)}
        _due -> :due
      end
    else
      _invalid -> :invalid
    end
  end

  defp encode_work(nil), do: nil
  defp encode_work(%Work{} = work), do: Work.to_map(work)

  defp decode_work(nil), do: {:ok, nil}
  defp decode_work(encoded), do: Work.from_map(encoded)

  defp encode_task(%ProtocolTask{} = task) do
    %{
      "id" => task.id,
      "status" => Atom.to_string(task.status),
      "statusMessage" => task.status_message,
      "createdAt" => task.created_at,
      "lastUpdatedAt" => task.last_updated_at,
      "ttlMs" => task.ttl_ms,
      "pollIntervalMs" => task.poll_interval_ms,
      "inputRequests" => task.input_requests,
      "result" => task.result,
      "error" => task.error,
      "usedInputKeys" => task.used_input_keys |> MapSet.to_list() |> Enum.sort()
    }
  end

  defp decode_task(
         %{
           "id" => id,
           "status" => status,
           "statusMessage" => status_message,
           "createdAt" => created_at,
           "lastUpdatedAt" => last_updated_at,
           "ttlMs" => ttl_ms,
           "pollIntervalMs" => poll_interval_ms,
           "inputRequests" => input_requests,
           "result" => result,
           "error" => error,
           "usedInputKeys" => used_input_keys
         } = encoded
       )
       when map_size(encoded) == 11 do
    with {:ok, decoded_status} <- decode_status(status),
         {:ok, decoded_keys} <- decode_used_input_keys(used_input_keys) do
      task = %ProtocolTask{
        id: id,
        status: decoded_status,
        status_message: status_message,
        created_at: created_at,
        last_updated_at: last_updated_at,
        ttl_ms: ttl_ms,
        poll_interval_ms: poll_interval_ms,
        input_requests: input_requests,
        result: result,
        error: error,
        used_input_keys: decoded_keys
      }

      validate_decoded_task(task)
    end
  end

  defp decode_task(_encoded), do: {:error, :invalid_task_encoding}

  defp validate_decoded_task(task) do
    {:ok, ProtocolTask.validate!(task)}
  rescue
    exception in ArgumentError -> {:error, {:invalid_persisted_task, exception.message}}
  end

  defp validate_task(%ProtocolTask{} = task) do
    _valid = ProtocolTask.validate!(task)
    :ok
  rescue
    exception in ArgumentError -> {:error, {:invalid_task, exception.message}}
  end

  defp validate_task(_task), do: {:error, :invalid_task}

  defp validate_work(nil), do: :ok
  defp validate_work(%Work{} = work), do: Work.validate(work)
  defp validate_work(_work), do: {:error, :invalid_snapshot_work}

  defp validate_revision(revision) when is_integer(revision) and revision >= 0, do: :ok
  defp validate_revision(_revision), do: {:error, :invalid_snapshot_revision}

  defp validate_retry_count(%__MODULE__{retry_count: retry_count, work: work})
       when is_integer(retry_count) and retry_count >= 0 do
    available_retries =
      case work do
        %Work{retry_policy: retry_policy} -> length(retry_policy.delays_ms)
        nil -> 0
      end

    if retry_count <= available_retries,
      do: :ok,
      else: {:error, :retry_count_exceeds_policy}
  end

  defp validate_retry_count(_snapshot), do: {:error, :invalid_retry_count}

  defp validate_retry_at(%__MODULE__{retry_at: nil}), do: :ok

  defp validate_retry_at(%__MODULE__{} = snapshot) do
    cond do
      not ProtocolTask.valid_timestamp?(snapshot.retry_at) ->
        {:error, :invalid_retry_at}

      snapshot.retry_count == 0 ->
        {:error, :retry_at_without_retry}

      ProtocolTask.terminal?(snapshot.task) ->
        {:error, :terminal_task_has_retry_at}

      is_nil(snapshot.last_failure) ->
        {:error, :retry_at_without_failure}

      true ->
        :ok
    end
  end

  defp validate_last_failure(nil), do: :ok

  defp validate_last_failure(%{"error" => error, "statusMessage" => status_message} = failure)
       when map_size(failure) == 2 do
    cond do
      not (is_map(error) and JSONValue.valid?(error)) ->
        {:error, :invalid_retry_failure_error}

      not (is_binary(status_message) or is_nil(status_message)) ->
        {:error, :invalid_retry_failure_status_message}

      true ->
        :ok
    end
  end

  defp validate_last_failure(_failure), do: {:error, :invalid_retry_failure}

  defp validate_retry_state(%__MODULE__{} = snapshot) do
    with :ok <- validate_retry_revision(snapshot),
         :ok <- validate_retry_failure_presence(snapshot),
         :ok <- validate_nonterminal_retry_availability(snapshot) do
      validate_zero_retry_failure(snapshot)
    end
  end

  defp validate_retry_revision(%__MODULE__{retry_count: retry_count, revision: revision})
       when retry_count > revision,
       do: {:error, :retry_count_exceeds_revision}

  defp validate_retry_revision(%__MODULE__{}), do: :ok

  defp validate_retry_failure_presence(%__MODULE__{retry_count: retry_count, last_failure: nil})
       when retry_count > 0,
       do: {:error, :retry_history_missing_failure}

  defp validate_retry_failure_presence(%__MODULE__{}), do: :ok

  defp validate_nonterminal_retry_availability(%__MODULE__{
         retry_count: retry_count,
         retry_at: nil,
         task: %ProtocolTask{status: status}
       })
       when retry_count > 0 and status in [:working, :input_required],
       do: {:error, :nonterminal_retry_missing_retry_at}

  defp validate_nonterminal_retry_availability(%__MODULE__{}), do: :ok

  defp validate_zero_retry_failure(%__MODULE__{retry_count: 0, last_failure: failure} = snapshot)
       when not is_nil(failure) do
    if zero_retry_exhaustion?(snapshot),
      do: :ok,
      else: {:error, :failure_without_retry_history}
  end

  defp validate_zero_retry_failure(%__MODULE__{}), do: :ok

  defp zero_retry_exhaustion?(%__MODULE__{
         task: %ProtocolTask{status: :failed} = task,
         work: work,
         revision: revision,
         retry_at: nil,
         last_failure: %{"error" => error, "statusMessage" => status_message}
       }) do
    revision > 0 and retry_delays(work) == [] and task.error == error and
      task.status_message == status_message
  end

  defp zero_retry_exhaustion?(_snapshot), do: false

  defp retry_delays(%Work{retry_policy: retry_policy}), do: retry_policy.delays_ms
  defp retry_delays(nil), do: []

  defp validate_input_history(history) when is_map(history) do
    if JSONValue.valid?(history) and
         Enum.all?(history, fn
           {key, request} when is_binary(key) and key != "" ->
             ProtocolTask.valid_input_request?(request)

           _invalid ->
             false
         end) do
      :ok
    else
      {:error, :invalid_input_history}
    end
  end

  defp validate_input_history(_history), do: {:error, :invalid_input_history}

  defp validate_accepted_responses(responses) when is_map(responses) do
    if JSONValue.valid?(responses) and
         Enum.all?(responses, fn
           {key, response} when is_binary(key) and key != "" -> is_map(response)
           _invalid -> false
         end) do
      :ok
    else
      {:error, :invalid_accepted_input_responses}
    end
  end

  defp validate_accepted_responses(_responses),
    do: {:error, :invalid_accepted_input_responses}

  defp validate_input_identity(snapshot) do
    history_keys = Map.keys(snapshot.input_history) |> MapSet.new()
    used_keys = snapshot.task.used_input_keys
    response_keys = Map.keys(snapshot.accepted_input_responses) |> MapSet.new()
    outstanding_keys = Map.keys(snapshot.task.input_requests) |> MapSet.new()

    cond do
      history_keys != used_keys ->
        {:error, :input_history_does_not_cover_used_keys}

      not outstanding_requests_match_history?(snapshot) ->
        {:error, :outstanding_input_request_does_not_match_history}

      not MapSet.subset?(response_keys, history_keys) ->
        {:error, :accepted_response_key_was_never_issued}

      not MapSet.disjoint?(response_keys, outstanding_keys) ->
        {:error, :accepted_response_still_outstanding}

      true ->
        :ok
    end
  end

  defp outstanding_requests_match_history?(snapshot) do
    Enum.all?(snapshot.task.input_requests, fn {key, request} ->
      Map.get(snapshot.input_history, key) == request
    end)
  end

  defp decode_status(status) do
    case status do
      "working" -> {:ok, :working}
      "input_required" -> {:ok, :input_required}
      "completed" -> {:ok, :completed}
      "failed" -> {:ok, :failed}
      "cancelled" -> {:ok, :cancelled}
      _invalid -> {:error, {:invalid_task_status, status}}
    end
  end

  defp decode_used_input_keys(keys) when is_list(keys) do
    cond do
      not Enum.all?(keys, &(is_binary(&1) and &1 != "")) ->
        {:error, :invalid_used_input_keys}

      MapSet.size(MapSet.new(keys)) != length(keys) ->
        {:error, :duplicate_used_input_keys}

      true ->
        {:ok, MapSet.new(keys)}
    end
  end

  defp decode_used_input_keys(_keys), do: {:error, :invalid_used_input_keys}
end
