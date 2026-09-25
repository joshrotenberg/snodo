defmodule Snodo.Extension.Route do
  @moduledoc "A resolved request route owned by one installed extension."

  alias Snodo.Extension.Method

  @type t :: %__MODULE__{
          extension_id: String.t(),
          module: module(),
          method: Method.t()
        }

  @enforce_keys [:extension_id, :module, :method]
  defstruct [:extension_id, :module, :method]
end
