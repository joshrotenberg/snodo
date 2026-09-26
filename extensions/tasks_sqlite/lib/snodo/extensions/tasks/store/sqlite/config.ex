defmodule Snodo.Extensions.Tasks.Store.SQLite.Config do
  @moduledoc """
  The store handle that `Snodo.Extensions.Tasks.Store.SQLite.new/1` returns and
  the other store functions take. Build it with `new/1` or `new!/1`; its fields
  are internal.
  """

  @type t :: %__MODULE__{
          repo: module(),
          scope: (Snodo.Context.t() -> term()),
          timeout: pos_integer(),
          reap_batch_size: pos_integer(),
          identity: reference()
        }

  @enforce_keys [:repo, :scope, :timeout, :reap_batch_size, :identity]
  defstruct [:repo, :scope, :timeout, :reap_batch_size, :identity]
end
