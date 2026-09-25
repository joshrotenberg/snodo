defmodule Snodo.Extensions.Tasks.Store.Postgres.Config do
  @moduledoc false

  @type t :: %__MODULE__{
          repo: module(),
          prefix: String.t() | nil,
          scope: (Snodo.Context.t() -> term()),
          timeout: pos_integer(),
          lock_timeout_ms: pos_integer(),
          reap_batch_size: pos_integer(),
          identity: reference()
        }

  @enforce_keys [
    :repo,
    :scope,
    :timeout,
    :lock_timeout_ms,
    :reap_batch_size,
    :identity
  ]
  defstruct [
    :repo,
    :prefix,
    :scope,
    :timeout,
    :lock_timeout_ms,
    :reap_batch_size,
    :identity
  ]
end
