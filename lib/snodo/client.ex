defmodule Snodo.Client do
  @moduledoc """
  A client for MCP servers.

  `direct/2` dispatches to a runtime in the calling process. `connect/2` opens
  a stdio subprocess or a Streamable HTTP endpoint:

      {:ok, client} = Snodo.Client.direct(EchoServer.runtime())
      {:ok, client} = Snodo.Client.connect({:stdio, "elixir", ["echo_server.exs"]})
      {:ok, client} = Snodo.Client.connect({:http, "http://127.0.0.1:4000/mcp"})

      {:ok, [%{"name" => "echo"}]} = Snodo.Client.list_tools(client)

      {:ok, result} = Snodo.Client.call_tool(client, "echo", %{"text" => "hello"})
      result["content"]
      #=> [%{"type" => "text", "text" => "hello"}]

  The client builds each request, including the metadata the selected protocol
  dialect requires, and decodes the response into one of:

    * `{:ok, result}`: the JSON-RPC `result` object as the server sent it, with
      string keys. A `tools/call` result with `"isError" => true` is a
      successful response and arrives here.
    * `{:input_required, result}`: a multi round-trip request. Call again with
      `input_responses:` and, when the result carries a `"requestState"`,
      `request_state:`. See the MRTR guide in `docs/mrtr-elicitation.md`.
    * `{:error, %Snodo.Error{}}`: a JSON-RPC error or a transport failure. For a
      JSON-RPC error, `code`, `message`, and `data` are the server's, and
      `kind` is derived from the code: -32700 and -32600 are `:json_rpc`,
      -32601 and -32602 are `:protocol`, -32603 is `:execution`, and any other
      code is `:protocol`. Transport failures have `kind: :transport`: -32000
      when the connection is closed, unreachable, or returns something that is
      not a JSON-RPC response, and -32001 when a request times out.

  Each request takes a fresh integer ID, so one client can be used from many
  processes at once. The client speaks the stateless `2026-07-28` protocol;
  initialize-era servers, which need a session handshake, are not supported.
  `subscriptions/listen` streams and progress notifications are not delivered.
  """

  alias Snodo.Client.Direct
  alias Snodo.Client.HTTP
  alias Snodo.Client.Page
  alias Snodo.Client.Stdio
  alias Snodo.Client.Transport
  alias Snodo.Error
  alias Snodo.Protocol.Registry
  alias Snodo.Server.Runtime

  @type response :: {:ok, map()} | {:input_required, map()} | {:error, Error.t()}
  @type list_kind :: :tools | :resources | :resource_templates | :prompts
  @type target ::
          {:stdio, String.t(), [String.t()]}
          | {:http, String.t()}
          | {module(), term()}
  @type t :: %__MODULE__{
          transport: {module(), Transport.state()},
          protocol: String.t(),
          dialect: module(),
          client_capabilities: map(),
          timeout: timeout()
        }

  @enforce_keys [:transport, :protocol, :dialect]
  defstruct [:transport, :protocol, :dialect, client_capabilities: %{}, timeout: 30_000]

  @remote_dialects [Snodo.Protocol.V2026_07_28]

  @list_operations %{
    tools: {"tools/list", "tools"},
    resources: {"resources/list", "resources"},
    resource_templates: {"resources/templates/list", "resourceTemplates"},
    prompts: {"prompts/list", "prompts"}
  }
  @list_kinds Map.keys(@list_operations)

  @doc """
  Builds a client that dispatches to `runtime` in the calling process.

  Options:

    * `:protocol` - the protocol version to speak. Defaults to the first
      stateless-era version the runtime enables. Initialize-era versions need
      a session, which a direct client does not hold, so they are refused.
    * `:client_capabilities` - the capabilities sent with every request, for
      example `%{"elicitation" => %{"form" => %{}}}`. Defaults to `%{}`.
    * `:auth` - the value handlers and authorization policies read as
      `context.auth`, as a transport would supply it after authenticating.
  """
  @spec direct(Runtime.t(), keyword()) :: {:ok, t()} | {:error, Error.t()}
  def direct(%Runtime{} = runtime, opts \\ []) when is_list(opts) do
    with {:ok, version} <- select_protocol(runtime, Keyword.get(opts, :protocol)),
         {:ok, dialect} <- Registry.fetch(runtime.protocol_registry, version),
         :ok <- require_stateless(dialect) do
      open(Direct, runtime, dialect, opts)
    end
  end

  @doc """
  Connects to a server in another process or on the network.

  Targets:

    * `{:stdio, command, args}` - runs `command` and speaks newline-delimited
      JSON-RPC over its stdin and stdout. See `Snodo.Client.Stdio` for `:env`
      and `:cd`. The connection closes when the calling process exits.
    * `{:http, url}` - posts each request to a Streamable HTTP endpoint. See
      `Snodo.Client.HTTP` for `:headers`, `:ssl`, and `:connect_timeout`.
    * `{module, init_arg}` - any `Snodo.Client.Transport`.

  Options for every target:

    * `:protocol` - defaults to `"2026-07-28"`, the only supported version.
    * `:client_capabilities` - as for `direct/2`.
    * `:timeout` - the default request timeout in milliseconds, 30,000 unless
      set. Each request can override it with `timeout:`.
  """
  @spec connect(target(), keyword()) :: {:ok, t()} | {:error, Error.t()}
  def connect(target, opts \\ [])

  def connect({:stdio, command, args}, opts) when is_binary(command) and is_list(args),
    do: connect({Stdio, {command, args}}, opts)

  def connect({:http, url}, opts) when is_binary(url), do: connect({HTTP, url}, opts)

  def connect({module, init_arg}, opts) when is_atom(module) and is_list(opts) do
    unless Code.ensure_loaded?(module) and function_exported?(module, :request, 3) do
      raise ArgumentError,
            "expected {:stdio, command, args}, {:http, url}, or {transport_module, init_arg}, " <>
              "got a tuple starting with #{inspect(module)}"
    end

    with {:ok, dialect} <- remote_dialect(Keyword.get(opts, :protocol)) do
      open(module, init_arg, dialect, opts)
    end
  end

  @doc "Closes the client's connection. Closing an in-process client does nothing."
  @spec close(t()) :: :ok
  def close(%__MODULE__{transport: {module, state}}), do: module.close(state)

  @doc "Requests `server/discover`."
  @spec discover(t()) :: response()
  def discover(%__MODULE__{} = client), do: request(client, "server/discover")

  @doc "Lists every tool, following `nextCursor` to the last page."
  @spec list_tools(t()) :: {:ok, [map()]} | {:error, Error.t()}
  def list_tools(%__MODULE__{} = client), do: list_all(client, :tools)

  @doc "Lists every direct resource, following `nextCursor` until the last page."
  @spec list_resources(t()) :: {:ok, [map()]} | {:error, Error.t()}
  def list_resources(%__MODULE__{} = client), do: list_all(client, :resources)

  @doc "Lists every resource template, following `nextCursor` until the last page."
  @spec list_resource_templates(t()) :: {:ok, [map()]} | {:error, Error.t()}
  def list_resource_templates(%__MODULE__{} = client), do: list_all(client, :resource_templates)

  @doc "Lists every prompt, following `nextCursor` until the last page."
  @spec list_prompts(t()) :: {:ok, [map()]} | {:error, Error.t()}
  def list_prompts(%__MODULE__{} = client), do: list_all(client, :prompts)

  @doc """
  Requests one page of a list operation.

  `kind` is one of `:tools`, `:resources`, `:resource_templates`, or
  `:prompts`. Pass the previous page's `next_cursor` to continue.
  """
  @spec list_page(t(), list_kind(), String.t() | nil) :: {:ok, Page.t()} | {:error, Error.t()}
  def list_page(%__MODULE__{} = client, kind, cursor \\ nil)
      when kind in @list_kinds and (is_binary(cursor) or is_nil(cursor)) do
    {method, key} = Map.fetch!(@list_operations, kind)
    params = if cursor, do: %{"cursor" => cursor}, else: %{}

    case request(client, method, params) do
      {:ok, result} ->
        {:ok,
         %Page{
           items: Map.get(result, key, []),
           next_cursor: Map.get(result, "nextCursor"),
           result: result
         }}

      {:error, %Error{}} = error ->
        error
    end
  end

  @doc """
  Calls a tool.

  Options are those of `request/4`. A result with `"isError" => true` is
  returned as `{:ok, result}`: the tool ran and reported its own failure.
  """
  @spec call_tool(t(), String.t(), map(), keyword()) :: response()
  def call_tool(%__MODULE__{} = client, name, arguments \\ %{}, opts \\ [])
      when is_binary(name) and is_map(arguments) do
    request(client, "tools/call", %{"name" => name, "arguments" => arguments}, opts)
  end

  @doc "Reads a resource by exact URI. Options are those of `request/4`."
  @spec read_resource(t(), String.t(), keyword()) :: response()
  def read_resource(%__MODULE__{} = client, uri, opts \\ []) when is_binary(uri) do
    request(client, "resources/read", %{"uri" => uri}, opts)
  end

  @doc "Gets a rendered prompt. Options are those of `request/4`."
  @spec get_prompt(t(), String.t(), map(), keyword()) :: response()
  def get_prompt(%__MODULE__{} = client, name, arguments \\ %{}, opts \\ [])
      when is_binary(name) and is_map(arguments) do
    request(client, "prompts/get", %{"name" => name, "arguments" => arguments}, opts)
  end

  @doc """
  Sends any request method with the given params.

  Use it for methods without a dedicated function, such as
  `completion/complete` or a negotiated extension's methods. The dialect's
  request metadata is merged under `params["_meta"]`; keys already present in
  `params["_meta"]` win.

  Options:

    * `:input_responses` - answers to a previous `{:input_required, result}`,
      keyed by the IDs in its `"inputRequests"`. Sent as `inputResponses`.
    * `:request_state` - the `"requestState"` of a previous
      `{:input_required, result}`. Sent as `requestState`.
    * `:meta` - extra `_meta` entries, such as a `"progressToken"`. These win
      over the dialect's metadata and over `params["_meta"]`.

  `subscriptions/listen` raises `ArgumentError`: it needs a stream to deliver
  events on, and dispatching it would open the application's source.
  """
  @spec request(t(), String.t(), map(), keyword()) :: response()
  def request(%__MODULE__{} = client, method, params \\ %{}, opts \\ [])
      when is_binary(method) and is_map(params) and is_list(opts) do
    if method == "subscriptions/listen" do
      raise ArgumentError, "Snodo.Client cannot stream subscriptions/listen"
    end

    raw = %{
      "jsonrpc" => "2.0",
      "id" => System.unique_integer([:positive, :monotonic]),
      "method" => method,
      "params" => build_params(client, params, opts)
    }

    {module, state} = client.transport

    transport_opts = [
      dialect: client.dialect,
      timeout: Keyword.get(opts, :timeout, client.timeout)
    ]

    case module.request(state, raw, transport_opts) do
      {:ok, response} -> decode_response(response)
      {:error, %Error{}} = error -> error
    end
  end

  defp open(module, init_arg, dialect, opts) do
    capabilities = Keyword.get(opts, :client_capabilities, %{})
    timeout = Keyword.get(opts, :timeout, 30_000)

    unless is_map(capabilities) do
      raise ArgumentError, ":client_capabilities must be a map, got: #{inspect(capabilities)}"
    end

    unless timeout == :infinity or (is_integer(timeout) and timeout > 0) do
      raise ArgumentError,
            ":timeout must be a positive integer or :infinity, got: #{inspect(timeout)}"
    end

    with {:ok, state} <- module.connect(init_arg, opts) do
      {:ok,
       %__MODULE__{
         transport: {module, state},
         protocol: dialect.version(),
         dialect: dialect,
         client_capabilities: capabilities,
         timeout: timeout
       }}
    end
  end

  defp remote_dialect(nil), do: {:ok, hd(@remote_dialects)}

  defp remote_dialect(version) when is_binary(version) do
    case Enum.find(@remote_dialects, &(&1.version() == version)) do
      nil ->
        {:error,
         Error.invalid_params("Snodo.Client does not support protocol #{version}", %{
           "requested" => version,
           "supported" => Enum.map(@remote_dialects, & &1.version())
         })}

      dialect ->
        {:ok, dialect}
    end
  end

  defp remote_dialect(version) do
    raise ArgumentError, ":protocol must be a version string, got: #{inspect(version)}"
  end

  defp select_protocol(runtime, nil) do
    case Registry.versions(runtime.protocol_registry, era: :stateless) do
      [version | _rest] ->
        {:ok, version}

      [] ->
        {:error,
         Error.invalid_params(
           "The runtime enables no stateless protocol version for a direct client",
           %{"enabled" => Registry.versions(runtime.protocol_registry)}
         )}
    end
  end

  defp select_protocol(_runtime, version) when is_binary(version), do: {:ok, version}

  defp select_protocol(_runtime, version) do
    raise ArgumentError, ":protocol must be a version string, got: #{inspect(version)}"
  end

  defp require_stateless(dialect) do
    if dialect.era() == :stateless do
      :ok
    else
      {:error,
       Error.invalid_params(
         "Protocol #{dialect.version()} needs a session, which a direct client does not hold",
         %{"requested" => dialect.version()}
       )}
    end
  end

  defp build_params(client, params, opts) do
    metadata =
      client.dialect.request_metadata(client.client_capabilities)
      |> Map.merge(Map.get(params, "_meta", %{}))
      |> Map.merge(Keyword.get(opts, :meta, %{}))

    params
    |> put_present("inputResponses", Keyword.get(opts, :input_responses))
    |> put_present("requestState", Keyword.get(opts, :request_state))
    |> Map.put("_meta", metadata)
  end

  defp put_present(params, _key, nil), do: params
  defp put_present(params, key, value), do: Map.put(params, key, value)

  defp decode_response(%{"result" => %{"resultType" => "input_required"} = result}),
    do: {:input_required, result}

  defp decode_response(%{"result" => result}) when is_map(result), do: {:ok, result}

  defp decode_response(%{"error" => %{"code" => code, "message" => message} = error})
       when is_integer(code) and is_binary(message) do
    {:error,
     %Error{code: code, message: message, data: Map.get(error, "data"), kind: error_kind(code)}}
  end

  defp decode_response(response) do
    {:error, Transport.connection_error("The server sent an invalid JSON-RPC response", response)}
  end

  defp error_kind(code) when code in [-32_700, -32_600], do: :json_rpc
  defp error_kind(code) when code in [-32_601, -32_602], do: :protocol
  defp error_kind(-32_603), do: :execution
  defp error_kind(_code), do: :protocol

  defp list_all(client, kind), do: collect_pages(client, kind, nil, %{}, [])

  # A remote server can hand back a cursor it already issued; following it
  # would never terminate.
  defp collect_pages(client, kind, cursor, seen, pages) do
    with {:ok, %Page{items: items, next_cursor: next}} <- list_page(client, kind, cursor) do
      pages = [items | pages]

      cond do
        is_nil(next) ->
          {:ok, pages |> Enum.reverse() |> Enum.concat()}

        Map.has_key?(seen, next) ->
          {:error,
           Transport.connection_error("The server repeated a pagination cursor", %{
             kind: kind,
             cursor: next
           })}

        true ->
          collect_pages(client, kind, next, Map.put(seen, next, true), pages)
      end
    end
  end
end
