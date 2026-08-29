defmodule MCP.Extensions.Tasks.Work do
  @moduledoc """
  A versioned, JSON-safe description of restartable task work.

  Work descriptors contain data only. The `type` selects an application-owned
  executor and the `idempotency_key` remains stable across claims, process
  restarts, and execution retries. The immutable retry policy is expanded to
  exact delays before persistence, so an in-flight task does not change policy
  when application configuration changes. Applications should use the stable
  key when making externally visible side effects idempotent.
  """

  alias MCP.Extensions.Tasks.RetryPolicy
  alias MCP.JSONValue

  @version 2

  @type t :: %__MODULE__{
          idempotency_key: String.t(),
          type: String.t(),
          input: map(),
          retry_policy: RetryPolicy.t()
        }

  @enforce_keys [:idempotency_key, :type, :input]
  defstruct [:idempotency_key, :type, :input, retry_policy: %RetryPolicy{delays_ms: []}]

  @doc "Builds a validated application-defined work descriptor."
  @spec new(String.t(), String.t(), map(), keyword()) :: {:ok, t()} | {:error, term()}
  def new(idempotency_key, type, input, opts \\ []) do
    with :ok <- validate_options(opts) do
      work = %__MODULE__{
        idempotency_key: idempotency_key,
        type: type,
        input: input,
        retry_policy: Keyword.get(opts, :retry_policy, RetryPolicy.none())
      }

      case validate(work) do
        :ok -> {:ok, work}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc "Builds a validated work descriptor or raises `ArgumentError`."
  @spec new!(String.t(), String.t(), map(), keyword()) :: t()
  def new!(idempotency_key, type, input, opts \\ []) do
    case new(idempotency_key, type, input, opts) do
      {:ok, work} -> work
      {:error, reason} -> raise ArgumentError, "invalid task work: #{inspect(reason)}"
    end
  end

  @doc "Builds the standard descriptor for a durable `tools/call` invocation."
  @spec tool_call(String.t(), String.t(), map(), keyword()) ::
          {:ok, t()} | {:error, term()}
  def tool_call(idempotency_key, tool_name, arguments, opts \\ []) do
    cond do
      not non_empty_string?(tool_name) ->
        {:error, :invalid_tool_name}

      not is_map(arguments) ->
        {:error, :invalid_tool_arguments}

      true ->
        new(
          idempotency_key,
          "tools/call",
          %{"name" => tool_name, "arguments" => arguments},
          opts
        )
    end
  end

  @doc "Returns the descriptor with a validated immutable retry policy."
  @spec put_retry_policy(t(), RetryPolicy.t()) :: {:ok, t()} | {:error, term()}
  def put_retry_policy(%__MODULE__{} = work, %RetryPolicy{} = retry_policy) do
    updated = %{work | retry_policy: retry_policy}

    case validate(updated) do
      :ok -> {:ok, updated}
      {:error, reason} -> {:error, reason}
    end
  end

  def put_retry_policy(_work, _retry_policy), do: {:error, :invalid_retry_policy}

  @doc "Validates a descriptor constructed locally or decoded by an adapter."
  @spec validate(t()) :: :ok | {:error, term()}
  def validate(%__MODULE__{} = work) do
    cond do
      not non_empty_string?(work.idempotency_key) ->
        {:error, :invalid_work_idempotency_key}

      not non_empty_string?(work.type) ->
        {:error, :invalid_work_type}

      not (is_map(work.input) and JSONValue.valid?(work.input)) ->
        {:error, :invalid_work_input}

      RetryPolicy.validate(work.retry_policy) != :ok ->
        {:error, :invalid_work_retry_policy}

      true ->
        :ok
    end
  end

  def validate(_work), do: {:error, :invalid_work}

  @doc "Encodes a descriptor as a stable JSON-safe persistence map."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = work) do
    case validate(work) do
      :ok ->
        %{
          "version" => @version,
          "idempotencyKey" => work.idempotency_key,
          "type" => work.type,
          "input" => work.input,
          "retryPolicy" => RetryPolicy.to_map(work.retry_policy)
        }

      {:error, reason} ->
        raise ArgumentError, "cannot encode invalid task work: #{inspect(reason)}"
    end
  end

  @doc "Decodes and validates a persistence map produced by `to_map/1`."
  @spec from_map(term()) :: {:ok, t()} | {:error, term()}
  def from_map(
        %{
          "version" => @version,
          "idempotencyKey" => idempotency_key,
          "type" => type,
          "input" => input,
          "retryPolicy" => encoded_retry_policy
        } = encoded
      )
      when map_size(encoded) == 5 do
    with {:ok, retry_policy} <- RetryPolicy.from_map(encoded_retry_policy) do
      new(idempotency_key, type, input, retry_policy: retry_policy)
    end
  end

  def from_map(%{"version" => version}) when version != @version do
    {:error, {:unsupported_work_version, version}}
  end

  def from_map(_encoded), do: {:error, :invalid_work_encoding}

  defp non_empty_string?(value), do: is_binary(value) and value != ""

  defp validate_options(opts) do
    if Keyword.keyword?(opts) and Keyword.keys(opts) -- [:retry_policy] == [] do
      :ok
    else
      {:error, :invalid_work_options}
    end
  end
end
