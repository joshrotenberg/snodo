defmodule MCPEx.Conformance.Progress.Tool do
  @moduledoc false
  use MCP.Tool,
    name: "test_tool_with_progress",
    description: "Reports three real computation stages before returning their result"

  @impl true
  def call(_arguments, context) do
    :ok = MCP.Progress.report(context, 0, total: 100, message: "Starting computation")
    first_half = Enum.sum(1..50)
    :ok = MCP.Progress.report(context, 50, total: 100, message: "First half complete")
    result = first_half + Enum.sum(51..100)
    :ok = MCP.Progress.report(context, 100, total: 100, message: "Computation complete")
    {:ok, MCP.Result.text("Progress computation completed: #{result}")}
  end
end
