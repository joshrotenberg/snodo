defmodule MCP.Transport do
  @moduledoc "Behaviour for long-lived transport adapters."

  @callback start_link(keyword()) :: GenServer.on_start()
end
