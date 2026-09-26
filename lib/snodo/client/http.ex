defmodule Snodo.Client.HTTP do
  @moduledoc """
  Streamable HTTP transport for `Snodo.Client.connect({:http, url}, opts)`.

  Each request is one `POST` through OTP's `:httpc`, so no connection or
  process outlives it. The request headers come from the protocol dialect's
  `transport_policy/1`, the same declaration the server admits requests
  against: the accepted and request media types, and every mirrored header
  (for `2026-07-28`, `MCP-Protocol-Version`, `Mcp-Method`, and `Mcp-Name`) read
  from the request body. A mirrored value that is not plain printable ASCII is
  sent in the `=?base64?...?=` form when the policy allows it.

  The response may be `application/json` or `text/event-stream`. From an event
  stream the transport returns the response whose ID matches the request and
  drops notifications such as progress. A JSON-RPC error body is returned
  whatever the HTTP status, so `Snodo.Client` decodes it as `{:error,
  %Snodo.Error{}}`. Anything else is a -32000 transport error with the status and
  body in `cause`. A timeout closes the connection, which the server treats as
  cancellation.

  Options:

    * `:headers` - extra request headers as `{name, value}` string pairs, for
      example `[{"authorization", "Bearer " <> token}]`.
    * `:ssl` - `:ssl` client options for `https` URLs. The default verifies the
      peer against `:public_key.cacerts_get/0` and checks the host name.
    * `:connect_timeout` - milliseconds to establish the connection. Defaults
      to the request timeout.
  """

  @behaviour Snodo.Client.Transport

  alias Snodo.Client.Transport
  alias Snodo.Envelope
  alias Snodo.Transport.Context, as: TransportContext
  alias Snodo.Transport.ParamHeaders
  alias Snodo.Transport.Policy

  @type state :: %{
          url: charlist(),
          headers: [{charlist(), charlist()}],
          ssl: keyword(),
          connect_timeout: timeout() | nil
        }

  @sentinel_prefix "=?base64?"
  @sentinel_suffix "?="

  @impl Transport
  def connect(url, opts) when is_binary(url) do
    case URI.new(url) do
      {:ok, %URI{scheme: scheme, host: host} = uri}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        {:ok, _started} = Application.ensure_all_started([:inets, :ssl])

        {:ok,
         %{
           url: String.to_charlist(url),
           headers: Enum.map(Keyword.get(opts, :headers, []), &charlist_header/1),
           ssl: Keyword.get_lazy(opts, :ssl, fn -> default_ssl(uri) end),
           connect_timeout: Keyword.get(opts, :connect_timeout)
         }}

      _invalid ->
        {:error, Transport.connection_error("Expected an http or https URL", url)}
    end
  end

  @impl Transport
  def request(state, message, opts) when is_map(message) do
    timeout = Keyword.fetch!(opts, :timeout)
    policy = policy(Keyword.fetch!(opts, :dialect), message)
    [content_type | _other_types] = policy.request_content_types

    headers =
      [
        {"accept", Enum.join(policy.required_accept_types, ", ")}
        | mirrored_headers(policy, message) ++
            parameter_headers(policy, message, Keyword.get(opts, :tool))
      ]
      |> Enum.map(&charlist_header/1)
      |> Kernel.++(state.headers)

    request = {state.url, headers, String.to_charlist(content_type), JSON.encode!(message)}

    http_options = [
      timeout: timeout,
      connect_timeout: state.connect_timeout || timeout,
      ssl: state.ssl,
      autoredirect: false
    ]

    case :httpc.request(:post, request, http_options, body_format: :binary) do
      {:ok, {{_version, status, _reason}, response_headers, body}} ->
        decode(status, response_headers, body, Map.get(message, "id"))

      {:error, :timeout} ->
        {:error, Transport.timeout_error(timeout)}

      {:error, reason} ->
        {:error, Transport.connection_error("The HTTP request failed", reason)}
    end
  end

  @impl Transport
  def close(_state), do: :ok

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

  defp decode(status, headers, body, id) do
    if event_stream?(headers) do
      decode_event_stream(status, body, id)
    else
      decode_json(status, body)
    end
  end

  defp decode_json(status, body) do
    case JSON.decode(body) do
      {:ok, %{"jsonrpc" => "2.0"} = response} -> {:ok, response}
      _other -> unexpected(status, body)
    end
  end

  defp decode_event_stream(status, body, id) do
    body
    |> String.split(["\r\n\r\n", "\n\n"], trim: true)
    |> Enum.find_value(fn event -> matching_response(event, id) end)
    |> case do
      nil -> unexpected(status, body)
      response -> {:ok, response}
    end
  end

  defp matching_response(event, id) do
    data =
      event
      |> String.split(["\r\n", "\n"])
      |> Enum.flat_map(fn
        "data:" <> value -> [String.trim_leading(value, " ")]
        _other_field -> []
      end)
      |> Enum.join("\n")

    case JSON.decode(data) do
      {:ok, %{"id" => ^id} = response} when not is_map_key(response, "method") -> response
      _notification_or_other -> nil
    end
  end

  defp event_stream?(headers) do
    Enum.any?(headers, fn {name, value} ->
      String.downcase(List.to_string(name)) == "content-type" and
        value |> List.to_string() |> String.downcase() |> String.starts_with?("text/event-stream")
    end)
  end

  defp unexpected(status, body) do
    {:error,
     Transport.connection_error(
       "The HTTP response was not a JSON-RPC message",
       {:http_status, status, binary_part(body, 0, min(byte_size(body), 512))}
     )}
  end

  defp charlist_header({name, value}) when is_binary(name) and is_binary(value),
    do: {String.to_charlist(name), String.to_charlist(value)}

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
