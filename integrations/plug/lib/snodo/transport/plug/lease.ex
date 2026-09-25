defmodule Snodo.Transport.Plug.Lease do
  @moduledoc false

  # Plug server processes can serve more than one request. A separate short-lived
  # reply owner makes executor/subscription cleanup request-scoped, even if a late
  # result arrives after the Plug's deadline on a persistent HTTP connection.
  def start(owner) do
    spawn(fn ->
      monitor = Process.monitor(owner)
      forward(owner, monitor)
    end)
  end

  def stop(lease) do
    Process.exit(lease, :shutdown)
    :ok
  end

  defp forward(owner, monitor) do
    receive do
      {:DOWN, ^monitor, :process, ^owner, _reason} ->
        :ok

      {:snodoecution, _executor, _reference, _key, _outcome} = event ->
        send(owner, event)
        forward(owner, monitor)
    end
  end
end
