defmodule MCP.Envelope do
  @moduledoc "A decoded JSON-RPC message before dialect-specific resolution."

  alias MCP.Error
  alias MCP.Transport.Context, as: TransportContext

  @type id :: String.t() | integer() | nil
  @type t :: %__MODULE__{
          id: id(),
          kind: :request | :notification,
          method: String.t(),
          params: map(),
          raw: map(),
          transport: TransportContext.t()
        }

  @enforce_keys [:kind, :method, :raw, :transport]
  defstruct [:id, :kind, :method, :transport, params: %{}, raw: %{}]

  @doc "Decodes the protocol-neutral JSON-RPC envelope without choosing a dialect."
  @spec decode(term(), TransportContext.t()) :: {:ok, t()} | {:error, Error.t()}
  def decode(raw, %TransportContext{} = transport) when is_map(raw) do
    with :ok <- validate_jsonrpc(raw),
         {:ok, method} <- fetch_method(raw),
         {:ok, params} <- validate_params(Map.get(raw, "params", %{})),
         {:ok, id, kind} <- validate_id(raw) do
      {:ok,
       %__MODULE__{
         id: id,
         kind: kind,
         method: method,
         params: params,
         raw: raw,
         transport: transport
       }}
    end
  end

  def decode(_raw, %TransportContext{}), do: {:error, Error.invalid_request()}

  defp validate_jsonrpc(%{"jsonrpc" => "2.0"}), do: :ok

  defp validate_jsonrpc(_raw) do
    {:error, Error.invalid_request("Expected a JSON-RPC 2.0 request")}
  end

  defp fetch_method(%{"method" => method}) when is_binary(method), do: {:ok, method}
  defp fetch_method(_raw), do: {:error, Error.invalid_request("Request method must be a string")}

  defp validate_params(params) when is_map(params), do: {:ok, params}

  defp validate_params(_params),
    do: {:error, Error.invalid_params("Request params must be an object")}

  defp validate_id(raw) do
    case Map.fetch(raw, "id") do
      :error -> {:ok, nil, :notification}
      {:ok, id} when is_binary(id) or is_integer(id) -> {:ok, id, :request}
      {:ok, _id} -> {:error, Error.invalid_request("Request id must be a string or integer")}
    end
  end
end
