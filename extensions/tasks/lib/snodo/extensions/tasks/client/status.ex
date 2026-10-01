defmodule Snodo.Extensions.Tasks.Client.Status do
  @moduledoc """
  A task's status as a client reads it: from the creation result of a
  task-augmented `tools/call`, from `tasks/get`, or from a `notifications/tasks`
  event.

  The fields mirror the wire shape with atom keys:

    * `task_id` - the server's `taskId`.
    * `status` - `:working`, `:input_required`, `:completed`, `:failed`, or
      `:cancelled`.
    * `status_message` - the server's `statusMessage`, or `nil`.
    * `created_at`, `last_updated_at` - the ISO 8601 timestamps as sent.
    * `ttl_ms` - `ttlMs`, or `nil` for a task the server keeps indefinitely.
    * `poll_interval_ms` - `pollIntervalMs`, or `nil` when the server sent none.
    * `input_requests` - for `:input_required`, the outstanding requests keyed
      by the key to answer them under in `tasks/update`; `%{}` otherwise.
    * `result` - for `:completed`, the final `CallToolResult` map as the server
      sent it; `nil` otherwise.
    * `error` - for `:failed`, the JSON-RPC error object the task failed with;
      `nil` otherwise.

    * `raw` - the decoded map, `_meta` included, for fields this struct does
      not name.

  A creation result (`"resultType" => "task"`) is the flat task and need not
  carry these three payloads, so a status decoded from one can have
  `input_requests: %{}`, `result: nil`, and `error: nil` whatever its status.
  `detailed?/1` tells whether a status carries the payload its status implies.
  """

  @type status :: :working | :input_required | :completed | :failed | :cancelled

  @type t :: %__MODULE__{
          task_id: String.t(),
          status: status(),
          status_message: String.t() | nil,
          created_at: String.t() | nil,
          last_updated_at: String.t() | nil,
          ttl_ms: pos_integer() | nil,
          poll_interval_ms: pos_integer() | nil,
          input_requests: %{optional(String.t()) => map()},
          result: map() | nil,
          error: map() | nil,
          raw: map()
        }

  @enforce_keys [:task_id, :status, :raw]
  defstruct [
    :task_id,
    :status,
    :status_message,
    :created_at,
    :last_updated_at,
    :ttl_ms,
    :poll_interval_ms,
    :result,
    :error,
    :raw,
    input_requests: %{}
  ]

  @statuses %{
    "working" => :working,
    "input_required" => :input_required,
    "completed" => :completed,
    "failed" => :failed,
    "cancelled" => :cancelled
  }

  @terminal [:completed, :failed, :cancelled]

  @doc """
  Decodes a task map from the wire.

  Returns `{:error, reason}` when `taskId` is not a non-empty string, when
  `status` is not one of the five statuses, or, for anything but a creation
  result, when the payload its status requires is missing: an
  `inputRequests` object for `input_required`, a `result` object for
  `completed`, and an `error` object with an integer `code` and a string
  `message` for `failed`. A creation result needs no payload, and a payload
  it does carry is checked the same way.
  """
  @spec from_map(map()) :: {:ok, t()} | {:error, term()}
  def from_map(%{"taskId" => task_id, "status" => status} = map)
      when is_binary(task_id) and task_id != "" and is_map_key(@statuses, status) do
    status = Map.fetch!(@statuses, status)

    with {:ok, payload} <- payload(status, map, map["resultType"] == "task") do
      {:ok,
       struct!(
         __MODULE__,
         Map.merge(payload, %{
           task_id: task_id,
           status: status,
           status_message: string_or_nil(map["statusMessage"]),
           created_at: string_or_nil(map["createdAt"]),
           last_updated_at: string_or_nil(map["lastUpdatedAt"]),
           ttl_ms: positive_or_nil(map["ttlMs"]),
           poll_interval_ms: positive_or_nil(map["pollIntervalMs"]),
           raw: map
         })
       )}
    end
  end

  def from_map(map) when is_map(map), do: {:error, {:invalid_task, map}}

  @doc "Returns true for `:completed`, `:failed`, and `:cancelled`, which never change."
  @spec terminal?(t()) :: boolean()
  def terminal?(%__MODULE__{status: status}), do: status in @terminal

  @doc """
  Returns true when the status carries the payload its status implies:
  `input_requests` for `:input_required`, `result` for `:completed`, and
  `error` for `:failed`. A status decoded from a creation result may not.
  """
  @spec detailed?(t()) :: boolean()
  def detailed?(%__MODULE__{status: :input_required, input_requests: requests}),
    do: map_size(requests) > 0

  def detailed?(%__MODULE__{status: :completed, result: result}), do: is_map(result)
  def detailed?(%__MODULE__{status: :failed, error: error}), do: is_map(error)
  def detailed?(%__MODULE__{}), do: true

  @payload_keys %{input_required: "inputRequests", completed: "result", failed: "error"}

  # A creation result is the flat task; it carries no payload to require.
  defp payload(status, map, true = _creation?) do
    if Map.has_key?(map, Map.get(@payload_keys, status)),
      do: payload(status, map),
      else: {:ok, %{}}
  end

  defp payload(status, map, false), do: payload(status, map)

  defp payload(:input_required, %{"inputRequests" => requests}) when is_map(requests) do
    if Enum.all?(requests, fn {key, request} -> is_binary(key) and is_map(request) end),
      do: {:ok, %{input_requests: requests}},
      else: {:error, {:invalid_input_requests, requests}}
  end

  defp payload(:completed, %{"result" => result}) when is_map(result),
    do: {:ok, %{result: result}}

  defp payload(:failed, %{"error" => %{"code" => code, "message" => message} = error})
       when is_integer(code) and is_binary(message),
       do: {:ok, %{error: error}}

  defp payload(status, map) when status in [:working, :cancelled] and is_map(map),
    do: {:ok, %{}}

  defp payload(status, map), do: {:error, {:missing_payload, status, map}}

  defp string_or_nil(value) when is_binary(value), do: value
  defp string_or_nil(_value), do: nil

  defp positive_or_nil(value) when is_integer(value) and value > 0, do: value
  defp positive_or_nil(_value), do: nil
end
