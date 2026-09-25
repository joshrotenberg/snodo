defmodule Snodo.Subscription.Filter do
  @moduledoc false

  alias Snodo.JSONValue

  @spec valid?(term()) :: boolean()
  def valid?(filter) when is_map(filter) do
    Enum.all?(filter, fn {key, value} -> is_binary(key) and JSONValue.valid?(value) end)
  end

  def valid?(_filter), do: false

  @spec subset?(term(), term()) :: boolean()
  def subset?(candidate, supported) when is_map(candidate) and is_map(supported) do
    valid?(candidate) and
      Enum.all?(candidate, fn {key, value} ->
        case Map.fetch(supported, key) do
          {:ok, supported_value} -> value_subset?(value, supported_value)
          :error -> false
        end
      end)
  end

  def subset?(_candidate, _supported), do: false

  @spec merge(map(), map()) :: {:ok, map()} | {:error, [String.t()]}
  def merge(left, right) when is_map(left) and is_map(right) do
    collisions = left |> Map.keys() |> Enum.filter(&Map.has_key?(right, &1)) |> Enum.sort()

    case collisions do
      [] -> {:ok, Map.merge(left, right)}
      keys -> {:error, keys}
    end
  end

  @spec project(map(), map()) :: map()
  def project(accepted, contribution) when is_map(accepted) and is_map(contribution) do
    accepted
    |> Map.take(Map.keys(contribution))
    |> Enum.filter(fn {key, value} ->
      value_subset?(value, Map.fetch!(contribution, key))
    end)
    |> Map.new()
  end

  defp value_subset?(candidate, supported) when is_list(candidate) and is_list(supported) do
    Enum.all?(candidate, &Enum.member?(supported, &1))
  end

  defp value_subset?(candidate, supported) when is_map(candidate) and is_map(supported) do
    subset?(candidate, supported)
  end

  defp value_subset?(candidate, supported), do: candidate == supported
end
