defmodule Snodo.Transport.StdioReaderTest do
  use ExUnit.Case, async: true

  alias Snodo.Transport.Stdio.Reader

  # Feeds the chunks through the framer and returns every event, including
  # the final line at EOF.
  defp frame(chunks, max_line_bytes) do
    {events, buffer} =
      Enum.reduce(chunks, {[], Reader.new_buffer()}, fn chunk, {events, buffer} ->
        {new_events, buffer} = Reader.split(buffer, chunk, max_line_bytes)
        {events ++ new_events, buffer}
      end)

    events ++ Reader.flush(buffer)
  end

  test "lines split across chunks are joined, with CRLF left for the decoder" do
    assert frame(["{\"a\":", "1}\r\n{\"b\"", ":2}\n\n"], 100) ==
             [{:line, "{\"a\":1}\r\n"}, {:line, "{\"b\":2}\n"}, {:line, "\n"}]
  end

  test "the limit counts the newline" do
    assert frame(["123456789\n"], 10) == [{:line, "123456789\n"}]
    assert frame(["1234567890\n"], 10) == [:too_long]
    assert frame(["1234567890"], 10) == [{:line, "1234567890"}]
    assert frame(["12345678901"], 10) == [:too_long]
  end

  test "a long line is refused once, then dropped, and the next line is served" do
    {events, buffer} = Reader.split(Reader.new_buffer(), String.duplicate("x", 11), 10)
    assert {events, buffer} == {[:too_long], :discarding}

    assert Reader.split(buffer, String.duplicate("x", 1_000), 10) == {[], :discarding}

    assert frame([String.duplicate("x", 25), String.duplicate("x", 25), "x\nok\n"], 10) ==
             [:too_long, {:line, "ok\n"}]
  end

  test "input that ends without a newline delivers a final line within the limit" do
    long = String.duplicate("x", 20)

    assert frame(["one\ntwo"], 10) == [{:line, "one\n"}, {:line, "two"}]
    assert frame(["one\n", long], 10) == [{:line, "one\n"}, :too_long]
    assert frame(["one\n"], 10) == [{:line, "one\n"}]
  end
end
