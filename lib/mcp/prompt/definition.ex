defmodule MCP.Prompt.Definition do
  @moduledoc "Protocol-neutral definition of an MCP prompt template."

  @type t :: %__MODULE__{
          name: String.t(),
          title: String.t() | nil,
          description: String.t() | nil,
          arguments: [map()],
          completion_arguments: [String.t()],
          icons: [map()],
          metadata: map()
        }

  @enforce_keys [:name]
  defstruct [
    :name,
    :title,
    :description,
    arguments: [],
    completion_arguments: [],
    icons: [],
    metadata: %{}
  ]
end
