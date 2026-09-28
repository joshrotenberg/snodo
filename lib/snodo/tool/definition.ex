defmodule Snodo.Tool.Definition do
  @moduledoc "Protocol-neutral static definition of an application tool."

  @type t :: %__MODULE__{
          name: String.t(),
          title: String.t() | nil,
          description: String.t() | nil,
          input_schema: map(),
          output_schema: map() | nil,
          annotations: map(),
          icons: [map()],
          metadata: map()
        }

  @enforce_keys [:name, :input_schema]
  defstruct [
    :name,
    :title,
    :description,
    :input_schema,
    :output_schema,
    annotations: %{},
    icons: [],
    metadata: %{}
  ]
end
