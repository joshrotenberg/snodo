defmodule MCP.Cancellation do
  @moduledoc "A lightweight cooperative cancellation token backed by `:atomics`."

  @opaque t :: %__MODULE__{state: :atomics.atomics_ref()}
  @enforce_keys [:state]
  defstruct [:state]

  @spec new() :: t()
  def new do
    %__MODULE__{state: :atomics.new(1, signed: false)}
  end

  @spec cancel(t(), term()) :: :ok
  def cancel(%__MODULE__{state: state}, _reason \\ nil) do
    :ok = :atomics.put(state, 1, 1)
  end

  @spec cancelled?(t()) :: boolean()
  def cancelled?(%__MODULE__{state: state}), do: :atomics.get(state, 1) == 1

  @doc "Recognizes a cancellation token at an untyped context boundary."
  @spec normalize(term()) :: {:ok, t()} | :error
  def normalize(%__MODULE__{} = token), do: {:ok, token}
  def normalize(_other), do: :error
end
