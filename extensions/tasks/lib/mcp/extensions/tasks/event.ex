defmodule MCP.Extensions.Tasks.Event do
  @moduledoc """
  A validated, versioned state-transition intent for a protocol Task.

  Events contain data only. They can cross a process, database, or remote-store
  boundary without asking the store to execute application closures. Event IDs
  are stable across compare-and-set retries; idempotency remains the store's
  responsibility.
  """

  alias MCP.Extensions.Tasks.Task, as: ProtocolTask
  alias MCP.JSONValue

  @version 1
  @kinds [
    :input_requested,
    :input_responses_accepted,
    :retry_requested,
    :completed,
    :failed,
    :cancelled
  ]

  @type kind ::
          :input_requested
          | :input_responses_accepted
          | :retry_requested
          | :completed
          | :failed
          | :cancelled

  @type t :: %__MODULE__{
          id: String.t(),
          version: pos_integer(),
          kind: kind(),
          data: map()
        }

  @enforce_keys [:id, :version, :kind, :data]
  defstruct [:id, :version, :kind, :data]

  @spec input_requested(String.t(), map(), keyword()) :: {:ok, t()} | {:error, term()}
  def input_requested(key, request, opts \\ []) do
    build(:input_requested, %{"key" => key, "request" => request}, opts)
  end

  @spec input_responses_accepted(map(), keyword()) :: {:ok, t()} | {:error, term()}
  def input_responses_accepted(responses, opts \\ []) do
    build(:input_responses_accepted, %{"responses" => responses}, opts)
  end

  @doc "Requests the next persisted retry delay or terminal failure on exhaustion."
  @spec retry_requested(map(), String.t() | nil, keyword()) :: {:ok, t()} | {:error, term()}
  def retry_requested(error, status_message, opts \\ []) do
    build(
      :retry_requested,
      %{"error" => error, "statusMessage" => status_message},
      opts
    )
  end

  @spec completed(map(), keyword()) :: {:ok, t()} | {:error, term()}
  def completed(result, opts \\ []) do
    build(:completed, %{"result" => result}, opts)
  end

  @spec failed(map(), String.t() | nil, keyword()) :: {:ok, t()} | {:error, term()}
  def failed(error, status_message, opts \\ []) do
    build(
      :failed,
      %{"error" => error, "statusMessage" => status_message},
      opts
    )
  end

  @spec cancelled(keyword()) :: {:ok, t()} | {:error, term()}
  def cancelled(opts \\ []) do
    build(:cancelled, %{}, opts)
  end

  @doc "Validates an event constructed locally or by an adapter."
  @spec validate(t()) :: :ok | {:error, term()}
  def validate(%__MODULE__{} = event) do
    cond do
      event.version != @version ->
        {:error, {:unsupported_event_version, event.version}}

      not (is_binary(event.id) and event.id != "") ->
        {:error, :invalid_event_id}

      event.kind not in @kinds ->
        {:error, {:unsupported_event_kind, event.kind}}

      not is_map(event.data) ->
        {:error, :invalid_event_data}

      true ->
        validate_data(event.kind, event.data)
    end
  end

  def validate(_event), do: {:error, :invalid_event}

  @doc "Encodes an event as a stable JSON-safe persistence map."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = event) do
    case validate(event) do
      :ok ->
        %{
          "version" => event.version,
          "id" => event.id,
          "kind" => Atom.to_string(event.kind),
          "data" => event.data
        }

      {:error, reason} ->
        raise ArgumentError, "cannot encode invalid task event: #{inspect(reason)}"
    end
  end

  @doc "Decodes and validates a persistence map produced by `to_map/1`."
  @spec from_map(term()) :: {:ok, t()} | {:error, term()}
  def from_map(
        %{
          "version" => version,
          "id" => id,
          "kind" => kind,
          "data" => data
        } = encoded
      )
      when map_size(encoded) == 4 do
    with {:ok, decoded_kind} <- decode_kind(kind),
         event = %__MODULE__{id: id, version: version, kind: decoded_kind, data: data},
         :ok <- validate(event) do
      {:ok, event}
    end
  end

  def from_map(_encoded), do: {:error, :invalid_event_encoding}

  @spec generate_id() :: String.t()
  def generate_id do
    18
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end

  defp build(kind, data, opts) when is_list(opts) do
    with :ok <- validate_options(opts),
         event = %__MODULE__{
           id: Keyword.get_lazy(opts, :id, &generate_id/0),
           version: @version,
           kind: kind,
           data: data
         },
         :ok <- validate(event) do
      {:ok, event}
    end
  end

  defp build(_kind, _data, _opts), do: {:error, :invalid_event_options}

  defp validate_options(opts) do
    if Keyword.keyword?(opts) and Keyword.keys(opts) -- [:id] == [] do
      :ok
    else
      {:error, :invalid_event_options}
    end
  end

  defp validate_data(:input_requested, %{"key" => key, "request" => request} = data)
       when map_size(data) == 2 do
    cond do
      not (is_binary(key) and key != "") -> {:error, :invalid_input_key}
      not ProtocolTask.valid_input_request?(request) -> {:error, :invalid_input_request}
      true -> :ok
    end
  end

  defp validate_data(:input_responses_accepted, %{"responses" => responses} = data)
       when map_size(data) == 1 do
    if valid_input_responses?(responses),
      do: :ok,
      else: {:error, :invalid_input_responses}
  end

  defp validate_data(:completed, %{"result" => result} = data) when map_size(data) == 1 do
    if is_map(result) and JSONValue.valid?(result),
      do: :ok,
      else: {:error, :invalid_task_result}
  end

  defp validate_data(
         :retry_requested,
         %{"error" => error, "statusMessage" => status_message} = data
       )
       when map_size(data) == 2 do
    validate_failure_data(error, status_message)
  end

  defp validate_data(
         :failed,
         %{"error" => error, "statusMessage" => status_message} = data
       )
       when map_size(data) == 2 do
    validate_failure_data(error, status_message)
  end

  defp validate_data(:cancelled, data) when map_size(data) == 0, do: :ok
  defp validate_data(_kind, _data), do: {:error, :invalid_event_data}

  defp valid_input_responses?(responses) when is_map(responses) do
    JSONValue.valid?(responses) and
      Enum.all?(responses, fn
        {key, response} when is_binary(key) and key != "" -> is_map(response)
        _invalid -> false
      end)
  end

  defp valid_input_responses?(_responses), do: false

  defp decode_kind(kind) when is_binary(kind) do
    case kind do
      "input_requested" -> {:ok, :input_requested}
      "input_responses_accepted" -> {:ok, :input_responses_accepted}
      "retry_requested" -> {:ok, :retry_requested}
      "completed" -> {:ok, :completed}
      "failed" -> {:ok, :failed}
      "cancelled" -> {:ok, :cancelled}
      _unknown -> {:error, {:unsupported_event_kind, kind}}
    end
  end

  defp decode_kind(kind), do: {:error, {:unsupported_event_kind, kind}}

  defp validate_failure_data(error, status_message) do
    cond do
      not (is_map(error) and JSONValue.valid?(error)) ->
        {:error, :invalid_task_error}

      not (is_nil(status_message) or is_binary(status_message)) ->
        {:error, :invalid_status_message}

      true ->
        :ok
    end
  end
end
