defmodule MCP.Transport.Stdio.Framing do
  @moduledoc "Newline-delimited JSON framing for the MCP stdio binding."

  alias MCP.Error

  @spec decode_line(iodata()) :: {:ok, term()} | {:error, Error.t()}
  def decode_line(line) do
    line =
      line
      |> IO.iodata_to_binary()
      |> String.trim_trailing("\n")
      |> String.trim_trailing("\r")

    case JSON.decode(line) do
      {:ok, message} ->
        {:ok, message}

      {:error, _decode_error} ->
        {:error, Error.parse_error()}
    end
  rescue
    _exception -> {:error, Error.parse_error()}
  end

  @spec encode_message(map()) :: iodata()
  def encode_message(message) when is_map(message) do
    [JSON.encode_to_iodata!(message), "\n"]
  end
end
