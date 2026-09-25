defmodule MCP.Client do
  @moduledoc """
  A client for servers built with this library.

  `direct/2` dispatches through `MCP.Server.dispatch/3` in the calling
  process. No transport or process sits in between:

      {:ok, client} = MCP.Client.direct(EchoServer.runtime())
      {:ok, [%{"name" => "echo"}]} = MCP.Client.list_tools(client)

      {:ok, result} = MCP.Client.call_tool(client, "echo", %{"text" => "hello"})
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
    * `{:error, %MCP.Error{}}`: a JSON-RPC error. `code`, `message`, and
      `data` are the server's. `kind` is derived from the code: -32700 and
      -32600 are `:json_rpc`, -32601 and -32602 are `:protocol`, -32603 is
      `:execution`, and any other code is `:protocol`.

  The client is an immutable struct and each request takes a fresh integer ID,
  so a client value can be shared between processes. Stdio and HTTP transports
  and `subscriptions/listen` streams are not implemented.
  """

  alias MCP.Client.Page
  alias MCP.Error
  alias MCP.Protocol.Registry
  alias MCP.Server
  alias MCP.Server.Runtime
  alias MCP.Transport.Context, as: TransportContext

  @type response :: {:ok, map()} | {:input_required, map()} | {:error, Error.t()}
  @type list_kind :: :tools | :resources | :resource_templates | :prompts
  @type t :: %__MODULE__{
          runtime: Runtime.t(),
          protocol: String.t(),
          dialect: module(),
          client_capabilities: map(),
          auth: term()
        }

  @enforce_keys [:runtime, :protocol, :dialect]
  defstruct [:runtime, :protocol, :dialect, :auth, client_capabilities: %{}]

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
    capabilities = Keyword.get(opts, :client_capabilities, %{})

    unless is_map(capabilities) do
      raise ArgumentError, ":client_capabilities must be a map, got: #{inspect(capabilities)}"
    end

    with {:ok, version} <- select_protocol(runtime, Keyword.get(opts, :protocol)),
         {:ok, dialect} <- Registry.fetch(runtime.protocol_registry, version),
         :ok <- require_stateless(dialect) do
      {:ok,
       %__MODULE__{
         runtime: runtime,
         protocol: version,
         dialect: dialect,
         client_capabilities: capabilities,
         auth: Keyword.get(opts, :auth)
       }}
    end
  end

  @doc "Requests `server/discover`."
  @spec discover(t()) :: response()
  def discover(%__MODULE__{} = client), do: request(client, "server/discover")

  @doc "Lists every tool, following `nextCursor` until the last page."
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
      raise ArgumentError,
            "MCP.Client.direct/2 cannot stream subscriptions/listen; use a streaming transport"
    end

    raw = %{
      "jsonrpc" => "2.0",
      "id" => System.unique_integer([:positive, :monotonic]),
      "method" => method,
      "params" => build_params(client, params, opts)
    }

    client.runtime
    |> Server.dispatch(raw, transport_context(client))
    |> decode_response()
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

  defp transport_context(client) do
    metadata = if is_nil(client.auth), do: %{}, else: %{auth: client.auth}

    %TransportContext{
      transport: :direct,
      request_headers: %{"mcp-protocol-version" => client.protocol},
      metadata: metadata
    }
  end

  defp decode_response({:ok, %{"result" => %{"resultType" => "input_required"} = result}}),
    do: {:input_required, result}

  defp decode_response({:ok, %{"result" => result}}), do: {:ok, result}
  defp decode_response({:ok, %{"error" => error}}), do: {:error, decode_error(error)}

  defp decode_error(%{"code" => code, "message" => message} = error) do
    %Error{code: code, message: message, data: Map.get(error, "data"), kind: error_kind(code)}
  end

  defp error_kind(code) when code in [-32_700, -32_600], do: :json_rpc
  defp error_kind(code) when code in [-32_601, -32_602], do: :protocol
  defp error_kind(-32_603), do: :execution
  defp error_kind(_code), do: :protocol

  defp list_all(client, kind), do: collect_pages(client, kind, nil, MapSet.new(), [])

  defp collect_pages(client, kind, cursor, seen, pages) do
    with {:ok, %Page{items: items, next_cursor: next}} <- list_page(client, kind, cursor) do
      pages = [items | pages]

      cond do
        is_nil(next) ->
          {:ok, pages |> Enum.reverse() |> Enum.concat()}

        MapSet.member?(seen, next) ->
          {:error,
           Error.internal("The server repeated a pagination cursor", %{
             "kind" => kind,
             "cursor" => next
           })}

        true ->
          collect_pages(client, kind, next, MapSet.put(seen, next), pages)
      end
    end
  end
end
