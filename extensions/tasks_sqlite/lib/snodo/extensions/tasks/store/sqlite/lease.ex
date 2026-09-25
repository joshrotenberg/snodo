defmodule Snodo.Extensions.Tasks.Store.SQLite.Lease do
  @moduledoc false

  @derive {Inspect, only: [:task_id, :owner_id, :generation, :expires_at_us]}
  @enforce_keys [
    :store_identity,
    :task_id,
    :owner_id,
    :token,
    :generation,
    :expires_at_us
  ]
  defstruct [
    :store_identity,
    :task_id,
    :owner_id,
    :token,
    :generation,
    :expires_at_us
  ]
end
