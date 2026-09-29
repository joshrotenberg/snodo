defmodule Snodo.Client.Response do
  @moduledoc false
  # Decodes one JSON-RPC response object into the tuples `Snodo.Client`
  # documents. Transports use it too, for the terminal response of a
  # `subscriptions/listen` stream, so both paths read a response the same way.

  alias Snodo.Client.Transport
  alias Snodo.Error

  @type decoded :: {:ok, map()} | {:input_required, map()} | {:error, Error.t()}

  @doc false
  @spec decode(map()) :: decoded()
  def decode(%{"result" => _result, "error" => _error} = response) do
    {:error, Transport.connection_error("The server sent both a result and an error", response)}
  end

  def decode(%{"result" => %{"resultType" => "input_required"} = result}),
    do: {:input_required, result}

  def decode(%{"result" => result}) when is_map(result), do: {:ok, result}

  def decode(%{"error" => %{"code" => code, "message" => message} = error})
      when is_integer(code) and is_binary(message) do
    {:error,
     %Error{code: code, message: message, data: Map.get(error, "data"), kind: error_kind(code)}}
  end

  def decode(response) do
    {:error, Transport.connection_error("The server sent an invalid JSON-RPC response", response)}
  end

  @doc false
  @spec terminal(map()) :: :complete | {:error, Error.t()}
  def terminal(response) do
    case decode(response) do
      {:ok, _result} ->
        :complete

      {:error, %Error{} = error} ->
        {:error, error}

      {:input_required, result} ->
        {:error,
         Transport.connection_error(
           "The server sent an input_required result for a subscription",
           result
         )}
    end
  end

  defp error_kind(code) when code in [-32_700, -32_600], do: :json_rpc
  defp error_kind(code) when code in [-32_601, -32_602], do: :protocol
  defp error_kind(-32_603), do: :execution
  defp error_kind(_code), do: :protocol
end
