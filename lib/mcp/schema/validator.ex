defmodule MCP.Schema.Validator do
  @moduledoc """
  Pluggable JSON Schema validation boundary.

  Validators receive the untouched schema map registered by the application.
  Returning `{:error, reason}` marks an instance invalid; validators must not
  mutate either the instance or schema.

  `MCP.Schema.Validator.Basic` is the dependency-free common-subset
  implementation. `MCP.Schema.Validator.Passthrough` remains the runtime
  default so selecting validation is an explicit application policy.
  """

  @callback validate(instance :: term(), schema :: map()) :: :ok | {:error, term()}
end

defmodule MCP.Schema.Validator.Passthrough do
  @moduledoc "Default validator used when an application has not installed a backend."

  @behaviour MCP.Schema.Validator

  @impl true
  def validate(_instance, _schema), do: :ok
end
