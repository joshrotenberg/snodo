defmodule MCPEx.ComplianceCase do
  @moduledoc false

  @enforce_keys [:id, :spec_ref, :transports, :request, :expected]
  defstruct [:id, :spec_ref, :transports, :request, :expected]
end
