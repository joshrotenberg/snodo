defmodule Snodo.Resource.Definition do
  @moduledoc "Protocol-neutral definition of a direct resource or resource template."

  @type kind :: :resource | :template
  @type t :: %__MODULE__{
          kind: kind(),
          uri: String.t() | nil,
          uri_template: String.t() | nil,
          name: String.t(),
          title: String.t() | nil,
          description: String.t() | nil,
          mime_type: String.t() | nil,
          size: non_neg_integer() | nil,
          completion_arguments: [String.t()],
          icons: [map()],
          annotations: map(),
          metadata: map()
        }

  @enforce_keys [:kind, :name]
  defstruct [
    :kind,
    :uri,
    :uri_template,
    :name,
    :title,
    :description,
    :mime_type,
    :size,
    completion_arguments: [],
    icons: [],
    annotations: %{},
    metadata: %{}
  ]
end
