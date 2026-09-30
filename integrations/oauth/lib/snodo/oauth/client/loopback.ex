defmodule Snodo.OAuth.Client.Loopback do
  @moduledoc false
  # The loopback redirect endpoint of RFC 8252 section 7.3: a listener on
  # 127.0.0.1, bound before the authorization URL exists, that answers the
  # authorization server's redirect and hands its query to the flow.

  @default_path "/callback"
  @header_limit 100
  @recv_timeout 5_000

  @page """
  <!doctype html>
  <html><head><meta charset="utf-8"><title>Authorization complete</title></head>
  <body><p>Authorization complete. You can close this window.</p></body></html>
  """

  @type t :: %{socket: :gen_tcp.socket(), path: String.t(), uri: String.t()}

  @doc "Binds the listener. Options: `:port` (0 for an OS-assigned port) and `:path`."
  @spec listen(keyword()) :: {:ok, t()} | {:error, term()}
  def listen(opts) do
    port = Keyword.get(opts, :port, 0)
    path = Keyword.get(opts, :path, @default_path)

    unless is_integer(port) and port in 0..65_535,
      do: raise(ArgumentError, "loopback :port must be an integer from 0 to 65535")

    unless is_binary(path) and String.starts_with?(path, "/") and
             not String.contains?(path, ["?", "#", " "]),
           do: raise(ArgumentError, "loopback :path must be an absolute path without a query")

    options = [
      :binary,
      active: false,
      packet: :http_bin,
      packet_size: 8_192,
      ip: {127, 0, 0, 1},
      reuseaddr: true,
      backlog: 8
    ]

    with {:ok, socket} <- :gen_tcp.listen(port, options),
         {:ok, port} <- :inet.port(socket) do
      {:ok, %{socket: socket, path: path, uri: "http://127.0.0.1:#{port}#{path}"}}
    end
  end

  @spec close(t()) :: :ok
  def close(%{socket: socket}), do: :gen_tcp.close(socket)

  @doc """
  Starts a process that accepts connections until one is a `GET` for the
  callback path, sends `{:redirect, ref, query}` to `flow`, and stops. Any
  other request gets a 404. It gives up after `timeout` milliseconds.
  """
  @spec accept(t(), pid(), reference(), timeout()) :: pid()
  def accept(listener, flow, ref, timeout) do
    spawn_link(fn -> loop(listener, flow, ref, deadline(timeout)) end)
  end

  defp loop(listener, flow, ref, deadline) do
    case :gen_tcp.accept(listener.socket, remaining(deadline)) do
      {:ok, socket} ->
        outcome = serve(socket, listener.path, flow, ref)
        :gen_tcp.close(socket)
        if outcome == :continue, do: loop(listener, flow, ref, deadline)

      {:error, _reason} ->
        :ok
    end
  end

  defp serve(socket, path, flow, ref) do
    with {:ok, {:http_request, method, {:abs_path, target}, _version}} <-
           :gen_tcp.recv(socket, 0, @recv_timeout),
         :ok <- drain_headers(socket, 0),
         :ok <- :inet.setopts(socket, packet: :raw) do
      %URI{path: request_path, query: query} = URI.parse(target)

      cond do
        method == :GET and request_path == path ->
          send(flow, {:redirect, ref, URI.decode_query(query || "", %{}, :www_form)})
          respond(socket, "200 OK", @page)
          :done

        request_path == path ->
          respond(socket, "405 Method Not Allowed", "Method not allowed\n")
          :continue

        true ->
          respond(socket, "404 Not Found", "Not found\n")
          :continue
      end
    else
      _other -> :continue
    end
  end

  defp drain_headers(_socket, count) when count > @header_limit, do: :error

  defp drain_headers(socket, count) do
    case :gen_tcp.recv(socket, 0, @recv_timeout) do
      {:ok, :http_eoh} -> :ok
      {:ok, {:http_header, _index, _name, _reserved, _value}} -> drain_headers(socket, count + 1)
      _other -> :error
    end
  end

  defp respond(socket, status, body) do
    _sent =
      :gen_tcp.send(socket, [
        "HTTP/1.1 ",
        status,
        "\r\ncontent-type: text/html; charset=utf-8\r\ncontent-length: ",
        Integer.to_string(byte_size(body)),
        "\r\ncache-control: no-store\r\nconnection: close\r\n\r\n",
        body
      ])

    :ok
  end

  defp deadline(:infinity), do: :infinity
  defp deadline(timeout), do: System.monotonic_time(:millisecond) + timeout

  defp remaining(:infinity), do: :infinity
  defp remaining(deadline), do: max(deadline - System.monotonic_time(:millisecond), 0)
end
