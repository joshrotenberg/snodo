defmodule MCP.Extensions.Tasks.Task do
  @moduledoc """
  Application-facing task state for the `io.modelcontextprotocol/tasks` extension.

  The struct contains a small amount of private bookkeeping (`used_input_keys`)
  that never appears on the wire. State changes are explicit and terminal states
  are immutable, which lets an atomic store resolve cancellation/completion races.
  """

  alias MCP.JSONValue

  @type status :: :working | :input_required | :completed | :failed | :cancelled

  @type t :: %__MODULE__{
          id: String.t(),
          status: status(),
          status_message: String.t() | nil,
          created_at: String.t(),
          last_updated_at: String.t(),
          ttl_ms: pos_integer() | nil,
          poll_interval_ms: pos_integer() | nil,
          input_requests: map(),
          result: map() | nil,
          error: map() | nil,
          used_input_keys: MapSet.t(String.t())
        }

  @terminal [:completed, :failed, :cancelled]

  @enforce_keys [:id, :created_at, :last_updated_at, :ttl_ms]
  defstruct [
    :id,
    :status_message,
    :created_at,
    :last_updated_at,
    :ttl_ms,
    :poll_interval_ms,
    :result,
    :error,
    status: :working,
    input_requests: %{},
    used_input_keys: MapSet.new()
  ]

  @spec new!(keyword()) :: t()
  def new!(opts) when is_list(opts) do
    task = %__MODULE__{
      id: Keyword.fetch!(opts, :id),
      created_at: Keyword.fetch!(opts, :created_at),
      last_updated_at: Keyword.fetch!(opts, :created_at),
      ttl_ms: Keyword.get(opts, :ttl_ms, 3_600_000),
      poll_interval_ms: Keyword.get(opts, :poll_interval_ms, 250),
      status_message: Keyword.get(opts, :status_message)
    }

    validate!(task)
  end

  @spec terminal?(t()) :: boolean()
  def terminal?(%__MODULE__{status: status}), do: status in @terminal

  @spec add_input(t(), String.t(), map(), String.t()) ::
          {:ok, t()} | {:error, :duplicate_input_key | :terminal | :invalid_input_request}
  def add_input(%__MODULE__{} = task, key, request, now)
      when is_binary(key) and key != "" and is_map(request) and is_binary(now) do
    cond do
      terminal?(task) ->
        {:error, :terminal}

      MapSet.member?(task.used_input_keys, key) ->
        {:error, :duplicate_input_key}

      not valid_input_request?(request) ->
        {:error, :invalid_input_request}

      true ->
        {:ok,
         %{
           task
           | status: :input_required,
             input_requests: Map.put(task.input_requests, key, request),
             used_input_keys: MapSet.put(task.used_input_keys, key),
             last_updated_at: now
         }}
    end
  end

  def add_input(%__MODULE__{}, _key, _request, _now), do: {:error, :invalid_input_request}

  @spec fulfill_inputs(t(), [String.t()], String.t()) :: {:ok, t(), [String.t()]}
  def fulfill_inputs(%__MODULE__{} = task, keys, now)
      when is_list(keys) and is_binary(now) do
    matched = Enum.filter(keys, &Map.has_key?(task.input_requests, &1))

    if matched == [] or terminal?(task) do
      {:ok, task, []}
    else
      remaining = Map.drop(task.input_requests, matched)
      status = if map_size(remaining) == 0, do: :working, else: :input_required

      {:ok,
       %{
         task
         | status: status,
           input_requests: remaining,
           last_updated_at: now
       }, matched}
    end
  end

  @spec complete(t(), map(), String.t()) :: {:ok, t()} | {:terminal, t()}
  def complete(%__MODULE__{} = task, result, now)
      when is_map(result) and is_binary(now) do
    transition_terminal(task, :completed, now, result: result)
  end

  @spec fail(t(), map(), String.t(), String.t() | nil) :: {:ok, t()} | {:terminal, t()}
  def fail(%__MODULE__{} = task, error, now, status_message \\ nil)
      when is_map(error) and is_binary(now) do
    transition_terminal(task, :failed, now, error: error, status_message: status_message)
  end

  @spec cancel(t(), String.t(), String.t() | nil) :: {:ok, t()} | {:terminal, t()}
  def cancel(%__MODULE__{} = task, now, status_message \\ nil) when is_binary(now) do
    transition_terminal(task, :cancelled, now, status_message: status_message)
  end

  @doc "Returns the flat SEP-2663 creation result, without detailed payload fields."
  @spec creation_result(t()) :: map()
  def creation_result(%__MODULE__{} = task) do
    task
    |> base_wire()
    |> Map.put("resultType", "task")
  end

  @doc "Returns the flat status-specific `tasks/get` result."
  @spec detailed_result(t()) :: map()
  def detailed_result(%__MODULE__{} = task) do
    task
    |> notification_params()
    |> Map.put("resultType", "complete")
  end

  @doc "Returns the complete status-specific payload for `notifications/tasks`."
  @spec notification_params(t()) :: map()
  def notification_params(%__MODULE__{} = task) do
    task
    |> validate!()
    |> base_wire()
    |> put_detailed_payload(task)
  end

  @doc "Returns an RFC 3339/ISO 8601 UTC timestamp at millisecond precision."
  @spec timestamp() :: String.t()
  def timestamp do
    DateTime.utc_now()
    |> DateTime.truncate(:millisecond)
    |> DateTime.to_iso8601()
  end

  @doc false
  @spec validate!(t()) :: t()
  def validate!(%__MODULE__{} = task) do
    validate_identity!(task)
    validate_timestamps!(task)
    validate_timing_options!(task)
    validate_inputs!(task)
    validate_result_payloads!(task)
    validate_status_payload!(task)
    task
  end

  @doc false
  @spec valid_input_request?(term()) :: boolean()
  def valid_input_request?(%{"method" => method} = request)
      when is_binary(method) and method != "" do
    JSONValue.valid?(request)
  end

  def valid_input_request?(_request), do: false

  @doc false
  @spec valid_timestamp?(term()) :: boolean()
  def valid_timestamp?(value) when is_binary(value) do
    match?({:ok, _datetime, _offset}, DateTime.from_iso8601(value))
  end

  def valid_timestamp?(_value), do: false

  defp validate_identity!(task) do
    unless is_binary(task.id) and task.id != "" do
      raise ArgumentError, "task id must be a non-empty string"
    end

    unless task.status in [:working, :input_required, :completed, :failed, :cancelled] do
      raise ArgumentError, "task status is invalid"
    end

    unless is_nil(task.status_message) or is_binary(task.status_message) do
      raise ArgumentError, "task status_message must be a string or nil"
    end
  end

  defp validate_timestamps!(task) do
    unless valid_timestamp?(task.created_at) and valid_timestamp?(task.last_updated_at) do
      raise ArgumentError, "task timestamps must be ISO 8601 strings"
    end

    unless timestamp_ordered?(task.created_at, task.last_updated_at) do
      raise ArgumentError, "task last_updated_at cannot precede created_at"
    end
  end

  defp validate_timing_options!(task) do
    unless is_nil(task.ttl_ms) or (is_integer(task.ttl_ms) and task.ttl_ms > 0) do
      raise ArgumentError, "task ttl_ms must be nil or a positive integer"
    end

    unless is_nil(task.poll_interval_ms) or
             (is_integer(task.poll_interval_ms) and task.poll_interval_ms > 0) do
      raise ArgumentError, "task poll_interval_ms must be nil or a positive integer"
    end
  end

  defp validate_inputs!(task) do
    unless valid_input_requests?(task.input_requests) do
      raise ArgumentError, "task input_requests must contain valid, JSON-safe requests"
    end

    unless match?(%MapSet{}, task.used_input_keys) and
             Enum.all?(task.used_input_keys, &(is_binary(&1) and &1 != "")) do
      raise ArgumentError, "task used_input_keys must be a set of non-empty strings"
    end

    unless Enum.all?(Map.keys(task.input_requests), &MapSet.member?(task.used_input_keys, &1)) do
      raise ArgumentError, "task input request keys must be present in used_input_keys"
    end
  end

  defp validate_result_payloads!(task) do
    unless is_nil(task.result) or (is_map(task.result) and JSONValue.valid?(task.result)) do
      raise ArgumentError, "task result must be a JSON-safe object or nil"
    end

    unless is_nil(task.error) or (is_map(task.error) and JSONValue.valid?(task.error)) do
      raise ArgumentError, "task error must be a JSON-safe object or nil"
    end
  end

  defp transition_terminal(%__MODULE__{} = task, status, now, attrs) do
    if terminal?(task) do
      {:terminal, task}
    else
      {:ok,
       %{
         task
         | status: status,
           status_message: Keyword.get(attrs, :status_message),
           last_updated_at: now,
           input_requests: %{},
           result: Keyword.get(attrs, :result),
           error: Keyword.get(attrs, :error)
       }}
    end
  end

  defp base_wire(task) do
    %{
      "taskId" => task.id,
      "status" => Atom.to_string(task.status),
      "createdAt" => task.created_at,
      "lastUpdatedAt" => task.last_updated_at,
      "ttlMs" => task.ttl_ms
    }
    |> maybe_put("statusMessage", task.status_message)
    |> maybe_put("pollIntervalMs", task.poll_interval_ms)
  end

  defp put_detailed_payload(wire, %__MODULE__{status: :input_required} = task) do
    Map.put(wire, "inputRequests", task.input_requests)
  end

  defp put_detailed_payload(wire, %__MODULE__{status: :completed} = task) do
    Map.put(wire, "result", task.result || %{})
  end

  defp put_detailed_payload(wire, %__MODULE__{status: :failed} = task) do
    Map.put(wire, "error", task.error || %{"code" => -32_603, "message" => "Internal error"})
  end

  defp put_detailed_payload(wire, %__MODULE__{}), do: wire

  defp valid_input_requests?(requests) when is_map(requests) do
    Enum.all?(requests, fn
      {key, request} when is_binary(key) and key != "" -> valid_input_request?(request)
      _invalid -> false
    end)
  end

  defp valid_input_requests?(_requests), do: false

  defp timestamp_ordered?(created_at, last_updated_at) do
    with {:ok, created, _offset} <- DateTime.from_iso8601(created_at),
         {:ok, updated, _offset} <- DateTime.from_iso8601(last_updated_at) do
      DateTime.compare(created, updated) in [:lt, :eq]
    else
      _invalid -> false
    end
  end

  defp validate_status_payload!(%__MODULE__{status: :working} = task) do
    require_empty_inputs!(task)
    require_no_terminal_payload!(task)
  end

  defp validate_status_payload!(%__MODULE__{status: :input_required} = task) do
    if map_size(task.input_requests) == 0 do
      raise ArgumentError, "input_required tasks must contain at least one input request"
    end

    require_no_terminal_payload!(task)
  end

  defp validate_status_payload!(%__MODULE__{status: :completed} = task) do
    require_empty_inputs!(task)

    unless is_map(task.result) and is_nil(task.error) do
      raise ArgumentError, "completed tasks require a result and cannot contain an error"
    end
  end

  defp validate_status_payload!(%__MODULE__{status: :failed} = task) do
    require_empty_inputs!(task)

    unless is_map(task.error) and is_nil(task.result) do
      raise ArgumentError, "failed tasks require an error and cannot contain a result"
    end
  end

  defp validate_status_payload!(%__MODULE__{status: :cancelled} = task) do
    require_empty_inputs!(task)
    require_no_terminal_payload!(task)
  end

  defp require_empty_inputs!(task) do
    unless map_size(task.input_requests) == 0 do
      raise ArgumentError, "only input_required tasks may contain input requests"
    end
  end

  defp require_no_terminal_payload!(task) do
    unless is_nil(task.result) and is_nil(task.error) do
      raise ArgumentError, "non-result task states cannot contain a result or error"
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
