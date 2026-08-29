defmodule MCP.Extensions.Tasks.Store.Postgres.Lease do
  @moduledoc false

  @derive {Inspect, only: [:task_id, :owner_id, :generation, :expires_at]}
  @enforce_keys [
    :store_identity,
    :task_id,
    :owner_id,
    :token,
    :generation,
    :expires_at
  ]
  defstruct [
    :store_identity,
    :task_id,
    :owner_id,
    :token,
    :generation,
    :expires_at
  ]
end
