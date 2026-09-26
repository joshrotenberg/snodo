defmodule Snodo.Error do
  @moduledoc "A protocol-neutral error with JSON-RPC-compatible defaults."

  @type kind ::
          :json_rpc
          | :protocol
          | :transport
          | :execution
          | :authorization
          | :extension

  @type t :: %__MODULE__{
          code: integer(),
          message: String.t(),
          data: term() | nil,
          kind: kind(),
          cause: term() | nil
        }

  @enforce_keys [:code, :message, :kind]
  defstruct [:code, :message, :data, :kind, :cause]

  @doc "Builds a JSON-RPC parse error: code -32700, kind `:json_rpc`."
  @spec parse_error(String.t()) :: t()
  def parse_error(message \\ "Parse error"),
    do: new(-32_700, message, :json_rpc)

  @doc "Builds a JSON-RPC invalid request error: code -32600, kind `:json_rpc`."
  @spec invalid_request(String.t()) :: t()
  def invalid_request(message \\ "Invalid Request"),
    do: new(-32_600, message, :json_rpc)

  @doc """
  Builds a method-not-found error for `method`: code -32601, kind `:protocol`,
  message `"Method not found: <method>"`.
  """
  @spec method_not_found(String.t()) :: t()
  def method_not_found(method),
    do: new(-32_601, "Method not found: #{method}", :protocol)

  @doc """
  Builds an invalid params error: code -32602, kind `:protocol`.

  `data`, when not `nil`, is sent as the error's `"data"` and must be a JSON
  value. Return this from a handler when the request should fail as a
  JSON-RPC error, for example a resource that does not exist.
  """
  @spec invalid_params(String.t(), term() | nil) :: t()
  def invalid_params(message \\ "Invalid params", data \\ nil),
    do: new(-32_602, message, :protocol, data)

  @doc """
  Builds an internal error: code -32603, kind `:execution`.

  `cause` is kept in the struct's `cause` field. `to_json_rpc/1` leaves it
  out, so it is not sent to the client.
  """
  @spec internal(String.t(), term() | nil) :: t()
  def internal(message \\ "Internal error", cause \\ nil),
    do: %__MODULE__{code: -32_603, message: message, kind: :execution, cause: cause}

  @doc """
  Builds an application authorization refusal.

  `code` is the application's own choice; JSON-RPC reserves -32000..-32099 for
  implementation-defined server errors. `snodo` never invents one.
  """
  @spec authorization(integer(), String.t(), term() | nil) :: t()
  def authorization(code, message, data \\ nil)
      when is_integer(code) and is_binary(message),
      do: new(code, message, :authorization, data)

  @doc """
  Wraps a failure reason as an execution error.

  An `Snodo.Error` is returned unchanged. Any other `reason` becomes code
  -32603 with the message `"Tool execution failed"`, kind `:execution`, and
  `reason` in the `cause` field, which `to_json_rpc/1` leaves out.
  """
  @spec execution(term()) :: t()
  def execution(%__MODULE__{} = error), do: error

  def execution(reason) do
    %__MODULE__{
      code: -32_603,
      message: "Tool execution failed",
      kind: :execution,
      cause: reason
    }
  end

  @doc """
  Returns the JSON-RPC error object: `"code"`, `"message"`, and `"data"` when
  `data` is not `nil`. `kind` and `cause` are not included.
  """
  @spec to_json_rpc(t()) :: map()
  def to_json_rpc(%__MODULE__{} = error) do
    %{"code" => error.code, "message" => error.message}
    |> maybe_put("data", error.data)
  end

  defp new(code, message, kind, data \\ nil) do
    %__MODULE__{code: code, message: message, kind: kind, data: data}
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
