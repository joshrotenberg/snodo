defmodule Snodo.Extensions.Tasks.WorkExecutor do
  @moduledoc """
  Application-owned execution boundary for serializable task work.

  The durable record contains a `Snodo.Extensions.Tasks.Work` value rather than a
  process-local function. A runner resolves that value through a configured
  executor after every initial claim or recovery claim. Executor configuration
  uses `{module, state}` so applications can rebuild runtime state when their
  supervision tree restarts without placing it in the descriptor.

  `{:failed, error, status_message}` is terminal. An executor opts into the
  descriptor's next persisted retry delay only by returning
  `{:retry, error, status_message}`. Exceptions, exits, and invalid outcomes
  are returned as invocation errors so the runner can fail closed.
  """

  alias Snodo.Cancellation
  alias Snodo.Extensions.Tasks.Work

  @type ref :: {module(), term()}
  @type outcome ::
          {:completed, map()}
          | {:failed, map(), String.t() | nil}
          | {:retry, map(), String.t() | nil}

  @callback execute(Work.t(), Cancellation.t(), state :: term()) :: outcome()

  @doc "Validates an executor reference and returns it unchanged."
  @spec validate_ref!(term()) :: ref()
  def validate_ref!({module, _state} = ref) when is_atom(module) do
    case Code.ensure_loaded(module) do
      {:module, ^module} ->
        :ok

      _missing ->
        raise ArgumentError, "work executor module #{inspect(module)} could not be loaded"
    end

    unless function_exported?(module, :execute, 3) do
      raise ArgumentError,
            "work executor module #{inspect(module)} does not export execute/3"
    end

    ref
  end

  def validate_ref!(_invalid) do
    raise ArgumentError, "work executor must be a {module, state} tuple"
  end

  @doc "Safely invokes an executor and validates its runner-compatible outcome."
  @spec invoke(ref(), Work.t(), Cancellation.t()) :: {:ok, outcome()} | {:error, term()}
  def invoke({module, state} = executor, %Work{} = work, %Cancellation{} = cancellation)
      when is_atom(module) do
    _validated = validate_ref!(executor)

    module.execute(work, cancellation, state)
    |> normalize_outcome()
  rescue
    exception -> {:error, {:executor_exception, exception, __STACKTRACE__}}
  catch
    kind, reason -> {:error, {:executor_exit, kind, reason, __STACKTRACE__}}
  end

  def invoke(_executor, _work, _cancellation), do: {:error, :invalid_executor_invocation}

  defp normalize_outcome({:completed, result} = outcome) when is_map(result),
    do: {:ok, outcome}

  defp normalize_outcome({:failed, error, status_message} = outcome)
       when is_map(error) and (is_binary(status_message) or is_nil(status_message)),
       do: {:ok, outcome}

  defp normalize_outcome({:retry, error, status_message} = outcome)
       when is_map(error) and (is_binary(status_message) or is_nil(status_message)),
       do: {:ok, outcome}

  defp normalize_outcome(other), do: {:error, {:invalid_executor_return, other}}
end
