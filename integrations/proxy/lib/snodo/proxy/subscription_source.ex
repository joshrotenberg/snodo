defmodule Snodo.Proxy.SubscriptionSource do
  @moduledoc false

  @behaviour Snodo.Subscription.Source

  alias Snodo.Authorization
  alias Snodo.Authorization.Component
  alias Snodo.Proxy.Catalog
  alias Snodo.Proxy.Manager
  alias Snodo.Subscription.Event
  alias Snodo.Subscription.Hub

  @impl true
  def open(filter, context, %{proxy: proxy, hub: hub, authorization: authorization}) do
    catalog = Manager.catalog(proxy)

    with {:ok, accepted} <- filter_resources(filter, catalog, context, authorization),
         {:ok, accepted, handle} <- Hub.open(accepted, context, hub) do
      {:ok, accepted, {handle, context}}
    end
  end

  @impl true
  def next({handle, context}, options) do
    case Hub.next(handle, options.hub) do
      {:ok, %Event{kind: :resource_updated, uri: uri} = event} ->
        catalog = Manager.catalog(options.proxy)

        case readable?(catalog, uri, context, options.authorization) do
          {:ok, true} -> {:ok, event}
          {:ok, false} -> next({handle, context}, options)
          {:error, error} -> {:error, error}
        end

      other ->
        other
    end
  end

  @impl true
  def close({handle, _context}, reason, %{hub: hub}), do: Hub.close(handle, reason, hub)

  defp filter_resources(filter, catalog, context, authorization) do
    case Map.fetch(filter, "resourceSubscriptions") do
      :error ->
        {:ok, filter}

      {:ok, uris} ->
        Enum.reduce_while(uris, {:ok, []}, fn uri, result ->
          admit_resource(uri, result, catalog, context, authorization)
        end)
        |> case do
          {:ok, accepted} ->
            {:ok, Map.put(filter, "resourceSubscriptions", Enum.reverse(accepted))}

          {:error, error} ->
            {:error, error}
        end
    end
  end

  defp admit_resource(uri, {:ok, accepted}, catalog, context, authorization) do
    case readable?(catalog, uri, context, authorization) do
      {:ok, true} -> {:cont, {:ok, [uri | accepted]}}
      {:ok, false} -> {:cont, {:ok, accepted}}
      {:error, error} -> {:halt, {:error, error}}
    end
  end

  defp readable?(catalog, uri, context, authorization) do
    case Catalog.lookup_resource(catalog, uri) do
      {:ok, %{kind: :resource_template}, _original_uri} ->
        {:ok, false}

      {:ok, %{subscribed?: false}, _original_uri} ->
        {:ok, false}

      {:ok, entry, _original_uri} ->
        component = %Component{
          kind: entry.kind,
          name: entry.name,
          uri: entry.public["uri"],
          requested_uri: nil
        }

        case Authorization.decide(authorization, :invocation, component, context) do
          :ok -> {:ok, true}
          {:refused, _error} -> {:ok, false}
          {:fault, error} -> {:error, error}
        end

      _unknown_or_ambiguous ->
        {:ok, false}
    end
  end
end
