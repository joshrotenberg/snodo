defmodule Snodo.Client.HTTP do
  @moduledoc """
  Streamable HTTP transport for `Snodo.Client.connect({:http, url}, opts)`.

  Requests use a bounded pool of HTTP/1.1 `:gen_tcp` or `:ssl` connections.
  Fully read, framed responses can return their connection to the pool;
  streams and responses that run until socket close do not. The request
  headers come from the protocol dialect's
  `transport_policy/1`. For a request made with `extension: Module`, the
  module's `transport_policy/2` adapts that policy for its exact-versioned
  method. These are the same declarations the server admits requests against:
  the accepted and request media types, and every mirrored header
  (for `2026-07-28`, `MCP-Protocol-Version`, `Mcp-Method`, and `Mcp-Name`) read
  from the request body. A mirrored value that is not plain printable ASCII is
  sent in the `=?base64?...?=` form when the policy allows it. A header value
  that contains CR, LF, or NUL is refused with a -32000 transport error, and
  so is a request-level `:headers` entry that names a header the transport
  owns (see the `:headers` option).

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
  option such a request is dropped. If that `POST` fails, refused by the
  server or by the connection, the request in flight fails at once with a
  -32000 transport error whose `cause` is that failure. The time the function takes counts
  against the request's timeout, which is not extended. Other notifications
  are dropped. A JSON-RPC error body is returned whatever the HTTP status, so
  `Snodo.Client` decodes it as `{:error, %Snodo.Error{}}`. Anything else is a
  -32000 transport error with the status and body in `cause`. A timeout closes
  the connection, which the server treats as cancellation.

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
  For a request, an event stream is one body, so the limit applies to the
  whole stream, notifications included; a subscription stream is limited
  per event, as described above. The status line and headers are held to the same
  limit. Over the limit the connection is closed and the request returns a
  -32000 transport error with `cause: {:max_response_bytes, limit}`.

  Options:

    * `:headers` - extra request headers as `{name, value}` string pairs, for
      example `[{"authorization", "Bearer " <> token}]`. The transport owns
      `host`, `content-type`, `content-length`, `transfer-encoding`, and
      `connection`, and refuses them here; with `:token_provider` it owns
      `authorization` too.
    * `:token_provider` - `{module, state}`, a `Snodo.Client.TokenProvider`
      that supplies the bearer token. The transport asks it for a token
      before each request, notification, answer to a server request, and
      session `DELETE`, and before opening each `subscriptions/listen` stream.
      After a `401`, or a `403` whose `WWW-Authenticate` challenge is
      `insufficient_scope`, it asks the provider to refresh with the parsed
      `Snodo.Client.Challenge` and sends the request once more. A `401` or
      `403` on that second attempt is a -32000 transport error with
      `cause: {:unauthorized, status, challenge}`. Without a provider, those
      statuses are returned as any other unexpected status. The request
      timeout covers each HTTP attempt, not the provider calls before and
      between them.
    * `:ssl` - `:ssl` client options for `https` URLs. The default verifies the
      peer against `:public_key.cacerts_get/0` and checks the host name.
    * `:connect_timeout` - milliseconds to establish the connection. Defaults
      to the request timeout.
    * `:max_response_bytes` - the largest response to accept, default 16 MiB,
      the stdio client's line limit.
    * `:pool_size` - the most simultaneous pooled requests for this client
      origin, default 4. Additional requests wait up to their request timeout.
      Event streams detach from the pool and use a separate socket.
    * `:pool_idle_timeout` - milliseconds an idle connection may wait for
      reuse, default 30,000.
    * `:pool_max_requests` - the most requests sent on one connection before
      it is retired, default 100.
  """

  @behaviour Snodo.Client.Transport

  alias Snodo.Client.Challenge
  alias Snodo.Client.Deadline
  alias Snodo.Client.HTTP.Pool
  alias Snodo.Client.HTTP.Stream, as: SubscriptionStream
  alias Snodo.Client.Transport
  alias Snodo.Envelope
  alias Snodo.Extension.Method, as: ExtensionMethod
  alias Snodo.Transport.Context, as: TransportContext
  alias Snodo.Transport.ParamHeaders
  alias Snodo.Transport.Policy

  @type state :: %{
          url: String.t(),
          scheme: String.t(),
          host: charlist(),
          port: :inet.port_number(),
          authority: String.t(),
          target: String.t(),
          socket_options: [:gen_tcp.connect_option()],
          headers: [{String.t(), String.t()}],
          ssl: keyword(),
          connect_timeout: timeout() | nil,
          max_response_bytes: pos_integer(),
          pool_key: term(),
          pool_size: pos_integer(),
          pool_idle_timeout: pos_integer(),
          pool_max_requests: pos_integer(),
          token_provider: {module(), term()} | nil
        }

  @sentinel_prefix "=?base64?"
  @sentinel_suffix "?="
  @default_max_response_bytes 16 * 1024 * 1024
  @default_pool_size 4
  @default_pool_idle_timeout 30_000
  @default_pool_max_requests 100
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

    provider = token_provider!(Keyword.get(opts, :token_provider))
    headers = extra_headers!(Keyword.get(opts, :headers, []), provider)
    pool_size = positive_option!(opts, :pool_size, @default_pool_size)
    pool_idle_timeout = positive_option!(opts, :pool_idle_timeout, @default_pool_idle_timeout)
    pool_max_requests = positive_option!(opts, :pool_max_requests, @default_pool_max_requests)

    case URI.new(url) do
      {:ok, %URI{scheme: scheme, host: host} = uri}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        {:ok, _started} = Application.ensure_all_started(:ssl)

        {:ok,
         %{
           url: url,
           scheme: scheme,
           host: String.to_charlist(host),
           port: uri.port,
           authority: authority(uri),
           target: target(uri),
           socket_options: socket_options(host),
           headers: headers,
           ssl: Keyword.get_lazy(opts, :ssl, fn -> default_ssl(uri) end),
           connect_timeout: Keyword.get(opts, :connect_timeout),
           max_response_bytes: max_response_bytes,
           pool_key: {scheme, host, uri.port, make_ref()},
           pool_size: pool_size,
           pool_idle_timeout: pool_idle_timeout,
           pool_max_requests: pool_max_requests,
           token_provider: provider
         }}

      _invalid ->
        {:error, Transport.connection_error("Expected an http or https URL", url)}
    end
  end

  @impl Transport
  def request(state, message, opts) when is_map(message) do
    timeout = Keyword.fetch!(opts, :timeout)
    extra = Keyword.get(opts, :headers, [])

    with {:ok, policy} <- request_policy(Keyword.fetch!(opts, :dialect), message, opts),
         {:ok, headers} <- request_headers(policy, message, opts, extra),
         :ok <- check_headers(headers),
         :ok <- check_owned(state, extra) do
      state
      |> authorized_exchange("POST", headers ++ state.headers, message, opts)
      |> report_headers(Keyword.get(opts, :on_response_headers))
      |> response(timeout, state.max_response_bytes)
    end
  end

  @impl Transport
  def notify(state, message, opts) when is_map(message) do
    policy = policy(Keyword.fetch!(opts, :dialect), message)

    extra = Keyword.get(opts, :headers, [])
    headers = message_headers(policy) ++ mirrored_headers(policy, message) ++ extra

    with :ok <- check_owned(state, extra), do: deliver(state, headers, message, opts)
  end

  @impl Transport
  def delete_session(state, opts) do
    headers = Keyword.get(opts, :headers, [])

    _outcome =
      with :ok <- check_headers(headers),
           :ok <- check_owned(state, headers) do
        authorized_exchange(state, "DELETE", headers ++ state.headers, nil, opts)
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

    with :ok <- check_headers(headers) do
      listen_authorized(state, headers ++ state.headers, message, opts)
    end
  end

  @impl Transport
  def close(state), do: Pool.close(state.pool_key)

  @doc false
  def cache_variant(%{headers: headers, max_response_bytes: max_response_bytes, ssl: ssl}) do
    variant_headers =
      Enum.reject(headers, fn {name, _value} ->
        String.downcase(name) in ["authorization", "cookie"]
      end)

    :crypto.hash(:sha256, :erlang.term_to_binary({variant_headers, max_response_bytes, ssl}))
  end

  @doc false
  def cache_credential(%{token_provider: nil, headers: headers, ssl: ssl}),
    do: {:ok, credential_digest(headers, nil, ssl), nil}

  def cache_credential(%{
        token_provider: {module, provider},
        headers: headers,
        ssl: ssl,
        url: url
      }) do
    with {:ok, token} <- provider_token(module, :token, module.token(provider, %{url: url})) do
      {:ok, credential_digest(headers, token, ssl), token}
    end
  end

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
               {:ok, status, response_headers, rest, _version} <- read_head(conn, "", 0),
               :none <- challenge(state, status, response_headers) do
            conn = %{conn | body: body_state(response_headers)}

            with {:ok, conn} <- read_body(conn, status, response_headers, rest),
                 {:ok, outcome} <- finish(conn) do
              {:ok, status, outcome}
            end
          end
        after
          close_socket(socket)
        end
      end

    send(stream, {:mcp_stream_end, stream_outcome(outcome, timeout, state.max_response_bytes)})
    :ok
  end

  defp stream_outcome({:challenge, _status, _challenge} = challenge, _timeout, _limit),
    do: challenge

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

  defp request_policy(dialect, message, opts) do
    {:ok, envelope} = Envelope.decode(message, %TransportContext{transport: :streamable_http})
    %Policy{} = base_policy = dialect.transport_policy(envelope)

    case Keyword.get(opts, :extension) do
      nil -> {:ok, base_policy}
      extension -> extension_policy(extension, dialect.version(), envelope, base_policy)
    end
  end

  defp extension_policy(extension, version, envelope, base_policy) do
    if extension_route?(extension, version, envelope.method) do
      if function_exported?(extension, :transport_policy, 2) do
        try do
          case extension.transport_policy(envelope, base_policy) do
            %Policy{} = policy -> {:ok, policy}
            _invalid -> invalid_extension_policy(extension)
          end
        rescue
          _error -> invalid_extension_policy(extension)
        catch
          _kind, _reason -> invalid_extension_policy(extension)
        end
      else
        {:ok, base_policy}
      end
    else
      invalid_extension_policy(extension)
    end
  end

  defp extension_route?(extension, version, method) when is_atom(extension) do
    Code.ensure_loaded?(extension) and function_exported?(extension, :methods, 0) and
      Enum.any?(extension.methods(), fn
        %ExtensionMethod{protocol_version: ^version, name: ^method} -> true
        _other -> false
      end)
  rescue
    _error -> false
  catch
    _kind, _reason -> false
  end

  defp extension_route?(_extension, _version, _method), do: false

  defp invalid_extension_policy(extension),
    do: {:error, Transport.connection_error("Invalid extension transport policy", extension)}

  defp request_headers(policy, message, opts, extra) do
    case Keyword.fetch(opts, :extension) do
      :error ->
        {:ok, build_request_headers(policy, message, opts, extra)}

      {:ok, extension} ->
        try do
          {:ok, build_request_headers(policy, message, opts, extra)}
        rescue
          _error -> invalid_extension_policy(extension)
        catch
          _kind, _reason -> invalid_extension_policy(extension)
        end
    end
  end

  defp build_request_headers(policy, message, opts, extra) do
    message_headers(policy) ++
      mirrored_headers(policy, message) ++
      parameter_headers(policy, message, Keyword.get(opts, :tool)) ++ extra
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

  # Request-level headers may not set what the transport writes itself, the
  # same rule `connect/2` applies to `:headers`.
  defp check_owned(state, headers) do
    owned = if state.token_provider, do: ["authorization" | @owned_headers], else: @owned_headers

    case Enum.find(headers, &owned_header?(&1, owned)) do
      nil -> :ok
      {name, _value} -> invalid_header(name)
    end
  end

  defp owned_header?({name, _value}, owned) when is_binary(name),
    do: String.downcase(name) in owned

  defp owned_header?(_header, _owned), do: false

  # A message that gets no JSON-RPC response: a notification, or the client's
  # answer to a server request. The server accepts it with a 2xx and no body,
  # or refuses it with an error body.
  defp deliver(state, headers, message, opts) do
    timeout = Keyword.fetch!(opts, :timeout)

    with :ok <- check_headers(headers) do
      case authorized_exchange(state, "POST", headers ++ state.headers, message, opts) do
        {:ok, status, _headers, _body} when status in 200..299 -> :ok
        {:ok, status, _headers, {:body, body}} -> refused(status, body)
        {:ok, status, _headers, {:unmatched, sample}} -> unexpected(status, sample)
        {:ok, status, _headers, {:response, response}} -> refused(status, JSON.encode!(response))
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

  defp extra_headers!(headers, provider) do
    unless is_list(headers) and Enum.all?(headers, &valid_extra_header?/1) do
      raise ArgumentError,
            ":headers must be {name, value} string pairs without CR, LF, or NUL, " <>
              "and without #{Enum.join(@owned_headers, ", ")}; got: #{inspect(headers)}"
    end

    if provider != nil and
         Enum.any?(headers, fn {name, _value} -> String.downcase(name) == "authorization" end) do
      raise ArgumentError, ":headers cannot set authorization when :token_provider is given"
    end

    headers
  end

  defp positive_option!(opts, name, default) do
    value = Keyword.get(opts, name, default)

    if is_integer(value) and value > 0 do
      value
    else
      raise ArgumentError, ":#{name} must be a positive integer"
    end
  end

  defp token_provider!(nil), do: nil

  defp token_provider!({module, _state} = provider) when is_atom(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :token, 2) and
         function_exported?(module, :refresh, 3) do
      provider
    else
      raise ArgumentError,
            ":token_provider must be {module, state} with a Snodo.Client.TokenProvider " <>
              "module, got: #{inspect(module)}"
    end
  end

  defp token_provider!(other) do
    raise ArgumentError, ":token_provider must be {module, state}, got: #{inspect(other)}"
  end

  # A nil message sends no body (DELETE).
  defp exchange(state, method, headers, message, opts) do
    timeout = Keyword.fetch!(opts, :timeout)

    with {:ok, socket, lease} <- checkout_socket(state, timeout) do
      try do
        {result, reusable?} =
          perform_exchange(state, socket, lease, method, headers, message, opts)

        if reusable?, do: Pool.checkin(lease, socket), else: Pool.discard(lease, socket)
        result
      catch
        kind, reason ->
          Pool.discard(lease, socket)
          :erlang.raise(kind, reason, __STACKTRACE__)
      end
    end
  end

  defp checkout_socket(state, timeout) do
    limits = {state.pool_size, state.pool_idle_timeout, state.pool_max_requests}

    case Pool.checkout(state.pool_key, limits, timeout) do
      {:ok, socket, lease} ->
        case set_send_timeout(socket, timeout) do
          :ok ->
            {:ok, socket, lease}

          {:error, reason} ->
            Pool.discard(lease, socket)
            {:error, reason}
        end

      {:open, lease} ->
        case open(state, state.connect_timeout || timeout, timeout) do
          {:ok, socket} ->
            {:ok, socket, lease}

          {:error, reason} ->
            Pool.discard(lease, nil)
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp set_send_timeout({:gen_tcp, socket}, timeout),
    do: :inet.setopts(socket, send_timeout: timeout)

  defp set_send_timeout({:ssl, socket}, timeout),
    do: :ssl.setopts(socket, send_timeout: timeout)

  defp perform_exchange(state, socket, lease, method, headers, message, opts) do
    on_progress = Keyword.get(opts, :on_progress)

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
      body: nil,
      extra_bytes?: false
    }

    with :ok <- send_request(socket, state, method, headers, encode(message), "keep-alive"),
         {:ok, status, response_headers, rest, version} <- read_head(conn, "", 0) do
      if event_stream?(response_headers), do: Pool.detach(lease)
      conn = %{conn | body: body_state(response_headers)}

      conn
      |> read_body(status, response_headers, rest)
      |> exchange_body_result(status, response_headers, version)
    else
      {:error, reason} -> {{:error, reason}, false}
    end
  end

  defp exchange_body_result({:ok, conn}, status, headers, version) do
    case finish(conn) do
      {:ok, outcome} ->
        {{:ok, status, headers, outcome}, reusable?(conn, version, status, headers)}

      {:error, reason} ->
        {{:error, reason}, false}
    end
  end

  defp exchange_body_result({:done, response}, status, headers, _version),
    do: {{:ok, status, headers, {:response, response}}, false}

  defp exchange_body_result({:error, reason}, _status, _headers, _version),
    do: {{:error, reason}, false}

  defp reusable?(conn, {1, 1}, status, headers) do
    match?({:length, _length}, framing(status, headers)) and
      not event_stream?(headers) and not conn.extra_bytes? and
      not connection_close?(headers)
  end

  defp reusable?(_conn, _version, _status, _headers), do: false

  defp connection_close?(headers) do
    Enum.any?(headers, fn
      {"connection", value} ->
        value
        |> String.downcase()
        |> String.split(",")
        |> Enum.any?(&(String.trim(&1) == "close"))

      _other ->
        false
    end)
  end

  # Only the attempt that answered the request is reported, not one that a
  # challenge sent back to the token provider.
  defp report_headers({:ok, _status, headers, _outcome} = result, on_headers)
       when is_function(on_headers, 1) do
    on_headers.(headers)
    result
  end

  defp report_headers(result, _on_headers), do: result

  defp response({:ok, _status, _headers, {:response, response}}, _timeout, _limit),
    do: {:ok, response}

  defp response({:ok, status, _headers, {:body, body}}, _timeout, _limit),
    do: decode_json(status, body)

  defp response({:ok, status, _headers, {:unmatched, sample}}, _timeout, _limit),
    do: unexpected(status, sample)

  defp response({:error, %Snodo.Error{}} = error, _timeout, _limit), do: error

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

  # One exchange, with the provider's token when there is one. Returns the
  # exchange's outcome, or an error from the provider or from a second
  # challenge.
  defp authorized_exchange(%{token_provider: nil} = state, method, headers, message, opts) do
    result = exchange(state, method, headers, message, opts)
    report_credential(opts, state, nil, result)
    result
  end

  defp authorized_exchange(state, method, headers, message, opts) do
    attempt = fn token ->
      result = attempt(state, method, headers, message, opts, token)
      report_credential(opts, state, token, result)
      result
    end

    case Keyword.fetch(opts, :cache_token) do
      {:ok, token} -> authorized(state, attempt, token)
      :error -> authorized(state, attempt)
    end
  end

  defp report_credential(opts, state, token, {:ok, _status, _headers, _outcome}) do
    if callback = Keyword.get(opts, :on_cache_credential) do
      callback.(credential_digest(state.headers, token, state.ssl))
    end

    :ok
  end

  defp report_credential(_opts, _state, _token, _outcome), do: :ok

  defp credential_digest(headers, token, ssl),
    do: :crypto.hash(:sha256, :erlang.term_to_binary({headers, token, ssl}))

  defp listen_authorized(%{token_provider: nil} = state, headers, message, opts),
    do: SubscriptionStream.open(state, headers, message, opts)

  defp listen_authorized(state, headers, message, opts) do
    authorized(state, &SubscriptionStream.open(state, bearer(&1) ++ headers, message, opts))
  end

  # One request or stream may need two attempts: the first learns that the
  # token is missing, expired, or short of scope, and the second carries the
  # token the provider obtained from that challenge. A third is never made,
  # so a server that keeps refusing cannot loop a client through its
  # authorization flow. `attempt` sends with a token and returns
  # `{:challenge, status, challenge}` or the result.
  defp authorized(state, attempt, initial_token \\ :fetch)

  defp authorized(%{token_provider: {module, provider}} = state, attempt, initial_token) do
    context = %{url: state.url}

    initial =
      if initial_token == :fetch,
        do: provider_token(module, :token, module.token(provider, context)),
        else: provider_token(module, :token, {:ok, initial_token})

    with {:ok, token} <- initial,
         {:challenge, status, challenge} <- attempt.(token),
         context = Map.merge(context, %{status: status, token: token}),
         {:ok, token} <-
           provider_token(module, :refresh, module.refresh(provider, challenge, context)),
         {:challenge, status, challenge} <- attempt.(token) do
      {:error, authorization_error(status, challenge)}
    end
  end

  # One exchange with `token`: a challenge for the provider, or the
  # exchange's outcome.
  defp attempt(state, method, headers, message, opts, token) do
    case exchange(state, method, bearer(token) ++ headers, message, opts) do
      {:ok, status, response_headers, _outcome} = result ->
        case challenge(state, status, response_headers) do
          :none -> result
          challenge -> challenge
        end

      other ->
        other
    end
  end

  # A 401, or a 403 that asks for more scope, goes back to the token
  # provider. Without one, every status is the response.
  defp challenge(%{token_provider: nil}, _status, _headers), do: :none

  defp challenge(_state, status, headers) when status in [401, 403] do
    challenge = Challenge.select(headers)
    if refreshable?(status, challenge), do: {:challenge, status, challenge}, else: :none
  end

  defp challenge(_state, _status, _headers), do: :none

  defp refreshable?(401, _challenge), do: true
  defp refreshable?(403, %Challenge{error: "insufficient_scope"}), do: true
  defp refreshable?(_status, _challenge), do: false

  defp bearer(nil), do: []
  defp bearer(token), do: [{"authorization", "Bearer " <> token}]

  # The token is a credential, so neither error names it.
  defp provider_token(_module, :token, {:ok, nil}), do: {:ok, nil}

  defp provider_token(_module, _callback, {:ok, token}) when is_binary(token) do
    if token != "" and valid_header?({"authorization", token}) and
         not String.contains?(token, [" ", "\t"]) do
      {:ok, token}
    else
      {:error,
       Transport.connection_error("The token provider returned an invalid token", :invalid_token)}
    end
  end

  defp provider_token(_module, _callback, {:error, %Snodo.Error{} = error}), do: {:error, error}

  defp provider_token(module, callback, _other) do
    arity = if callback == :token, do: 2, else: 3

    raise ArgumentError,
          "#{inspect(module)}.#{callback}/#{arity} must return {:ok, token} or " <>
            "{:error, %Snodo.Error{}}" <> if(callback == :token, do: ", or {:ok, nil}", else: "")
  end

  defp authorization_error(status, challenge) do
    Transport.connection_error(
      "The server refused the request's authorization (HTTP #{status})",
      {:unauthorized, status, challenge}
    )
  end

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

  defp send_request(socket, state, method, headers, body, connection \\ "close")

  defp send_request({module, socket}, state, method, headers, body, connection) do
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
      "\r\nconnection: ",
      connection,
      "\r\n\r\n"
    ]

    module.send(socket, [head, body])
  end

  # `consumed` counts the head bytes already parsed. When a line is
  # incomplete, the whole buffer is head bytes, so it is checked before each
  # read.
  defp read_head(conn, buffer, consumed) do
    case :erlang.decode_packet(:http_bin, buffer, []) do
      {:ok, {:http_response, version, status, _reason}, rest} ->
        consumed = consumed + byte_size(buffer) - byte_size(rest)
        read_headers(conn, rest, consumed, status, [], version)

      {:more, _length} ->
        with {:ok, buffer} <- recv_head(conn, buffer, consumed) do
          read_head(conn, buffer, consumed)
        end

      _invalid ->
        {:error, :malformed}
    end
  end

  defp read_headers(conn, buffer, consumed, status, headers, version) do
    case :erlang.decode_packet(:httph_bin, buffer, []) do
      {:ok, {:http_header, _index, _field, name, value}, rest} ->
        consumed = consumed + byte_size(buffer) - byte_size(rest)
        headers = [{String.downcase(name), value} | headers]
        read_headers(conn, rest, consumed, status, headers, version)

      {:ok, :http_eoh, rest} ->
        consumed = consumed + byte_size(buffer) - byte_size(rest)
        end_of_head(conn, rest, consumed, status, Enum.reverse(headers), version)

      {:more, _length} ->
        with {:ok, buffer} <- recv_head(conn, buffer, consumed) do
          read_headers(conn, buffer, consumed, status, headers, version)
        end

      _invalid ->
        {:error, :malformed}
    end
  end

  # An interim 1xx response precedes the final one on the same connection.
  defp end_of_head(conn, rest, consumed, status, headers, version) do
    cond do
      consumed > conn.limit -> {:error, :too_large}
      status in 100..199 -> read_head(conn, rest, consumed)
      true -> {:ok, status, headers, rest, version}
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
      :chunked ->
        read_chunks(conn, rest)

      {:length, length} ->
        if over_limit?(conn, length),
          do: {:error, :too_large},
          else: read_length(conn, rest, length)

      :close ->
        read_to_close(conn, {:ok, rest})

      :malformed ->
        {:error, :malformed}
    end
  end

  # Whether `bytes` more of the body would pass the limit. A subscription's
  # event stream has no end, so its limit applies to each event as it is
  # split off (`next_event/1`), not to the body or to a chunk, which can hold
  # many events.
  defp over_limit?(conn, bytes), do: not per_event?(conn) and conn.read + bytes > conn.limit

  defp per_event?(%{stream: stream, body: {:events, _buffer, _scanned, _sample}}),
    do: is_pid(stream)

  defp per_event?(_conn), do: false

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

  defp read_length(conn, data, length) when byte_size(data) >= length do
    conn = if byte_size(data) > length, do: Map.put(conn, :extra_bytes?, true), else: conn
    feed(conn, binary_part(data, 0, length))
  end

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
          {:ok, size} -> start_chunk(conn, rest, size)
          :malformed -> {:error, :malformed}
        end

      [_partial] when byte_size(buffer) > @max_chunk_line_bytes ->
        {:error, :malformed}

      [_partial] ->
        with {:ok, data} <- recv(conn), do: read_chunks(conn, buffer <> data)
    end
  end

  defp start_chunk(conn, buffer, size) do
    if over_limit?(conn, size),
      do: {:error, :too_large},
      else: read_chunk(conn, buffer, size)
  end

  # The chunk's data is followed by CRLF. `size` is the part of the chunk's
  # data not yet fed; data is fed as it arrives, so a large chunk is not held
  # whole before its events are split off.
  defp read_chunk(conn, buffer, size) when byte_size(buffer) >= size + 2 do
    case binary_part(buffer, size, byte_size(buffer) - size) do
      "\r\n" <> rest ->
        with {:ok, conn} <- feed(conn, binary_part(buffer, 0, size)),
             do: read_chunks(conn, rest)

      _missing_delimiter ->
        {:error, :malformed}
    end
  end

  defp read_chunk(conn, buffer, size) when byte_size(buffer) > size do
    with {:ok, conn} <- feed(conn, binary_part(buffer, 0, size)),
         {:ok, data} <- recv(conn) do
      read_chunk(conn, binary_part(buffer, size, byte_size(buffer) - size) <> data, 0)
    end
  end

  defp read_chunk(conn, buffer, size) do
    with {:ok, conn} <- feed(conn, buffer),
         {:ok, data} <- recv(conn),
         do: read_chunk(conn, data, size - byte_size(buffer))
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

  # The limit counts every body byte, notifications included, except on a
  # subscription's event stream, where `next_event/1` checks each event.
  defp feed(conn, data) do
    cond do
      per_event?(conn) -> consume(conn, data)
      over_limit?(conn, byte_size(data)) -> {:error, :too_large}
      true -> consume(%{conn | read: conn.read + byte_size(data)}, data)
    end
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
        if per_event?(conn) and byte_size(buffer) > conn.limit,
          do: {:error, :too_large},
          else: {:ok, %{conn | body: {:events, buffer, byte_size(buffer), sample}}}

      {start, length} ->
        if per_event?(conn) and start + length > conn.limit,
          do: {:error, :too_large},
          else: split_event(conn, start, length)
    end
  end

  defp split_event(%{body: {:events, buffer, _scanned, sample}} = conn, start, length) do
    rest = binary_part(buffer, start + length, byte_size(buffer) - start - length)
    conn = %{conn | body: {:events, rest, 0, sample}}

    case event(conn, binary_part(buffer, 0, start)) do
      {:response, response} -> {:done, response}
      {:ok, conn} -> next_event(conn)
      {:error, reason} -> {:error, reason}
    end
  end

  # A stream may end without a blank line after its last event.
  defp finish(%{body: {:buffer, body}}), do: {:ok, {:body, body}}

  defp finish(%{body: {:events, buffer, _scanned, sample}} = conn) do
    case event(conn, buffer) do
      {:response, response} -> {:ok, {:response, response}}
      {:ok, _conn} -> {:ok, {:unmatched, sample}}
      {:error, reason} -> {:error, reason}
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
    with :ok <- answer_server_request(conn, request), do: {:ok, conn}
  end

  defp handle_event({:error, :duplicate_key}, _conn), do: {:error, :malformed}

  defp handle_event(_other, conn), do: {:ok, conn}

  # The server waits for the answer before it finishes the request in flight,
  # so the answer goes out on its own connection before the stream is read
  # further. An answer that is not delivered, refused by the server or lost to
  # a connection failure, fails the request in flight at once, since the
  # server then cannot complete it.
  defp answer_server_request(conn, request) do
    {state, session_headers, opts} = conn.reply
    response = conn.on_server_request.(request)

    case deliver(state, message_headers(%Policy{}) ++ session_headers, response, opts) do
      :ok ->
        :ok

      {:error, error} ->
        {:error,
         Transport.connection_error(
           "The answer to the server's #{request["method"]} request was not delivered",
           error
         )}
    end
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
