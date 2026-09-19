defmodule MCP.Schema.Validator.JSV.OfflineResolver do
  @moduledoc false
  @behaviour JSV.Resolver

  alias MCP.Schema.Validator.JSV.BuildError

  @impl true
  def resolve(uri, options) do
    case JSV.Resolver.Embedded.resolve(uri, options) do
      {:normal, schema} -> {:normal, schema}
      {:error, _reason} -> raise BuildError, reason: {:unresolved_reference, uri}
    end
  end
end
