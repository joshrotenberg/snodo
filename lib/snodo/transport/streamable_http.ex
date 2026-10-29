defmodule Snodo.Transport.StreamableHTTP do
  @moduledoc """
  Protocol-driven adapter for stateless Streamable HTTP requests.

  The default dialect is 2026-07-28. Explicitly enabled initialize-era dialects
  share admission and execution. They run without HTTP sessions unless the
  caller passes a `Snodo.Session.Manager` as the `:sessions` option of
  `prepare/3`; see "Initialize-era sessions" below.

  `prepare/3` performs HTTP and mirrored-header admission without invoking an
  application handler. `execute/3` runs one prepared message through the shared
  synchronous server core. This split lets HTTP servers admit a request before
  submitting only application work to `Snodo.Server.Executor`.

  Complete JSON responses and long-lived SSE descriptors are deliberately
  transport-server agnostic so Plug, Bandit, Cowboy, or a custom listener can
  translate them without changing protocol code.

  ## Initialize-era sessions

  With `sessions: manager` (the configuration `Snodo.Session.Manager.config/1`
  returns) and `auth:` (the request's trusted auth value, or `nil`), requests
  of the initialize-era dialects belong to a `Snodo.Session`:

    * An `initialize` request starts a session. `execute/3` returns its ID in
      the `Mcp-Session-Id` response header when initialization succeeds, and
      ends the session otherwise. At the manager's `:max_sessions` the request
      gets 503.
    * Every later request, notification, and response must carry that header.
      A missing header is 400. An unknown or expired ID, or a session bound to
      a different principal, is 404 with JSON-RPC code -32001, and the client
      initializes again. An `MCP-Protocol-Version` that differs from the
      session's version is 400.
    * A JSON-RPC response object is routed to the server request waiting for
      it and answered with 202.
    * `DELETE` ends the session and is answered with 200.
    * `GET` with `Accept: text/event-stream` returns `{:standalone, session}`.
      The caller opens the session's standalone stream with
      `Snodo.Session.attach_stream/2` (409 if it already has one) and writes
      each `{:mcp_session_message, session, ref, message}` it receives as an
      SSE event, acknowledging it with `{:mcp_session_written, ref, result}`.
    * During `execute/3`, a handler's input requests are sent as
      server-to-client requests through the progress sink's owner, which
      receives `{:mcp_stream_message, sink_reference, message}` as a
      `GenServer.call/3` and replies `:ok` once the message is written on
      the request's event stream.

  2026-07-28 requests are never part of a session.
  """

  alias Snodo.Authorization
  alias Snodo.Envelope
  alias Snodo.Error
  alias Snodo.Extension.Registry, as: ExtensionRegistry
  alias Snodo.Protocol.Registry
  alias Snodo.Server
  alias Snodo.Server.Runtime
  alias Snodo.Session
  alias Snodo.Session.Exchange
  alias Snodo.Session.Manager
  alias Snodo.Tool
  alias Snodo.Transport.Context, as: TransportContext
  alias Snodo.Transport.ParamHeaders
  alias Snodo.Transport.Policy
  alias Snodo.Transport.StreamableHTTP.Prepared
  alias Snodo.Transport.StreamableHTTP.Request
  alias Snodo.Transport.StreamableHTTP.Response
  alias Snodo.Transport.StreamableHTTP.StreamResponse

  @json_content_type "application/json"
  @protocol_header "mcp-protocol-version"
  @session_header "mcp-session-id"
  @default_local_origin_hosts ["127.0.0.1", "localhost", "::1"]
  @error_statuses %{
    -32_700 => 400,
    -32_600 => 400,
    -32_601 => 404,
    -32_602 => 400,
    -32_603 => 500,
    -32_020 => 400,
    -32_021 => 400,
    -32_022 => 400
  }

  @type prepare_result ::
          {:ok, Prepared.t()} | {:response, Response.t()} | {:standalone, Session.t()}

  @doc """
  Admits and decodes one HTTP request without executing its MCP handler.

  Options are `:allowed_origin_hosts`, `:allowed_hosts`, and, for
  initialize-era sessions, `:sessions` and `:auth` (see the module
  documentation). `{:standalone, session}` is returned only with `:sessions`.
  """
  @spec prepare(Runtime.t(), Request.t(), keyword()) :: prepare_result()
  def prepare(%Runtime{} = runtime, %Request{} = request, opts \\ []) do
    sessions = Keyword.get(opts, :sessions)

    with :ok <- validate_http_method(request, sessions),
         :ok <- validate_origin(request, opts),
         :ok <- validate_host(request, opts) do
      prepare_method(runtime, request, opts, sessions)
    else
      {:http_error, status, %Error{} = error, id} ->
        {:response, error_response(status, error, id, sessions)}
    end
  rescue
    _exception -> {:response, error_response(500, Error.internal(), nil)}
  end

  defp prepare_method(runtime, %Request{method: "POST"} = request, opts, _sessions) do
    with :ok <- validate_content_type(request),
         :ok <- validate_accept(request),
         {:ok, raw} <- decode_body(request.body) do
      prepare_decoded(runtime, request, raw, opts)
    else
      {:http_error, status, %Error{} = error, id} ->
        {:response, error_response(status, error, id)}
    end
  end

  defp prepare_method(_runtime, %Request{method: "GET"} = request, opts, sessions) do
    with :ok <- validate_event_stream_accept(request),
         {:ok, session} <- admit_session(request, sessions, opts, nil),
         :ok <- validate_session_version(request, session, nil) do
      {:standalone, session}
    else
      {:http_error, status, %Error{} = error, id} ->
        {:response, error_response(status, error, id)}
    end
  end

  defp prepare_method(_runtime, %Request{method: "DELETE"} = request, opts, sessions) do
    case admit_session(request, sessions, opts, nil) do
      {:ok, session} ->
        :ok = Session.close(session.pid)
        {:response, %Response{status: 200}}

      {:http_error, status, %Error{} = error, id} ->
        {:response, error_response(status, error, id)}
    end
  end

  # The body is decoded once; errors after this point answer with its id.
  defp prepare_decoded(runtime, request, raw, opts) do
    with :ok <- route_response_object(raw, request, opts),
         transport = transport_context(request),
         {:ok, envelope} <- decode_envelope(raw, transport),
         {:ok, protocol} <- select_protocol(runtime, envelope),
         base_policy = protocol.transport_policy(envelope),
         {:ok, policy} <-
           ExtensionRegistry.transport_policy(
             runtime.extension_registry,
             protocol.version(),
             envelope,
             runtime.capabilities,
             base_policy
           ),
         :ok <- validate_policy(request, raw, policy, envelope.id),
         {tool_mirrors, tool_authorization} =
           tool_parameter_mirrors(policy, runtime, protocol.version(), envelope),
         {:ok, deferred} <-
           validate_tool_mirrors(request, raw, tool_mirrors, tool_authorization, envelope.id),
         {:ok, session, new_session?} <- session_for(runtime, request, envelope, protocol, opts) do
      {:ok,
       %Prepared{
         raw: raw,
         transport: put_session(transport, session),
         protocol: protocol,
         kind: envelope.kind,
         policy: %{policy | mirrored_headers: Map.merge(policy.mirrored_headers, tool_mirrors)},
         deferred_error: deferred,
         deferred_authorization: tool_authorization,
         session: session,
         new_session?: new_session?
       }}
    else
      :response_object ->
        {:response, %Response{status: 202}}

      {:http_error, status, %Error{} = error, id} ->
        {:response, error_response(status, error, id)}

      {:error, %Error{} = error} ->
        {:response, error_response(status_for(error), error, readable_id(raw))}
    end
  rescue
    _exception -> {:response, error_response(500, Error.internal(), readable_id(raw))}
  end

  @doc "Executes one admitted request; transports may supply a cancellation token."
  @spec execute(Runtime.t(), Prepared.t(), term() | nil) :: Response.t() | StreamResponse.t()
  def execute(runtime, prepared, cancellation \\ nil)

  def execute(
        %Runtime{} = runtime,
        %Prepared{deferred_error: {:http_error, _, _, _}} = prepared,
        _
      ) do
    deferred_response(runtime, prepared)
  end

  def execute(%Runtime{} = runtime, %Prepared{} = prepared, cancellation) do
    transport = %{
      prepared.transport
      | metadata: Map.put(prepared.transport.metadata, :cancellation, cancellation)
    }

    case Exchange.dispatch(runtime, prepared.raw, transport) do
      {:ok, nil} ->
        %Response{status: 202}

      {:ok, response} when is_map(response) ->
        prepared.protocol
        |> execution_status(response)
        |> json_response(response)
        |> keep_session(prepared, response)

      {:stream, subscription} when prepared.policy.stream_mode == :sse ->
        %StreamResponse{subscription: subscription}

      {:stream, subscription} ->
        :ok = Snodo.Subscription.close(subscription, {:error, :stream_not_allowed})

        error_response(
          500,
          Error.internal("Protocol stream was not admitted"),
          readable_id(prepared.raw)
        )
    end
  rescue
    _exception ->
      _closed = discard_session(prepared)
      error_response(500, Error.internal(), readable_id(prepared.raw))
  end

  @doc """
  Runs admission and execution synchronously for embedding in another HTTP stack.

  A standalone `GET` stream cannot be served this way and is answered with 405.
  """
  @spec handle(Runtime.t(), Request.t(), keyword()) :: Response.t() | StreamResponse.t()
  def handle(%Runtime{} = runtime, %Request{} = request, opts \\ []) do
    case prepare(runtime, request, opts) do
      {:ok, prepared} ->
        execute(runtime, prepared)

      {:response, response} ->
        response

      {:standalone, _session} ->
        error_response(405, Error.invalid_request("Standalone streams are not served here"), nil)
    end
  end

  # A session started by initialize is kept only when initialization
  # succeeded, and its ID goes back in the response header.
  defp keep_session(response, %Prepared{new_session?: true, session: session}, %{"result" => _}),
    do: %{response | headers: [{@session_header, session.id} | response.headers]}

  defp keep_session(response, %Prepared{} = prepared, _body) do
    _closed = discard_session(prepared)
    response
  end

  defp discard_session(%Prepared{new_session?: true, session: %Session{pid: pid}}),
    do: Session.close(pid)

  defp discard_session(_prepared), do: :ok

  defp put_session(transport, nil), do: transport

  defp put_session(transport, session),
    do: %{transport | metadata: Map.put(transport.metadata, :session, session)}

  defp session_for(runtime, request, envelope, protocol, opts) do
    sessions = Keyword.get(opts, :sessions)

    cond do
      is_nil(sessions) or protocol.era() != :session ->
        {:ok, nil, false}

      envelope.method == "initialize" ->
        start_session(sessions, runtime, opts, envelope.id)

      true ->
        with {:ok, session} <- admit_session(request, sessions, opts, envelope.id),
             :ok <- validate_session_version(request, session, envelope.id) do
          {:ok, session, false}
        end
    end
  end

  defp start_session(sessions, runtime, opts, id) do
    case Manager.start_session(sessions, runtime, Keyword.get(opts, :auth)) do
      {:ok, session} ->
        {:ok, session, true}

      {:error, :limit} ->
        {:http_error, 503, Error.internal("Server session capacity exhausted"), id}

      {:error, _reason} ->
        {:http_error, 500, Error.internal("Could not start a session"), id}
    end
  end

  defp admit_session(request, sessions, opts, id) do
    case header_values(request.headers, @session_header) do
      [value] ->
        case Manager.admit(sessions, value, Keyword.get(opts, :auth)) do
          {:ok, session} -> {:ok, session}
          :error -> {:http_error, 404, session_not_found(), id}
        end

      [] ->
        {:http_error, 400, Error.invalid_request("Missing Mcp-Session-Id header"), id}

      _repeated ->
        {:http_error, 400, Error.invalid_request("Repeated Mcp-Session-Id header"), id}
    end
  end

  defp session_not_found,
    do: %Error{code: -32_001, message: "Session not found", kind: :transport}

  defp validate_session_version(request, session, id) do
    case header_values(request.headers, @protocol_header) do
      [] ->
        :ok

      [version] when version == session.protocol_version ->
        :ok

      _other ->
        {:http_error, 400, Error.invalid_request("Protocol version does not match the session"),
         id}
    end
  end

  # A response object has nothing to answer. The transport accepts it with
  # 202 and no body, as it does a notification. On a session it is the
  # client's answer to a server request, routed to the request waiting for it.
  defp route_response_object(raw, request, opts) do
    sessions = Keyword.get(opts, :sessions)

    cond do
      not Envelope.response?(raw) ->
        :ok

      is_nil(sessions) or header_values(request.headers, @session_header) == [] ->
        :response_object

      true ->
        with {:ok, session} <- admit_session(request, sessions, opts, nil) do
          _delivered = Session.deliver(session.pid, raw)
          :response_object
        end
    end
  end

  defp validate_event_stream_accept(%Request{} = request) do
    if "text/event-stream" in media_types(request.headers, "accept"),
      do: :ok,
      else:
        {:http_error, 406, Error.invalid_request("Accept must include text/event-stream"), nil}
  end

  @doc false
  @spec reject(Runtime.t(), Prepared.t(), Error.t(), pos_integer()) :: Response.t()
  def reject(%Runtime{} = runtime, %Prepared{} = prepared, %Error{} = error, status) do
    case Server.reject(runtime, prepared.raw, prepared.transport, error) do
      {:ok, nil} -> %Response{status: status}
      {:ok, response} -> json_response(status, response)
    end
  end

  defp validate_http_method(%Request{method: "POST"}, _sessions), do: :ok

  defp validate_http_method(%Request{method: method}, sessions)
       when method in ["GET", "DELETE"] and not is_nil(sessions),
       do: :ok

  defp validate_http_method(%Request{}, nil) do
    {:http_error, 405, Error.invalid_request("Streamable HTTP accepts POST only"), nil}
  end

  defp validate_http_method(%Request{}, _sessions) do
    {:http_error, 405, Error.invalid_request("Streamable HTTP accepts GET, POST, and DELETE"),
     nil}
  end

  defp validate_origin(%Request{} = request, opts) do
    case header_values(request.headers, "origin") do
      [] ->
        :ok

      [origin] ->
        allowed = Keyword.get(opts, :allowed_origin_hosts, @default_local_origin_hosts)

        if valid_origin?(origin, allowed) do
          :ok
        else
          {:http_error, 403, Error.invalid_request("Origin is not allowed"), nil}
        end

      _duplicates ->
        {:http_error, 403, Error.invalid_request("Origin is not allowed"), nil}
    end
  end

  # An allowlist entry is a host, or a host and port ("localhost:3000") that
  # pins the port. Origins carrying userinfo are never browser-generated.
  defp valid_origin?(origin, allowed_hosts) when is_list(allowed_hosts) do
    case URI.new(origin) do
      {:ok, %URI{scheme: scheme, host: host, port: port, userinfo: nil}}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        Enum.any?(allowed_hosts, &host_allowed?(&1, host, port))

      _invalid ->
        false
    end
  end

  # Host checking is opt-in: behind a reverse proxy the Host header commonly
  # carries the public name, so a loopback default would refuse proxied
  # requests. Origin, which browsers send, is checked by default.
  defp validate_host(%Request{} = request, opts) do
    case Keyword.get(opts, :allowed_hosts) do
      nil ->
        :ok

      allowed when is_list(allowed) ->
        with [authority] <- authority_values(request.headers),
             {:ok, host, port} <- parse_authority(authority),
             true <- Enum.any?(allowed, &host_allowed?(&1, host, port)) do
          :ok
        else
          _refused -> {:http_error, 403, Error.invalid_request("Host is not allowed"), nil}
        end
    end
  end

  defp authority_values(headers) do
    case header_values(headers, "host") do
      [] -> header_values(headers, ":authority")
      values -> values
    end
  end

  defp host_allowed?(entry, host, port) do
    case parse_authority(entry) do
      {:ok, allowed_host, nil} ->
        String.downcase(allowed_host) == String.downcase(host)

      {:ok, allowed_host, allowed_port} ->
        String.downcase(allowed_host) == String.downcase(host) and allowed_port == port

      :error ->
        false
    end
  end

  # "host", "host:port", "[v6]", "[v6]:port", or a bare IPv6 literal.
  defp parse_authority(value) when is_binary(value) do
    cond do
      match = Regex.run(~r/^\[([^\]]+)\](?::(\d+))?$/, value) -> authority(match)
      match = Regex.run(~r/^([^:\[\]]+)(?::(\d+))?$/, value) -> authority(match)
      String.contains?(value, ":") -> {:ok, value, nil}
      true -> :error
    end
  end

  defp parse_authority(_value), do: :error

  defp authority([_all, host]), do: {:ok, host, nil}
  defp authority([_all, host, ""]), do: {:ok, host, nil}
  defp authority([_all, host, port]), do: {:ok, host, String.to_integer(port)}

  defp validate_content_type(%Request{} = request) do
    case media_types(request.headers, "content-type") do
      [@json_content_type] ->
        :ok

      _missing_or_invalid ->
        {:http_error, 415, Error.invalid_request("Expected application/json"), nil}
    end
  end

  defp validate_accept(%Request{} = request) do
    accepted = media_types(request.headers, "accept")

    if @json_content_type in accepted and "text/event-stream" in accepted do
      :ok
    else
      {:http_error, 406,
       Error.invalid_request("Accept must include application/json and text/event-stream"), nil}
    end
  end

  # A leading UTF-8 byte order mark is not JSON, but some clients send one.
  defp decode_body(<<0xEF, 0xBB, 0xBF, body::binary>>), do: decode_body(body)

  defp decode_body(body) when is_binary(body) do
    case Snodo.JSONValue.decode(body) do
      {:ok, raw} -> {:ok, raw}
      {:error, _reason} -> {:http_error, 400, Error.parse_error(), nil}
    end
  end

  defp decode_envelope(raw, transport) do
    case Envelope.decode(raw, transport) do
      {:ok, envelope} -> {:ok, envelope}
      {:error, error} -> {:http_error, 400, error, readable_id(raw)}
    end
  end

  # The version header is checked before any dialect's header rules apply. A
  # header that disagrees with the body's version is -32020. One that names a
  # version the runtime does not enable is -32022, so a client can tell it
  # should change versions. An enabled header that no single dialect accepts
  # also disagrees with the body.
  defp select_protocol(%Runtime{} = runtime, %Envelope{} = envelope) do
    requested = TransportContext.get_header(envelope.transport.request_headers, @protocol_header)
    body_version = body_version(envelope)

    with :ok <- check_version_header(runtime, requested, body_version, envelope.id) do
      case Registry.select(runtime.protocol_registry, envelope) do
        {:ok, protocol} ->
          {:ok, protocol}

        {:error, _selection_error} when is_binary(requested) ->
          {:http_error, 400, version_mismatch(requested, body_version), envelope.id}

        {:error, selection_error} ->
          {:http_error, 400, selection_error, envelope.id}
      end
    end
  end

  defp check_version_header(_runtime, nil, _body_version, _id), do: :ok

  defp check_version_header(_runtime, requested, body_version, id)
       when is_binary(body_version) and requested != body_version,
       do: {:http_error, 400, version_mismatch(requested, body_version), id}

  defp check_version_header(runtime, requested, _body_version, id) do
    if requested in Registry.versions(runtime.protocol_registry),
      do: :ok,
      else: {:http_error, 400, unsupported_version(runtime, requested), id}
  end

  defp body_version(%Envelope{
         params: %{"_meta" => %{"io.modelcontextprotocol/protocolVersion" => version}}
       }),
       do: version

  defp body_version(%Envelope{}), do: nil

  defp version_mismatch(header_version, body_version) do
    %Error{
      code: -32_020,
      message: "Protocol header does not match request metadata",
      kind: :protocol,
      data: %{"header" => header_version, "body" => body_version}
    }
  end

  # Mirrors for the `x-mcp-header` arguments of the called tool, with the
  # authorization policy that decides its visibility. A tool outside the router
  # may come from an extension that serves it. An unknown tool adds none;
  # dispatch reports it.
  defp tool_parameter_mirrors(
         %Policy{tool_parameter_headers?: true},
         %Runtime{} = runtime,
         version,
         %Envelope{params: %{"name" => name}}
       )
       when is_binary(name) do
    with {:ok, schema, authorization} <- tool_input_schema(runtime, version, name),
         {:ok, [_first | _rest] = annotations} <- ParamHeaders.annotations(schema) do
      {ParamHeaders.mirrors(annotations), authorization}
    else
      _none -> {%{}, runtime.authorization}
    end
  end

  defp tool_parameter_mirrors(_policy, runtime, _version, _envelope),
    do: {%{}, runtime.authorization}

  defp tool_input_schema(%Runtime{} = runtime, version, name) do
    case Map.fetch(runtime.router.tools, name) do
      {:ok, tool} ->
        {:ok, Tool.definition(tool).input_schema, runtime.authorization}

      :error ->
        ExtensionRegistry.tool_input_schema(
          runtime.extension_registry,
          version,
          name,
          runtime.capabilities
        )
    end
  end

  # A tool parameter header names an argument of one specific tool, so its
  # failure would reveal a tool the policy conceals. That failure waits for
  # execute/3, where the caller's identity is known.
  defp validate_tool_mirrors(_request, _raw, mirrors, _authorization, _id) when mirrors == %{},
    do: {:ok, nil}

  defp validate_tool_mirrors(request, raw, mirrors, authorization, id) do
    case validate_mirrors(request.headers, raw, mirrors, id) do
      :ok ->
        {:ok, nil}

      {:http_error, _status, _error, _id} = failure ->
        if Authorization.conceal?(authorization), do: {:ok, failure}, else: failure
    end
  end

  # Asks the policy about the called tool once, as dispatch would, and answers
  # a refusal exactly as an unknown tool. The handler is not run.
  defp deferred_response(runtime, %Prepared{deferred_error: deferred} = prepared) do
    {:http_error, status, error, id} = deferred
    %{"params" => %{"name" => name}} = prepared.raw
    protocol = prepared.protocol

    with {:ok, envelope} <- protocol.decode_request(prepared.raw, prepared.transport),
         {:ok, context} <- protocol.build_context(envelope, runtime) do
      component = %Authorization.Component{kind: :tool, name: name}

      case Authorization.decide(prepared.deferred_authorization, :invocation, component, context) do
        :ok ->
          error_response(status, error, id)

        {:refused, _error} ->
          unknown = Error.invalid_params("Unknown tool: #{name}")
          error_response(status_for(unknown), unknown, id)

        {:fault, %Error{} = fault} ->
          error_response(status_for(fault), fault, id)
      end
    else
      _invalid -> error_response(status, error, id)
    end
  end

  defp validate_policy(%Request{} = request, raw, %Policy{} = policy, id) do
    with :ok <- validate_allowed_method(request.method, policy),
         :ok <- validate_required_headers(request.headers, policy.required_headers, id),
         :ok <- validate_forbidden_headers(request.headers, policy.forbidden_headers, id),
         :ok <- validate_mirrors(request.headers, raw, policy.mirrored_headers, id) do
      validate_policy_media_types(request, policy)
    end
  end

  defp validate_allowed_method(method, %Policy{allowed_methods: allowed}) do
    if allowed == [] or method in allowed do
      :ok
    else
      {:http_error, 405, Error.invalid_request("HTTP method is not allowed by the protocol"), nil}
    end
  end

  defp validate_required_headers(headers, required, id) do
    case Enum.find(required, &(length(header_values(headers, &1)) != 1)) do
      nil -> :ok
      name -> header_error("Missing or repeated required header: #{name}", id)
    end
  end

  defp validate_forbidden_headers(headers, forbidden, id) do
    case Enum.find(forbidden, &(header_values(headers, &1) != [])) do
      nil -> :ok
      name -> header_error("Forbidden header: #{name}", id)
    end
  end

  defp validate_mirrors(headers, raw, mirrors, id) do
    Enum.reduce_while(mirrors, :ok, fn {name, mirror}, :ok ->
      case validate_mirror(headers, raw, name, mirror, id) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp validate_mirror(headers, raw, name, mirror, id) do
    expected = get_in_path(raw, Map.fetch!(mirror, :path))
    values = header_values(headers, name)
    encoding = Map.get(mirror, :encoding, :plain)
    compare_mirror(expected, values, encoding, name, id)
  end

  # The dialect owns required request-body fields and reports their protocol
  # error before a mirror can be meaningfully compared.
  defp compare_mirror(nil, _values, _encoding, _name, _id), do: :ok

  defp compare_mirror(expected, [header], encoding, name, id) do
    case decode_header_value(header, encoding) do
      {:ok, decoded} ->
        if ParamHeaders.matches?(decoded, expected),
          do: :ok,
          else: header_error("#{name} does not match the request body", id)

      :error ->
        header_error("#{name} is malformed", id)
    end
  end

  defp compare_mirror(_expected, _values, _encoding, name, id) do
    header_error("Missing or repeated required header: #{name}", id)
  end

  defp validate_policy_media_types(%Request{} = request, %Policy{} = policy) do
    request_types = media_types(request.headers, "content-type")
    accepted = media_types(request.headers, "accept")

    cond do
      policy.request_content_types != [] and
          not Enum.any?(request_types, &(&1 in policy.request_content_types)) ->
        {:http_error, 415, Error.invalid_request("Unsupported request content type"), nil}

      not Enum.all?(policy.required_accept_types, &(&1 in accepted)) ->
        {:http_error, 406,
         Error.invalid_request("Required response content type is not accepted"), nil}

      true ->
        :ok
    end
  end

  defp decode_header_value(value, :plain), do: {:ok, value}

  # A plain value may carry only visible ASCII, space, and tab; anything else
  # must arrive base64-encoded.
  # The prefix and suffix overlap in "=?base64?=", so an encoded value is at
  # least 11 bytes; a shorter one that has both is malformed.
  defp decode_header_value(value, :base64_sentinel) do
    cond do
      String.starts_with?(value, "=?base64?") and String.ends_with?(value, "?=") ->
        if byte_size(value) >= 11, do: decode_base64_sentinel(value), else: :error

      Enum.all?(:binary.bin_to_list(value), &(&1 == 0x09 or &1 in 0x20..0x7E)) ->
        {:ok, value}

      true ->
        :error
    end
  end

  defp decode_base64_sentinel(value) do
    encoded_size = byte_size(value) - byte_size("=?base64?") - byte_size("?=")
    payload = binary_part(value, byte_size("=?base64?"), encoded_size)

    case Base.decode64(payload) do
      {:ok, decoded} -> validate_utf8_header(decoded)
      :error -> :error
    end
  end

  defp validate_utf8_header(decoded) when is_binary(decoded) do
    if String.valid?(decoded), do: {:ok, decoded}, else: :error
  end

  defp header_error(message, id) do
    {:http_error, 400, %Error{code: -32_020, message: message, kind: :transport}, id}
  end

  defp transport_context(%Request{} = request) do
    %TransportContext{
      transport: :streamable_http,
      peer: request.peer,
      request_headers: request.headers,
      connection_ref: request.connection_ref,
      metadata: %{}
    }
  end

  defp unsupported_version(%Runtime{} = runtime, requested) do
    %Error{
      code: -32_022,
      message: "Unsupported protocol version",
      kind: :protocol,
      data: %{
        "requested" => requested,
        "supported" => Registry.versions(runtime.protocol_registry)
      }
    }
  end

  # Initialize-era clients treat any non-2xx answer to a request as a
  # transport failure, and 404 as an expired session, so their JSON-RPC
  # errors travel with 200. Admission failures in prepare/3 keep 4xx on
  # every dialect.
  defp execution_status(protocol, response) do
    if protocol.era() == :stateless, do: response_status(response), else: 200
  end

  defp response_status(%{"error" => %{"code" => code}}) when is_integer(code) do
    Map.get(@error_statuses, code, 200)
  end

  defp response_status(_response), do: 200

  defp status_for(%Error{code: code}) do
    response_status(%{"error" => %{"code" => code}})
  end

  defp json_response(status, value) do
    %Response{
      status: status,
      headers: [{"content-type", "application/json"}],
      body: JSON.encode!(value)
    }
  end

  defp error_response(status, %Error{} = error, id, sessions \\ nil) do
    response =
      json_response(status, %{
        "jsonrpc" => "2.0",
        "id" => id,
        "error" => Error.to_json_rpc(error)
      })

    case {status, sessions} do
      {405, nil} ->
        %{response | headers: [{"allow", "POST"} | response.headers]}

      {405, _sessions} ->
        %{response | headers: [{"allow", "GET, POST, DELETE"} | response.headers]}

      _other ->
        response
    end
  end

  defp media_types(headers, name) do
    headers
    |> header_values(name)
    |> Enum.flat_map(&String.split(&1, ","))
    |> Enum.map(fn value ->
      value
      |> String.split(";", parts: 2)
      |> hd()
      |> String.trim()
      |> String.downcase()
    end)
    |> Enum.reject(&(&1 == ""))
  end

  defp header_values(headers, name) when is_map(headers) do
    wanted = String.downcase(name)

    for {key, value} <- headers,
        String.downcase(to_string(key)) == wanted,
        is_binary(value) do
      String.trim(value)
    end
  end

  defp header_values(headers, name) when is_list(headers) do
    wanted = String.downcase(name)

    for {key, value} <- headers,
        String.downcase(to_string(key)) == wanted,
        is_binary(value) do
      String.trim(value)
    end
  end

  defp get_in_path(value, []), do: value

  defp get_in_path(value, [key | rest]) when is_map(value) do
    value
    |> Map.get(key)
    |> get_in_path(rest)
  end

  defp get_in_path(_value, _path), do: nil

  # An id outside the bounds is not echoed; the error answers with a null id.
  defp readable_id(raw) when is_map(raw) do
    id = Map.get(raw, "id")
    if Envelope.bounded_id?(id), do: id, else: nil
  end

  defp readable_id(_raw), do: nil
end
