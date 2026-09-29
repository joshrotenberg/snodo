defmodule Snodo.OAuth.Client.RegistrationStore.Memory do
  @moduledoc """
  The default `Snodo.OAuth.Client.RegistrationStore`: a map held in the client's
  own state, so the registrations are forgotten when the client stops.
  """

  @behaviour Snodo.OAuth.Client.RegistrationStore

  @impl true
  def init(_arg), do: {:ok, %{}}

  @impl true
  def fetch(map, key), do: Map.fetch(map, key)

  @impl true
  def put(map, key, value), do: {:ok, Map.put(map, key, value)}

  @impl true
  def delete(map, key), do: {:ok, Map.delete(map, key)}
end
