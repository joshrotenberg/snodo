defmodule Snodo.Extension.Declared do
  @moduledoc false
  # Stands in for an extension declared with {:declared, id, settings}: no
  # methods, and negotiation yields the client's settings. The registry keys it
  # by the declared id and never calls id/0.

  @behaviour Snodo.Extension

  alias Snodo.Error

  @impl true
  def id, do: "dev.snodo/declared"

  @impl true
  def methods, do: []

  @impl true
  def negotiate(client_settings, _server_settings), do: {:ok, client_settings}

  # A declared extension has no routes, so these are never called.
  @impl true
  def validate_operation(_operation, _params, _context), do: {:error, no_methods()}

  @impl true
  def dispatch(_operation, _params, _context), do: {:error, no_methods()}

  @impl true
  def shape_result(_operation, _result, _context), do: %{}

  @impl true
  def shape_error(%Error{} = error, _context), do: Error.to_json_rpc(error)

  defp no_methods, do: Error.internal("A declared extension has no methods")
end
