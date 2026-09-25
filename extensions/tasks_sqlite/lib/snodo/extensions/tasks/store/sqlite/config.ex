defmodule Snodo.Extensions.Tasks.Store.SQLite.Config do
  @moduledoc false

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
