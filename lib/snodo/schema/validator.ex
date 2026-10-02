defmodule Snodo.Schema.Validator do
  @moduledoc """
  Pluggable JSON Schema validation boundary.

  Validators receive the untouched schema map registered by the application.
  Returning `{:error, reason}` marks an instance invalid; validators must not
  mutate either the instance or schema.

  `Snodo.Schema.Validator.Basic` is the dependency-free common-subset
  implementation. `Snodo.Schema.Validator.Passthrough` remains the runtime
  default so selecting validation is an explicit application policy.

  Validators may implement `compile/1` and `validate_compiled/2`. A server
  runtime prepares its registered tool schemas once and retains the compiled
  results for that runtime's lifetime. Build errors are returned at validation
  time as server errors, as they are for a validator that only implements
  `validate/2`. The error reason may be any term and is kept in the server's
  internal error cause, not sent to the client.
  """

  @callback validate(instance :: term(), schema :: map()) :: :ok | {:error, term()}

  @callback compile(schema :: map()) :: {:ok, term()} | {:error, term()}
  @callback validate_compiled(instance :: term(), compiled :: term()) :: :ok | {:error, term()}

  @optional_callbacks compile: 1, validate_compiled: 2
end

defmodule Snodo.Schema.Validator.Passthrough do
  @moduledoc "Default validator used when an application has not installed a backend."

  @behaviour Snodo.Schema.Validator

  @impl true
  def validate(_instance, _schema), do: :ok
end
