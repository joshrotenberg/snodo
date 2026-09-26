defmodule Snodo.Cancellation do
  @moduledoc "A lightweight cooperative cancellation token backed by `:atomics`."

  @opaque t :: %__MODULE__{state: :atomics.atomics_ref()}
  @enforce_keys [:state]
  defstruct [:state]

  @doc """
  Returns a token that is not cancelled.

  Copies of the token, including copies sent to other processes on the same
  node, share one state, so a cancellation through any copy is seen by all.
  """
  @spec new() :: t()
  def new do
    %__MODULE__{state: :atomics.new(1, signed: false)}
  end

  @doc """
  Marks the token cancelled. Cancelling an already cancelled token is a no-op.

  The token does not record `reason`; it is accepted and ignored.
  """
  @spec cancel(t(), term()) :: :ok
  def cancel(%__MODULE__{state: state}, _reason \\ nil) do
    :ok = :atomics.put(state, 1, 1)
  end

  @doc """
  Returns whether the token has been cancelled.

  A handler finds its request's token in the `cancellation` field of
  `Snodo.Context` when a transport runs the request through
  `Snodo.Server.Executor`. The field is `nil` for direct dispatch, so check
  it with `normalize/1` first.
  """
  @spec cancelled?(t()) :: boolean()
  def cancelled?(%__MODULE__{state: state}), do: :atomics.get(state, 1) == 1

  @doc "Recognizes a cancellation token at an untyped context boundary."
  @spec normalize(term()) :: {:ok, t()} | :error
  def normalize(%__MODULE__{} = token), do: {:ok, token}
  def normalize(_other), do: :error
end
