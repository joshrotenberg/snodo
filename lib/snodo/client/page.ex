defmodule Snodo.Client.Page do
  @moduledoc """
  One page of a list operation returned by `Snodo.Client.list_page/3`.

  `items` holds the listed definitions exactly as the server sent them.
  `next_cursor` is `nil` on the last page. `result` is the whole JSON-RPC
  `result` object, including cache hints and `_meta`.
  """

  @type t :: %__MODULE__{
          items: [map()],
          next_cursor: String.t() | nil,
          result: map()
        }

  @enforce_keys [:items, :result]
  defstruct [:items, :next_cursor, :result]
end
