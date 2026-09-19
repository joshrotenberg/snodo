defmodule MCP.Schema.Validator.JSV.Compiled do
  @moduledoc "An opaque, immutable validation root compiled under the adapter's policy."

  @opaque t :: %__MODULE__{root: JSV.Root.t()}
  @enforce_keys [:root]
  defstruct [:root]
end
