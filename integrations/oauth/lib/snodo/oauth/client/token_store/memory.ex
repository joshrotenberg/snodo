defmodule Snodo.OAuth.Client.TokenStore.Memory do
  @moduledoc """
  The default `Snodo.OAuth.Client.TokenStore`: a map held in the client's
  own state, so the tokens are forgotten when the client stops.
  """

  @behaviour Snodo.OAuth.Client.TokenStore

  @impl true
  def init(_arg), do: {:ok, %{}}

  @impl true
  def fetch(map, key), do: Map.fetch(map, key)

  @impl true
  def put(map, key, value), do: {:ok, Map.put(map, key, value)}

  @impl true
  def delete(map, key), do: {:ok, Map.delete(map, key)}
end
