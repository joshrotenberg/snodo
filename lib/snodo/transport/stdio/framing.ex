defmodule Snodo.Transport.Stdio.Framing do
  @moduledoc "Newline-delimited JSON framing for the MCP stdio binding."

  alias Snodo.Error

  @doc """
  Decodes one line of JSON. A trailing newline and carriage return, and a
  leading UTF-8 byte order mark, are ignored.
  """
  @spec decode_line(iodata()) :: {:ok, term()} | {:error, Error.t()}
  def decode_line(line) do
    line =
      line
      |> IO.iodata_to_binary()
      |> strip_byte_order_mark()
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

  defp strip_byte_order_mark(<<0xEF, 0xBB, 0xBF, rest::binary>>), do: rest
  defp strip_byte_order_mark(line), do: line

  @doc """
  Encodes one message as a line of JSON.

  Every character outside ASCII is written as a JSON `\\uXXXX` escape, with a
  surrogate pair above U+FFFF. The line is then the same bytes whatever the
  output device's encoding. Raw UTF-8 written with `IO.binwrite/2` to a
  Unicode-mode device, which `:stdio` is under `elixir`, would be encoded a
  second time. The escapes also keep U+2028 and U+2029 out of the stream.
  """
  @spec encode_message(map()) :: iodata()
  def encode_message(message) when is_map(message) do
    json = message |> JSON.encode_to_iodata!() |> IO.iodata_to_binary()
    [escape_non_ascii(json), "\n"]
  end

  defp escape_non_ascii(json) do
    if Regex.match?(~r/[\x80-\xFF]/, json) do
      for <<codepoint::utf8 <- json>>, into: "", do: escape(codepoint)
    else
      json
    end
  end

  defp escape(codepoint) when codepoint < 0x80, do: <<codepoint>>
  defp escape(codepoint) when codepoint < 0x10000, do: unicode_escape(codepoint)

  defp escape(codepoint) do
    offset = codepoint - 0x10000

    unicode_escape(0xD800 + Bitwise.bsr(offset, 10)) <>
      unicode_escape(0xDC00 + Bitwise.band(offset, 0x3FF))
  end

  defp unicode_escape(unit) do
    "\\u" <> (unit |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(4, "0"))
  end
end
