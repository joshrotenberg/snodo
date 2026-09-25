defmodule Snodo.Authorization.Component do
  @moduledoc """
  The identity of one registered router component shown to an authorization policy.

  `name` is the registered component name, which the router keeps unique within
  each catalog. `uri` carries the exact registered resource URI or resource URI
  template and is `nil` for tools and prompts. A policy may key on either, and
  new fields are additive, so match with a map pattern rather than positionally.
  """

  @type kind :: :tool | :prompt | :resource | :resource_template

  @type t :: %__MODULE__{
          kind: kind(),
          name: String.t(),
          uri: String.t() | nil
        }

  @enforce_keys [:kind, :name]
  defstruct [:kind, :name, :uri]
end
