defmodule Snodo.Tool.Definition do
  @moduledoc "Protocol-neutral static definition of an application tool."

  @type t :: %__MODULE__{
          name: String.t(),
          description: String.t() | nil,
          input_schema: map(),
          output_schema: map() | nil,
          annotations: map()
        }

  @enforce_keys [:name, :input_schema]
  defstruct [:name, :description, :input_schema, :output_schema, annotations: %{}]
end
