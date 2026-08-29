defmodule MCP.Compliance.QuietFormatter do
  @moduledoc false

  use GenServer

  @impl true
  def init(_opts), do: {:ok, nil}

  @impl true
  def handle_cast(_event, state), do: {:noreply, state}

  @impl true
  def handle_call(_request, _from, state), do: {:reply, :ok, state}

  @impl true
  def handle_info(_message, state), do: {:noreply, state}
end
