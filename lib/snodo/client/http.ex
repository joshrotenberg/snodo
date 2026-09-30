defmodule Snodo.Client.HTTP do
  @moduledoc """
  Streamable HTTP transport for `Snodo.Client.connect({:http, url}, opts)`.

  Each request is one HTTP/1.1 `POST` on its own `:gen_tcp` or `:ssl`
  connection, closed before the request returns, so no connection or process
  outlives it. The request headers come from the protocol dialect's
  `transport_policy/1`, the same declaration the server admits requests
  against: the accepted and request media types, and every mirrored header
  (for `2026-07-28`, `MCP-Protocol-Version`, `Mcp-Method`, and `Mcp-Name`) read
  from the request body. A mirrored value that is not plain printable ASCII is
  sent in the `=?base64?...?=` form when the policy allows it. A header value
  that contains CR, LF, or NUL is refused with a -32000 transport error.

  The response may be `application/json` or `text/event-stream`. An event
  stream is read as it arrives, and the transport returns the response whose
  ID matches the request as soon as that event is complete. A
  `notifications/progress` event for a request made with `progress:` is passed
  to the progress function when it arrives, and with
  `reset_timeout_on_progress: true` it moves the deadline for the rest of the
  response. A request the server sends on the stream, such as
  `elicitation/create` on an initialize-era connection, is answered by the
  `:on_server_request` function in the calling process, and the response is
  sent as its own `POST` before the stream is read further; without that
  option such a request is dropped. The time the function takes counts
  against the request's timeout, which is not extended. Other notifications are dropped. A
  JSON-RPC error body is returned whatever the HTTP status, so `Snodo.Client`
  decodes it as `{:error, %Snodo.Error{}}`. Anything else is a -32000 transport
  error with the status and body in `cause`. A timeout closes the connection,
  which the server treats as cancellation.

  On an initialize-era connection the client passes `MCP-Protocol-Version` and
  `Mcp-Session-Id` in `:headers`, reads `Mcp-Session-Id` from the `initialize`
  response through `:on_response_headers`, sends `notifications/initialized`
  with `notify/3` (a `POST` answered with a 2xx and no body), and ends the
  session with `delete_session/2`, a `DELETE` with the same headers whose
  outcome is not reported: a server that does not support client-initiated
  termination answers 405.

  A `subscriptions/listen` request opened with `Snodo.Client.listen/3` keeps
  its event-stream response open in a process of its own, which delivers the
  events to the owner (see `Snodo.Client.Subscription`). The request timeout
  bounds the wait for the acknowledgement only. Closing the subscription, or
  the owner's exit, closes that connection, which the server treats as
  cancellation. `:max_response_bytes` applies to each event of the stream
  rather than to the stream as a whole.

  The response is read by this module rather than `:httpc`, which reads the
  body of any status other than 200 and 206 in full before returning it.
  `:max_response_bytes` is checked as the response arrives, whatever its
  status: a `Content-Length` over the limit is refused before the body is read,
  a chunked body is refused at the first chunk that would pass it, and a body
  that ends when the connection closes is refused at the read that passes it.
  An event stream is one body, so the limit applies to the whole stream,
  notifications included. The status line and headers are held to the same
  limit. Over the limit the connection is closed and the request returns a
  -32000 transport error with `cause: {:max_response_bytes, limit}`.

  Options:

    * `:headers` - extra request headers as `{name, value}` string pairs, for
      example `[{"authorization", "Bearer " <> token}]`. The transport owns
      `host`, `content-type`, `content-length`, `transfer-encoding`, and
      `connection`, and refuses them here.
    * `:ssl` - `:ssl` client options for `https` URLs. The default verifies the
      peer against `:public_key.cacerts_get/0` and checks the host name.
    * `:connect_timeout` - milliseconds to establish the connection. Defaults
      to the request timeout.
    * `:max_response_bytes` - the largest response to accept, default 16 MiB,
      the stdio client's line limit.
  """

  @behaviour Snodo.Client.Transport

  alias Snodo.Client.Deadline
  alias Snodo.Client.HTTP.Stream, as: SubscriptionStream
  alias Snodo.Client.Transport
  alias Snodo.Envelope
  alias Snodo.Transport.Context, as: TransportContext
  alias Snodo.Transport.ParamHeaders
  alias Snodo.Transport.Policy

  @type state :: %{
          scheme: String.t(),
          host: charlist(),
          port: :inet.port_number(),
          authority: String.t(),
          target: String.t(),
          socket_options: [:gen_tcp.connect_option()],
          headers: [{String.t(), String.t()}],
          ssl: keyword(),
          connect_timeout: timeout() | nil,
          max_response_bytes: pos_integer()
        }

  @sentinel_prefix "=?base64?"
  @sentinel_suffix "?="
  @default_max_response_bytes 16 * 1024 * 1024
  @socket_options [:binary, active: false, packet: :raw]
  @default_ports %{"http" => 80, "https" => 443}
  # A chunk-size line is a hex number and optional extensions.
  @max_chunk_line_bytes 4_096
  @owned_headers ~w(host content-type content-length transfer-encoding connection)

  @impl Transport
  def connect(url, opts) when is_binary(url) do
    max_response_bytes = Keyword.get(opts, :max_response_bytes, @default_max_response_bytes)

    unless is_integer(max_response_bytes) and max_response_bytes > 0 do
      raise ArgumentError, ":max_response_bytes must be a positive integer"
    end

    headers = Keyword.get(opts, :headers, [])

    unless is_list(headers) and Enum.all?(headers, &valid_extra_header?/1) do
      raise ArgumentError,
            ":headers must be {name, value} string pairs without CR, LF, or NUL, " <>
              "and without #{Enum.join(@owned_headers, ", ")}; got: #{inspect(headers)}"
    end

    case URI.new(url) do
      {:ok, %URI{scheme: scheme, host: host} = uri}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        {:ok, _started} = Application.ensure_all_started(:ssl)

        {:ok,
         %{
           scheme: scheme,
           host: String.to_charlist(host),
           port: uri.port,
           authority: authority(uri),
           target: target(uri),
           socket_options: socket_options(host),
           headers: headers,
           ssl: Keyword.get_lazy(opts, :ssl, fn -> default_ssl(uri) end),
           connect_timeout: Keyword.get(opts, :connect_timeout),
           max_response_bytes: max_response_bytes
         }}

      _invalid ->
        {:error, Transport.connection_error("Expected an http or https URL", url)}
    end
  end

  @impl Transport
  def request(state, message, opts) when is_map(message) do
    timeout = Keyword.fetch!(opts, :timeout)
    policy = policy(Keyword.fetch!(opts, :dialect), message)

    headers =
      message_headers(policy) ++
        mirrored_headers(policy, message) ++
        parameter_headers(policy, message, Keyword.get(opts, :tool)) ++
        Keyword.get(opts, :headers, [])

    with :ok <- check_headers(headers) do
      state
      |> exchange("POST", headers ++ state.headers, message, opts)
      |> response(timeout, state.max_response_bytes)
    end
  end

  @impl Transport
  def notify(state, message, opts) when is_map(message) do
    policy = policy(Keyword.fetch!(opts, :dialect), message)

    headers =
      message_headers(policy) ++
        mirrored_headers(policy, message) ++ Keyword.get(opts, :headers, [])

    deliver(state, headers, message, opts)
  end

  @impl Transport
  def delete_session(state, opts) do
    headers = Keyword.get(opts, :headers, [])

    with :ok <- check_headers(headers) do
      _outcome = exchange(state, "DELETE", headers ++ state.headers, nil, opts)
    end

    :ok
  end

  @impl Transport
  def listen(state, message, opts) when is_map(message) do
    policy = policy(Keyword.fetch!(opts, :dialect), message)
    [content_type | _other_types] = policy.request_content_types

    headers = [
      {"content-type", content_type},
      {"accept", Enum.join(policy.required_accept_types, ", ")}
      | mirrored_headers(policy, message)
    ]

    case Enum.reject(headers, &valid_header?/1) do
      [] ->
        SubscriptionStream.open(state, headers ++ state.headers, message, opts)

      [{name, _value} | _others] ->
        {:error, Transport.connection_error("Invalid HTTP request header", name)}
    end
  end

  @impl Transport
  def close(_state), do: :ok

  # Runs in a process linked to `stream`, a `Snodo.Client.HTTP.Stream`. Sends
  # the request, then feeds every decoded event-stream message to `stream` as
  # `{:mcp_stream_message, message}`, and ends with `{:mcp_stream_end,
  # outcome}`. The ack deadline is `timeout`; once the first message has
  # arrived the read waits without limit. `:max_response_bytes` applies to the
  # head and to each event.
  @doc false
  @spec read_stream(pid(), state(), [{String.t(), String.t()}], map(), timeout()) :: :ok
  def read_stream(stream, state, headers, message, timeout) do
    outcome =
      with {:ok, socket} <- open(state, state.connect_timeout || timeout, timeout) do
        send(stream, {:mcp_stream_socket, socket})

        conn = %{
          socket: socket,
          deadline: Deadline.new(timeout: timeout),
          limit: state.max_response_bytes,
          id: Map.get(message, "id"),
          on_progress: nil,
          token: nil,
          on_server_request: nil,
          reply: nil,
          stream: stream,
          read: 0,
          body: nil
        }

        try do
          with :ok <- send_request(socket, state, "POST", headers, JSON.encode!(message)),
               {:ok, status, response_headers, rest} <- read_head(conn, "", 0) do
            conn = %{conn | body: body_state(response_headers)}

            case read_body(conn, status, response_headers, rest) do
              {:ok, conn} -> {:ok, status, finish(conn)}
              {:error, reason} -> {:error, reason}
            end
          end
        after
          close_socket(socket)
        end
      end

    send(stream, {:mcp_stream_end, stream_outcome(outcome, timeout, state.max_response_bytes)})
    :ok
  end

  defp stream_outcome({:ok, _status, {:unmatched, _sample}}, _timeout, _limit), do: :ended

  defp stream_outcome({:ok, status, {:body, body}}, _timeout, _limit) do
    case decode_json(status, body) do
      {:ok, response} -> {:response, response}
      {:error, error} -> {:error, error}
    end
  end

  defp stream_outcome(failure, timeout, limit), do: response(failure, timeout, limit)

  @doc false
  @spec close_socket({:gen_tcp | :ssl, term()}) :: :ok
  def close_socket({module, socket}) do
    _closed = module.close(socket)
    :ok
  end

  @doc """
  Encodes a mirrored header value with the base64 sentinel when it is not
  plain printable ASCII, or when the plain value could be mistaken for one.
  """
  @spec encode_sentinel(String.t()) :: String.t()
  def encode_sentinel(value) when is_binary(value) do
    if header_safe?(value) do
      value
    else
      @sentinel_prefix <> Base.encode64(value) <> @sentinel_suffix
    end
  end

  defp policy(dialect, message) do
    {:ok, envelope} = Envelope.decode(message, %TransportContext{transport: :streamable_http})
    %Policy{} = dialect.transport_policy(envelope)
  end

  defp message_headers(%Policy{} = policy) do
    [content_type | _other_types] = policy.request_content_types

    [
      {"content-type", content_type},
      {"accept", Enum.join(policy.required_accept_types, ", ")}
    ]
  end

  defp check_headers(headers) do
    case Enum.reject(headers, &valid_header?/1) do
      [] -> :ok
      [{name, _value} | _others] when is_binary(name) -> invalid_header(name)
      [invalid | _others] -> invalid_header(invalid)
    end
  end

  defp invalid_header(header),
    do: {:error, Transport.connection_error("Invalid HTTP request header", header)}

  # A message that gets no JSON-RPC response: a notification, or the client's
  # answer to a server request. The server accepts it with a 2xx and no body,
  # or refuses it with an error body.
  defp deliver(state, headers, message, opts) do
    timeout = Keyword.fetch!(opts, :timeout)

    with :ok <- check_headers(headers) do
      case exchange(state, "POST", headers ++ state.headers, message, opts) do
        {:ok, status, _body} when status in 200..299 -> :ok
        {:ok, status, {:body, body}} -> refused(status, body)
        {:ok, status, {:unmatched, sample}} -> unexpected(status, sample)
        {:ok, status, {:response, response}} -> refused(status, JSON.encode!(response))
        {:error, _reason} = failure -> response(failure, timeout, state.max_response_bytes)
      end
    end
  end

  defp refused(status, body) do
    case Snodo.JSONValue.decode(body) do
      {:ok, %{"error" => %{"code" => code, "message" => message} = error}}
      when is_integer(code) and is_binary(message) ->
        {:error,
         %Snodo.Error{code: code, message: message, data: Map.get(error, "data"), kind: :protocol}}

      _other ->
        unexpected(status, body)
    end
  end

  defp mirrored_headers(%Policy{mirrored_headers: mirrors}, message) do
    Enum.flat_map(mirrors, fn {name, mirror} ->
      case get_in(message, Map.fetch!(mirror, :path)) do
        value when is_binary(value) -> [{name, encode(value, Map.get(mirror, :encoding, :plain))}]
        _absent -> []
      end
    end)
  end

  # `x-mcp-header` arguments of a tools/call, when the caller passed the tool
  # definition. A null or absent argument sends no header.
  defp parameter_headers(
         %Policy{tool_parameter_headers?: true},
         %{"params" => %{"arguments" => arguments}},
         %{"inputSchema" => schema}
       )
       when is_map(arguments) and is_map(schema) do
    case ParamHeaders.annotations(schema) do
      {:ok, annotations} -> Enum.flat_map(annotations, &parameter_header(&1, arguments))
      {:error, _reason} -> []
    end
  end

  defp parameter_headers(_policy, _message, _tool), do: []

  defp parameter_header(annotation, arguments) do
    case arguments |> dig(annotation.path) |> ParamHeaders.plain_value() do
      nil -> []
      value -> [{ParamHeaders.header_name(annotation), encode_sentinel(value)}]
    end
  end

  defp dig(value, []), do: value
  defp dig(%{} = map, [key | rest]), do: map |> Map.get(key) |> dig(rest)
  defp dig(_value, _path), do: nil

  defp encode(value, :plain), do: value
  defp encode(value, :base64_sentinel), do: encode_sentinel(value)

  defp header_safe?(value) do
    value == String.trim(value) and
      not (String.starts_with?(value, @sentinel_prefix) and
             String.ends_with?(value, @sentinel_suffix)) and
      Enum.all?(:binary.bin_to_list(value), &(&1 in 0x20..0x7E))
  end

  defp valid_header?({name, value}) when is_binary(name) and is_binary(value) do
    name != "" and not String.contains?(name, [":", " ", "\r", "\n", "\0"]) and
      not String.contains?(value, ["\r", "\n", "\0"])
  end

  defp valid_header?(_header), do: false

  defp valid_extra_header?({name, _value} = header) when is_binary(name),
    do: valid_header?(header) and String.downcase(name) not in @owned_headers

  defp valid_extra_header?(_header), do: false

  # The socket is closed when the exchange ends, whatever the outcome. A nil
  # message sends no body (DELETE).
  defp exchange(state, method, headers, message, opts) do
    timeout = Keyword.fetch!(opts, :timeout)
    on_progress = Keyword.get(opts, :on_progress)
    on_headers = Keyword.get(opts, :on_response_headers)

    with {:ok, socket} <- open(state, state.connect_timeout || timeout, timeout) do
      conn = %{
        socket: socket,
        deadline: Deadline.new(opts),
        limit: state.max_response_bytes,
        id: message && Map.get(message, "id"),
        on_progress: on_progress,
        token: if(on_progress, do: get_in(message, ["params", "_meta", "progressToken"])),
        on_server_request: Keyword.get(opts, :on_server_request),
        reply: {state, Keyword.get(opts, :headers, []), Keyword.take(opts, [:timeout])},
        stream: nil,
        read: 0,
        body: nil
      }

      try do
        with :ok <- send_request(socket, state, method, headers, encode(message)),
             {:ok, status, response_headers, rest} <- read_head(conn, "", 0) do
          if on_headers, do: on_headers.(response_headers)
          conn = %{conn | body: body_state(response_headers)}

          case read_body(conn, status, response_headers, rest) do
            {:ok, conn} -> {:ok, status, finish(conn)}
            {:done, response} -> {:ok, status, {:response, response}}
            {:error, reason} -> {:error, reason}
          end
        end
      after
        close_socket(socket)
      end
    end
  end

  defp response({:ok, _status, {:response, response}}, _timeout, _limit), do: {:ok, response}
  defp response({:ok, status, {:body, body}}, _timeout, _limit), do: decode_json(status, body)

  defp response({:ok, status, {:unmatched, sample}}, _timeout, _limit),
    do: unexpected(status, sample)

  defp response({:error, {:timeout, deadline}}, _timeout, _limit),
    do: {:error, Deadline.error(deadline)}

  defp response({:error, :timeout}, timeout, _limit),
    do: {:error, Transport.timeout_error(timeout)}

  defp response({:error, :too_large}, _timeout, limit) do
    {:error,
     Transport.connection_error(
       "The HTTP response exceeds the #{limit}-byte limit",
       {:max_response_bytes, limit}
     )}
  end

  defp response({:error, :malformed}, _timeout, _limit),
    do: {:error, Transport.connection_error("The HTTP response is malformed", :malformed)}

  defp response({:error, reason}, _timeout, _limit),
    do: {:error, Transport.connection_error("The HTTP request failed", reason)}

  defp open(%{scheme: "http"} = state, connect_timeout, timeout) do
    options = state.socket_options ++ send_timeout(timeout)

    case :gen_tcp.connect(state.host, state.port, options, connect_timeout) do
      {:ok, socket} -> {:ok, {:gen_tcp, socket}}
      {:error, reason} -> {:error, {:failed_connect, reason}}
    end
  end

  defp open(%{scheme: "https"} = state, connect_timeout, timeout) do
    options = state.socket_options ++ send_timeout(timeout) ++ state.ssl

    case :ssl.connect(state.host, state.port, options, connect_timeout) do
      {:ok, socket} -> {:ok, {:ssl, socket}}
      {:error, reason} -> {:error, {:failed_connect, reason}}
    end
  end

  defp send_timeout(:infinity), do: []
  defp send_timeout(timeout), do: [send_timeout: timeout]

  defp encode(nil), do: ""
  defp encode(message), do: JSON.encode!(message)

  defp send_request({module, socket}, state, method, headers, body) do
    head = [
      method,
      " ",
      state.target,
      " HTTP/1.1\r\nhost: ",
      state.authority,
      "\r\n",
      Enum.map(headers, fn {name, value} -> [name, ": ", value, "\r\n"] end),
      "content-length: ",
      Integer.to_string(byte_size(body)),
      "\r\nconnection: close\r\n\r\n"
    ]

    module.send(socket, [head, body])
  end

  # `consumed` counts the head bytes already parsed. When a line is
  # incomplete, the whole buffer is head bytes, so it is checked before each
  # read.
  defp read_head(conn, buffer, consumed) do
    case :erlang.decode_packet(:http_bin, buffer, []) do
      {:ok, {:http_response, _version, status, _reason}, rest} ->
        consumed = consumed + byte_size(buffer) - byte_size(rest)
        read_headers(conn, rest, consumed, status, [])

      {:more, _length} ->
        with {:ok, buffer} <- recv_head(conn, buffer, consumed) do
          read_head(conn, buffer, consumed)
        end

      _invalid ->
        {:error, :malformed}
    end
  end

  defp read_headers(conn, buffer, consumed, status, headers) do
    case :erlang.decode_packet(:httph_bin, buffer, []) do
      {:ok, {:http_header, _index, _field, name, value}, rest} ->
        consumed = consumed + byte_size(buffer) - byte_size(rest)
        headers = [{String.downcase(name), value} | headers]
        read_headers(conn, rest, consumed, status, headers)

      {:ok, :http_eoh, rest} ->
        consumed = consumed + byte_size(buffer) - byte_size(rest)
        end_of_head(conn, rest, consumed, status, Enum.reverse(headers))

      {:more, _length} ->
        with {:ok, buffer} <- recv_head(conn, buffer, consumed) do
          read_headers(conn, buffer, consumed, status, headers)
        end

      _invalid ->
        {:error, :malformed}
    end
  end

  # An interim 1xx response precedes the final one on the same connection.
  defp end_of_head(conn, rest, consumed, status, headers) do
    cond do
      consumed > conn.limit -> {:error, :too_large}
      status in 100..199 -> read_head(conn, rest, consumed)
      true -> {:ok, status, headers, rest}
    end
  end

  defp recv_head(conn, buffer, consumed) do
    if consumed + byte_size(buffer) > conn.limit do
      {:error, :too_large}
    else
      with {:ok, data} <- recv(conn), do: {:ok, buffer <> data}
    end
  end

  # The body readers pass each piece of the body to `feed/2` as it arrives,
  # and end with `{:ok, conn}` at the end of the body, `{:done, response}` when
  # an event stream has delivered the response, or `{:error, reason}`.
  defp read_body(conn, status, headers, rest) do
    case framing(status, headers) do
      :chunked -> read_chunks(conn, rest)
      {:length, length} when length > conn.limit -> {:error, :too_large}
      {:length, length} -> read_length(conn, rest, length)
      :close -> read_to_close(conn, {:ok, rest})
      :malformed -> {:error, :malformed}
    end
  end

  # RFC 9112 section 6.3: 204 and 304 have no body, a chunked final transfer
  # coding wins over Content-Length, any other transfer coding runs until the
  # connection closes, and otherwise Content-Length gives the length.
  defp framing(status, _headers) when status in [204, 304], do: {:length, 0}

  defp framing(_status, headers) do
    codings =
      for {"transfer-encoding", value} <- headers,
          coding <- String.split(value, ","),
          do: coding |> String.trim() |> String.downcase()

    lengths = for {"content-length", value} <- headers, do: String.trim(value)

    cond do
      codings != [] and List.last(codings) == "chunked" -> :chunked
      codings != [] -> :close
      lengths == [] -> :close
      true -> content_length(Enum.uniq(lengths))
    end
  end

  defp content_length([value]) when byte_size(value) in 1..18 do
    case Integer.parse(value) do
      {length, ""} when length >= 0 -> {:length, length}
      _invalid -> :malformed
    end
  end

  defp content_length(_values), do: :malformed

  defp read_length(conn, data, length) when byte_size(data) >= length,
    do: feed(conn, binary_part(data, 0, length))

  defp read_length(conn, data, length) do
    with {:ok, conn} <- feed(conn, data),
         {:ok, more} <- recv(conn) do
      read_length(conn, more, length - byte_size(data))
    end
  end

  defp read_to_close(conn, {:ok, data}) do
    with {:ok, conn} <- feed(conn, data), do: read_to_close(conn, recv(conn))
  end

  defp read_to_close(conn, {:error, :closed}), do: {:ok, conn}
  defp read_to_close(_conn, {:error, reason}), do: {:error, reason}

  # Each chunk's size is checked against the running total before its data is
  # read. Trailers after the last chunk are not read; the connection closes.
  defp read_chunks(conn, buffer) do
    case :binary.split(buffer, "\r\n") do
      [line, rest] ->
        case chunk_size(line) do
          {:ok, 0} -> {:ok, conn}
          {:ok, size} when conn.read + size > conn.limit -> {:error, :too_large}
          {:ok, size} -> read_chunk(conn, rest, size)
          :malformed -> {:error, :malformed}
        end

      [_partial] when byte_size(buffer) > @max_chunk_line_bytes ->
        {:error, :malformed}

      [_partial] ->
        with {:ok, data} <- recv(conn), do: read_chunks(conn, buffer <> data)
    end
  end

  # The chunk's data is followed by CRLF.
  defp read_chunk(conn, buffer, size) when byte_size(buffer) >= size + 2 do
    case binary_part(buffer, size, byte_size(buffer) - size) do
      "\r\n" <> rest ->
        with {:ok, conn} <- feed(conn, binary_part(buffer, 0, size)),
             do: read_chunks(conn, rest)

      _missing_delimiter ->
        {:error, :malformed}
    end
  end

  defp read_chunk(conn, buffer, size) do
    with {:ok, data} <- recv(conn), do: read_chunk(conn, buffer <> data, size)
  end

  defp chunk_size(line) do
    [size | _extensions] = :binary.split(line, ";")
    size = String.trim(size)

    with true <- byte_size(size) in 1..15,
         {value, ""} when value >= 0 <- Integer.parse(size, 16) do
      {:ok, value}
    else
      _invalid -> :malformed
    end
  end

  # The recv timeout is the time left until the deadline, which progress can
  # move, so a timeout reports the deadline it ran into.
  defp recv(%{socket: {module, socket}, deadline: deadline}) do
    case module.recv(socket, 0, Deadline.remaining(deadline)) do
      {:error, :timeout} -> {:error, {:timeout, deadline}}
      result -> result
    end
  end

  # A JSON body is held until it ends. An event stream is split into events
  # as it arrives; `scanned` is how much of the partial event has already been
  # searched for a boundary, so each byte is searched about once, and `sample`
  # keeps the start of the stream for the error when no response arrives.
  defp body_state(headers) do
    if event_stream?(headers),
      do: {:events, "", 0, ""},
      else: {:buffer, ""}
  end

  # The limit counts every body byte, notifications included.
  defp feed(conn, data) do
    read = conn.read + byte_size(data)

    if read > conn.limit,
      do: {:error, :too_large},
      else: consume(%{conn | read: read}, data)
  end

  defp consume(%{body: {:buffer, body}} = conn, data),
    do: {:ok, %{conn | body: {:buffer, body <> data}}}

  defp consume(%{body: {:events, buffer, scanned, sample}} = conn, data) do
    sample = sample <> binary_part(data, 0, min(byte_size(data), 512 - byte_size(sample)))
    next_event(%{conn | body: {:events, buffer <> data, scanned, sample}})
  end

  defp next_event(%{body: {:events, buffer, scanned, sample}} = conn) do
    # A boundary of up to 4 bytes can straddle the previous search's end.
    from = max(scanned - 3, 0)

    case :binary.match(buffer, ["\r\n\r\n", "\n\n"], scope: {from, byte_size(buffer) - from}) do
      :nomatch ->
        {:ok, %{conn | body: {:events, buffer, byte_size(buffer), sample}}}

      {start, length} ->
        rest = binary_part(buffer, start + length, byte_size(buffer) - start - length)
        conn = %{conn | body: {:events, rest, 0, sample}, read: event_bytes_read(conn, rest)}

        case event(conn, binary_part(buffer, 0, start)) do
          {:response, response} -> {:done, response}
          {:ok, conn} -> next_event(conn)
        end
    end
  end

  # A subscription stream has no end, so its limit counts one event at a time.
  defp event_bytes_read(%{stream: nil, read: read}, _rest), do: read
  defp event_bytes_read(_conn, rest), do: byte_size(rest)

  # A stream may end without a blank line after its last event.
  defp finish(%{body: {:buffer, body}}), do: {:body, body}

  defp finish(%{body: {:events, buffer, _scanned, sample}} = conn) do
    case event(conn, buffer) do
      {:response, response} -> {:response, response}
      {:ok, _conn} -> {:unmatched, sample}
    end
  end

  defp event(conn, event) do
    event |> event_data() |> Snodo.JSONValue.decode() |> handle_event(conn)
  end

  defp event_data(event) do
    event
    |> String.split(["\r\n", "\n"])
    |> Enum.flat_map(fn
      "data:" <> value -> [String.trim_leading(value, " ")]
      _other_field -> []
    end)
    |> Enum.join("\n")
  end

  # A subscription stream hands every message to its process.
  defp handle_event({:ok, message}, %{stream: stream} = conn)
       when is_map(message) and is_pid(stream) do
    send(stream, {:mcp_stream_message, message})
    {:ok, %{conn | deadline: Deadline.new(timeout: :infinity)}}
  end

  defp handle_event({:ok, %{"id" => id} = response}, %{id: expected})
       when id == expected and not is_map_key(response, "method") do
    {:response, response}
  end

  defp handle_event(
         {:ok,
          %{
            "method" => "notifications/progress",
            "params" => %{"progressToken" => token} = params
          }},
         %{token: expected} = conn
       )
       when not is_nil(token) and token == expected do
    conn.on_progress.(params)
    {:ok, %{conn | deadline: Deadline.extend(conn.deadline)}}
  end

  defp handle_event(
         {:ok, %{"id" => id, "method" => method} = request},
         %{on_server_request: responder} = conn
       )
       when not is_nil(id) and is_binary(method) and is_function(responder, 1) do
    answer_server_request(conn, request)
    {:ok, conn}
  end

  defp handle_event(_other, conn), do: {:ok, conn}

  # The server waits for the answer before it finishes the request in flight,
  # so the answer goes out on its own connection before the stream is read
  # further. A refused answer surfaces as the failure of the request in
  # flight, which the server then cannot complete.
  defp answer_server_request(conn, request) do
    {state, session_headers, opts} = conn.reply
    response = conn.on_server_request.(request)
    _outcome = deliver(state, message_headers(%Policy{}) ++ session_headers, response, opts)
    :ok
  end

  defp decode_json(status, body) do
    case Snodo.JSONValue.decode(body) do
      {:ok, %{"jsonrpc" => "2.0"} = response} -> {:ok, response}
      _other -> unexpected(status, body)
    end
  end

  defp event_stream?(headers) do
    Enum.any?(headers, fn {name, value} ->
      name == "content-type" and
        value |> String.downcase() |> String.starts_with?("text/event-stream")
    end)
  end

  defp unexpected(status, body) do
    {:error,
     Transport.connection_error(
       "The HTTP response was not a JSON-RPC message",
       {:http_status, status, binary_part(body, 0, min(byte_size(body), 512))}
     )}
  end

  defp authority(%URI{scheme: scheme, host: host, port: port}) do
    host = if String.contains?(host, ":"), do: "[#{host}]", else: host
    if Map.fetch!(@default_ports, scheme) == port, do: host, else: "#{host}:#{port}"
  end

  defp target(%URI{path: path, query: query}) do
    path = if path in [nil, ""], do: "/", else: path
    if query, do: path <> "?" <> query, else: path
  end

  # An IPv6 literal needs the inet6 family; a host name resolves over IPv4.
  defp socket_options(host) do
    case :inet.parse_ipv6strict_address(String.to_charlist(host)) do
      {:ok, _address} -> [:inet6 | @socket_options]
      {:error, _not_ipv6} -> @socket_options
    end
  end

  defp default_ssl(%URI{scheme: "https"}) do
    [
      verify: :verify_peer,
      cacerts: :public_key.cacerts_get(),
      depth: 4,
      customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
    ]
  end

  defp default_ssl(%URI{}), do: []
end
