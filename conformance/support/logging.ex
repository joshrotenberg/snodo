defmodule SnodoTest.Conformance.Logging.Tool do
  @moduledoc false
  use Snodo.Tool,
    name: "test_tool_with_logging",
    description: "Sends three info log messages, 50 ms apart, before returning"

  @impl true
  def call(_arguments, context) do
    :ok = Snodo.Logging.log(context, :info, "Tool execution started")
    Process.sleep(50)
    :ok = Snodo.Logging.log(context, :info, "Tool processing data")
    Process.sleep(50)
    :ok = Snodo.Logging.log(context, :info, "Tool execution completed")
    {:ok, Snodo.Result.text("Logging tool completed")}
  end
end
