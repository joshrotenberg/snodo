defmodule MCP.Transport.Context do
  @moduledoc """
  Opaque, request-scoped information supplied by a transport.

  Protocol-independent code should not infer transport policy from this struct.
  """

  @type headers :: %{optional(String.t()) => String.t()} | [{String.t(), String.t()}]

  @type t :: %__MODULE__{
          transport: atom() | module() | nil,
          peer: term(),
          request_headers: headers(),
          response_handle: term(),
          connection_ref: term(),
          metadata: map()
        }

  defstruct [
    :transport,
    :peer,
    :response_handle,
    :connection_ref,
    request_headers: %{},
    metadata: %{}
  ]

  @doc false
  @spec get_header(headers(), String.t()) :: String.t() | nil
  def get_header(headers, name) when is_map(headers) do
    wanted = String.downcase(name)

    Enum.find_value(headers, fn {key, value} ->
      if String.downcase(to_string(key)) == wanted, do: value
    end)
  end

  def get_header(headers, name) when is_list(headers) do
    wanted = String.downcase(name)

    Enum.find_value(headers, fn {key, value} ->
      if String.downcase(to_string(key)) == wanted, do: value
    end)
  end
end
