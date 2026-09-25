defmodule Snodo.Schema.Validator.JSV.BuildError do
  @moduledoc "A schema or adapter policy failure, distinct from invalid instance data."

  @type t :: %__MODULE__{reason: term()}
  defexception [:reason]

  @impl true
  def message(_error), do: "JSON Schema could not be compiled by the configured validator"
end
