defmodule Snodo.Transport.Stdio.Reader do
  @moduledoc false

  # Reads the stdio transport's input in a linked process and sends the owner
  # `{:stdio_line, line}`, `:stdio_line_too_long`, `{:stdio_read_error, reason}`,
  # and finally `:stdio_eof`.
  #
  # The default `:stdio` input is read in chunks through a bounded framer when
  # the VM allows it. Other input is read a line at a time, and the device holds
  # each line in full before returning it.

  @type buffer :: {iodata(), non_neg_integer()} | :discarding
  @type event :: {:line, binary()} | :too_long

  @spec start_link(IO.device(), pos_integer()) :: pid()
  def start_link(input, max_line_bytes) do
    owner = self()
    spawn_link(fn -> read(input, max_line_bytes, owner) end)
  end

  @spec new_buffer() :: buffer()
  def new_buffer, do: {[], 0}

  # Splits a chunk into the lines it completes. An unterminated line is held
  # until its newline. Once a line passes the limit, counting its newline, it
  # is reported once as :too_long and the rest of it is dropped as it arrives.
  @spec split(buffer(), binary(), pos_integer()) :: {[event()], buffer()}
  def split(buffer, chunk, max_line_bytes) do
    chunk
    |> :binary.split("\n", [:global])
    |> split_parts(buffer, max_line_bytes, [])
  end

  # Returns the final line when input ends without a newline.
  @spec flush(buffer()) :: [event()]
  def flush({_data, 0}), do: []
  def flush({data, _size}), do: [{:line, IO.iodata_to_binary(data)}]
  def flush(:discarding), do: []

  defp split_parts([unterminated], buffer, max_line_bytes, events) do
    {buffer, events} = append(buffer, unterminated, 0, max_line_bytes, events)
    {Enum.reverse(events), buffer}
  end

  defp split_parts([line | parts], buffer, max_line_bytes, events) do
    events =
      case append(buffer, line, 1, max_line_bytes, events) do
        {{data, _size}, events} -> [complete(data) | events]
        {:discarding, events} -> events
      end

    split_parts(parts, new_buffer(), max_line_bytes, events)
  end

  defp complete(data), do: {:line, IO.iodata_to_binary([data, ?\n])}

  # `newline` is 1 when the part ends its line, so the limit counts the newline
  # as a line read with `IO.read(:line)` does.
  defp append(:discarding, _part, _newline, _max, events), do: {:discarding, events}

  defp append({data, size}, part, newline, max_line_bytes, events) do
    size = size + byte_size(part)

    if size + newline > max_line_bytes,
      do: {:discarding, [:too_long | events]},
      else: {{[data, part], size}, events}
  end

  defp read(:stdio, max_line_bytes, owner) do
    case open_standard_input() do
      {:ok, source} -> read_chunks(source, new_buffer(), max_line_bytes, owner)
      :lines -> read_lines(:stdio, read_mode(:stdio), owner)
      {:error, reason} -> fail(owner, reason)
    end
  end

  defp read(input, _max_line_bytes, owner), do: read_lines(input, read_mode(input), owner)

  # The VM's own standard input reader holds fd 0 unless the VM was started
  # with -noinput, and a port opened on fd 0 is then logged as stealing it.
  # From OTP 28 that reader reads only when asked, so a duplicate of fd 0 can
  # be read beside it; before OTP 28 it reads eagerly and would compete for
  # the data. A duplicate can only be read as a socket.
  defp open_standard_input do
    cond do
      :init.get_argument(:noinput) != :error -> open_descriptor()
      otp_release() >= 28 -> open_socket()
      true -> :lines
    end
  end

  defp open_descriptor do
    {:ok, {:port, Port.open({:fd, 0, 1}, [:in, :binary, :eof])}}
  catch
    :error, reason -> {:error, reason}
  end

  defp open_socket do
    case duplicate_standard_input() do
      {:ok, socket} ->
        case :socket.getopt(socket, {:socket, :type}) do
          {:ok, :stream} ->
            {:ok, {:socket, socket}}

          _not_stream ->
            _closed = :socket.close(socket)
            :lines
        end

      {:error, _not_a_socket} ->
        :lines
    end
  catch
    :error, _socket_unavailable -> :lines
  end

  # Linux reports a descriptor's domain and macOS does not; a stream read does
  # not use it. For a pipe, a file, or a terminal both calls fail before
  # anything is duplicated, because the descriptor has no socket type.
  defp duplicate_standard_input do
    case :socket.open(0, %{dup: true}) do
      {:ok, socket} -> {:ok, socket}
      {:error, _no_domain} -> :socket.open(0, %{dup: true, domain: :local})
    end
  end

  defp otp_release, do: :otp_release |> :erlang.system_info() |> List.to_integer()

  defp read_chunks(source, buffer, max_line_bytes, owner) do
    case read_chunk(source) do
      {:ok, chunk} ->
        {events, buffer} = split(buffer, chunk, max_line_bytes)
        Enum.each(events, &send(owner, message(&1)))
        read_chunks(source, buffer, max_line_bytes, owner)

      :eof ->
        buffer |> flush() |> Enum.each(&send(owner, message(&1)))
        send(owner, :stdio_eof)

      {:error, reason} ->
        fail(owner, reason)
    end
  end

  defp read_chunk({:port, port}) do
    receive do
      {^port, {:data, chunk}} -> {:ok, chunk}
      {^port, :eof} -> :eof
    end
  end

  defp read_chunk({:socket, socket}) do
    case :socket.recv(socket, 0, :infinity) do
      {:ok, chunk} -> {:ok, chunk}
      {:error, :closed} -> :eof
      {:error, reason} -> {:error, reason}
    end
  end

  defp message({:line, line}), do: {:stdio_line, line}
  defp message(:too_long), do: :stdio_line_too_long

  defp read_lines(input, mode, owner) do
    case read_line(input, mode) do
      data when is_binary(data) ->
        send(owner, {:stdio_line, data})
        read_lines(input, mode, owner)

      :eof ->
        send(owner, :stdio_eof)

      {:error, reason} ->
        fail(owner, reason)
    end
  end

  defp read_line(input, :bytes), do: IO.binread(input, :line)
  defp read_line(input, :characters), do: IO.read(input, :line)

  # `:stdio` is a Latin-1 device when the VM's stdin is a pipe, and IO.read/2
  # would then turn each byte of a UTF-8 character into a character of its
  # own. IO.binread/2 returns the bytes unchanged. Unicode devices, and
  # devices that do not report an encoding, keep IO.read/2.
  defp read_mode(input) do
    case :io.getopts(io_device(input)) do
      options when is_list(options) ->
        if Keyword.get(options, :encoding) == :latin1, do: :bytes, else: :characters

      _unsupported ->
        :characters
    end
  end

  defp io_device(:stdio), do: :standard_io
  defp io_device(device), do: device

  defp fail(owner, reason) do
    send(owner, {:stdio_read_error, reason})
    send(owner, :stdio_eof)
  end
end
