defmodule Snodo.Extensions.Tasks.Store.Postgres.Config do
  @moduledoc """
  The store handle that `Snodo.Extensions.Tasks.Store.Postgres.new/1` returns and
  the other store functions take. Build it with `new/1` or `new!/1`; its fields
  are internal.
  """

  @type t :: %__MODULE__{
          repo: module(),
          prefix: String.t() | nil,
          scope: (Snodo.Context.t() -> term()),
          timeout: pos_integer(),
          lock_timeout_ms: pos_integer(),
          reap_batch_size: pos_integer(),
          max_tasks: pos_integer() | :infinity,
          max_active_tasks_per_scope: pos_integer() | :infinity,
          identity: reference()
        }

  @enforce_keys [
    :repo,
    :scope,
    :timeout,
    :lock_timeout_ms,
    :reap_batch_size,
    :max_tasks,
    :max_active_tasks_per_scope,
    :identity
  ]
  defstruct [
    :repo,
    :prefix,
    :scope,
    :timeout,
    :lock_timeout_ms,
    :reap_batch_size,
    :max_tasks,
    :max_active_tasks_per_scope,
    :identity
  ]
end
