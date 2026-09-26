defmodule Snodo.Transport.StreamableHTTP do
  @moduledoc """
  Protocol-driven adapter for stateless Streamable HTTP requests.

  The default dialect is 2026-07-28. Explicitly enabled initialize-era dialects
  share admission and execution without creating HTTP sessions.

  `prepare/3` performs HTTP and mirrored-header admission without invoking an
  application handler. `execute/3` runs one prepared message through the shared
  synchronous server core. This split lets HTTP servers admit a request before
  submitting only application work to `Snodo.Server.Executor`.

  Complete JSON responses and long-lived SSE descriptors are deliberately
  transport-server agnostic so Plug, Bandit, Cowboy, or a custom listener can
  translate them without changing protocol code.
  """

  alias Snodo.Envelope
  alias Snodo.Error
  alias Snodo.Extension.Registry, as: ExtensionRegistry
  alias Snodo.Protocol.Registry
  alias Snodo.Server
  alias Snodo.Server.Runtime
  alias Snodo.Transport.Context, as: TransportContext
  alias Snodo.Transport.Policy
  alias Snodo.Transport.StreamableHTTP.Prepared
  alias Snodo.Transport.StreamableHTTP.Request
  alias Snodo.Transport.StreamableHTTP.Response
  alias Snodo.Transport.StreamableHTTP.StreamResponse

  @json_content_type "application/json"
  @protocol_header "mcp-protocol-version"
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

  @type prepare_result :: {:ok, Prepared.t()} | {:response, Response.t()}

  @doc "Admits and decodes one HTTP request without executing its MCP handler."
  @spec prepare(Runtime.t(), Request.t(), keyword()) :: prepare_result()
  def prepare(%Runtime{} = runtime, %Request{} = request, opts \\ []) do
    with :ok <- validate_http_method(request),
         :ok <- validate_origin(request, opts),
         :ok <- validate_content_type(request),
         :ok <- validate_accept(request),
         {:ok, raw} <- decode_body(request.body),
         :ok <- reject_response_object(raw),
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
         :ok <- validate_policy(request, raw, policy, envelope.id) do
      {:ok,
       %Prepared{
         raw: raw,
         transport: transport,
         protocol: protocol,
         kind: envelope.kind,
         policy: policy
       }}
    else
      :response_object ->
        {:response, %Response{status: 202}}

      {:http_error, status, %Error{} = error, id} ->
        {:response, error_response(status, error, id)}

      {:error, %Error{} = error} ->
        {:response, error_response(status_for(error), error, readable_id(request.body))}
    end
  rescue
    _exception ->
      {:response, error_response(500, Error.internal(), readable_id(request.body))}
  end

  @doc "Executes one admitted request; transports may supply a cancellation token."
  @spec execute(Runtime.t(), Prepared.t(), term() | nil) :: Response.t() | StreamResponse.t()
  def execute(%Runtime{} = runtime, %Prepared{} = prepared, cancellation \\ nil) do
    transport = %{
      prepared.transport
      | metadata: Map.put(prepared.transport.metadata, :cancellation, cancellation)
    }

    case Server.dispatch(runtime, prepared.raw, transport) do
      {:ok, nil} ->
        %Response{status: 202}

      {:ok, response} when is_map(response) ->
        json_response(execution_status(prepared.protocol, response), response)

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
    _exception -> error_response(500, Error.internal(), readable_id(prepared.raw))
  end

  @doc "Runs admission and execution synchronously for embedding in another HTTP stack."
  @spec handle(Runtime.t(), Request.t(), keyword()) :: Response.t() | StreamResponse.t()
  def handle(%Runtime{} = runtime, %Request{} = request, opts \\ []) do
    case prepare(runtime, request, opts) do
      {:ok, prepared} -> execute(runtime, prepared)
      {:response, response} -> response
    end
  end

  @doc false
  @spec reject(Runtime.t(), Prepared.t(), Error.t(), pos_integer()) :: Response.t()
  def reject(%Runtime{} = runtime, %Prepared{} = prepared, %Error{} = error, status) do
    case Server.reject(runtime, prepared.raw, prepared.transport, error) do
      {:ok, nil} -> %Response{status: status}
      {:ok, response} -> json_response(status, response)
    end
  end

  defp validate_http_method(%Request{method: "POST"}), do: :ok

  defp validate_http_method(%Request{}) do
    {:http_error, 405, Error.invalid_request("Streamable HTTP accepts POST only"), nil}
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

  defp valid_origin?(origin, allowed_hosts) when is_list(allowed_hosts) do
    case URI.new(origin) do
      {:ok, %URI{scheme: scheme, host: host}}
      when scheme in ["http", "https"] and is_binary(host) ->
        normalized = String.downcase(host)
        Enum.any?(allowed_hosts, &(String.downcase(&1) == normalized))

      _invalid ->
        false
    end
  end

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

  defp decode_body(body) when is_binary(body) do
    case JSON.decode(body) do
      {:ok, raw} -> {:ok, raw}
      {:error, _reason} -> {:http_error, 400, Error.parse_error(), nil}
    end
  end

  # A response object has nothing to answer. The transport accepts it with
  # 202 and no body, as it does a notification.
  defp reject_response_object(raw) do
    if Envelope.response?(raw), do: :response_object, else: :ok
  end

  defp decode_envelope(raw, transport) do
    case Envelope.decode(raw, transport) do
      {:ok, envelope} -> {:ok, envelope}
      {:error, error} -> {:http_error, 400, error, readable_id(raw)}
    end
  end

  defp select_protocol(%Runtime{} = runtime, %Envelope{} = envelope) do
    case Registry.select(runtime.protocol_registry, envelope) do
      {:ok, protocol} ->
        {:ok, protocol}

      {:error, selection_error} ->
        requested =
          TransportContext.get_header(envelope.transport.request_headers, @protocol_header)

        if is_binary(requested) do
          {:http_error, 400, unsupported_version(runtime, requested), envelope.id}
        else
          {:http_error, 400, selection_error, envelope.id}
        end
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
      {:ok, ^expected} -> :ok
      {:ok, _mismatch} -> header_error("#{name} does not match the request body", id)
      :error -> header_error("#{name} is malformed", id)
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

  defp decode_header_value(value, :base64_sentinel) do
    if String.starts_with?(value, "=?base64?") and String.ends_with?(value, "?=") do
      decode_base64_sentinel(value)
    else
      {:ok, value}
    end
  end

  defp decode_base64_sentinel(value) do
    encoded_size = byte_size(value) - byte_size("=?base64?") - byte_size("?=")
    payload = String.slice(value, byte_size("=?base64?"), encoded_size)

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

  defp error_response(status, %Error{} = error, id) do
    response =
      json_response(status, %{
        "jsonrpc" => "2.0",
        "id" => id,
        "error" => Error.to_json_rpc(error)
      })

    case status do
      405 -> %{response | headers: [{"allow", "POST"} | response.headers]}
      _other -> response
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

  defp readable_id(raw) when is_map(raw) do
    case Map.get(raw, "id") do
      id when is_binary(id) or is_integer(id) -> id
      _invalid -> nil
    end
  end

  defp readable_id(body) when is_binary(body) do
    case JSON.decode(body) do
      {:ok, raw} -> readable_id(raw)
      {:error, _reason} -> nil
    end
  end

  defp readable_id(_raw), do: nil
end
