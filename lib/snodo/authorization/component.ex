defmodule Snodo.Authorization.Component do
  @moduledoc """
  The identity of one registered router component shown to an authorization policy.

  `name` is the registered component name, which the router keeps unique within
  each catalog. `uri` carries the exact registered resource URI or resource URI
  template and is `nil` for tools and prompts. `requested_uri` carries the
  concrete URI for a resource-template read or subscription read check. It is
  `nil` during discovery and template completion, where no concrete resource
  URI was requested. A policy may key on these fields; new fields are additive,
  so match with a map pattern rather than positionally.
  """

  @type kind :: :tool | :prompt | :resource | :resource_template

  @type t :: %__MODULE__{
          kind: kind(),
          name: String.t(),
          uri: String.t() | nil,
          requested_uri: String.t() | nil
        }

  @enforce_keys [:kind, :name]
  defstruct [:kind, :name, :uri, :requested_uri]
end
