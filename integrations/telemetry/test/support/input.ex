defmodule SnodoTest.Telemetry.Input do
  @moduledoc false

  # An IO device for the stdio transport's reader that answers get_line with
  # the lines a test pushes, in order, so a test can send a message after an
  # earlier request is already running. It answers :eof once eof/1 was called
  # and no line is left.

  @spec start_link() :: {:ok, pid()}
  def start_link, do: {:ok, spawn_link(fn -> loop(:queue.new(), nil, false) end)}

  @spec push(pid(), binary()) :: :ok
  def push(device, line) when is_binary(line) do
    send(device, {:push, line})
    :ok
  end

  @spec eof(pid()) :: :ok
  def eof(device) do
    send(device, :eof)
    :ok
  end

  defp loop(queue, waiter, eof?) do
    receive do
      {:push, line} ->
        push_line(queue, waiter, eof?, line)

      :eof ->
        mark_eof(queue, waiter)

      {:io_request, from, reply_as, request} ->
        request(queue, waiter, eof?, {from, reply_as}, request)
    end
  end

  defp push_line(queue, nil, eof?, line), do: loop(:queue.in(line, queue), nil, eof?)

  defp push_line(queue, {from, reply_as}, eof?, line) do
    io_reply(from, reply_as, line)
    loop(queue, nil, eof?)
  end

  defp mark_eof(queue, {from, reply_as} = waiter) do
    if :queue.is_empty(queue),
      do: io_reply(from, reply_as, :eof),
      else: loop(queue, waiter, true)
  end

  defp mark_eof(queue, nil), do: loop(queue, nil, true)

  defp request(queue, _waiter, eof?, {from, reply_as} = caller, {:get_line, _encoding, _prompt}) do
    case :queue.out(queue) do
      {{:value, line}, rest} ->
        io_reply(from, reply_as, line)
        loop(rest, nil, eof?)

      {:empty, _queue} when eof? ->
        io_reply(from, reply_as, :eof)

      {:empty, queue} ->
        loop(queue, caller, eof?)
    end
  end

  defp request(queue, waiter, eof?, {from, reply_as}, _unsupported) do
    io_reply(from, reply_as, {:error, :enotsup})
    loop(queue, waiter, eof?)
  end

  defp io_reply(to, reply_as, reply) do
    send(to, {:io_reply, reply_as, reply})
    :ok
  end
end
