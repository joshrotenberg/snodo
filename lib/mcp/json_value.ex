defmodule MCP.JSONValue do
  @moduledoc false

  @spec valid?(term()) :: boolean()
  def valid?(value)
      when is_nil(value) or is_boolean(value) or is_binary(value) or is_number(value),
      do: true

  def valid?(value) when is_list(value), do: Enum.all?(value, &valid?/1)

  def valid?(value) when is_map(value) do
    Enum.all?(value, fn {key, nested} -> is_binary(key) and valid?(nested) end)
  end

  def valid?(_value), do: false
end
