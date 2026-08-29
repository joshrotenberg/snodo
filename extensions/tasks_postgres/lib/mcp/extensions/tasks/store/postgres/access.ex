defmodule MCP.Extensions.Tasks.Store.Postgres.Access do
  @moduledoc false

  @derive {Inspect, only: [:action]}
  @enforce_keys [:store_identity, :scope, :encoded_scope, :action]
  defstruct [:store_identity, :scope, :encoded_scope, :action]
end
