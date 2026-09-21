defmodule MCP.Protocol.Legacy do
  @moduledoc false

  alias MCP.{Context, Envelope, Error, Progress, Prompt, Resource, Result}
  alias MCP.Protocol.Profile
  alias MCP.Protocol.Profile.Method
  alias MCP.Transport.Context, as: TransportContext
  alias MCP.Transport.Policy

  @version_key "io.modelcontextprotocol/protocolVersion"
  @lists %{
    "tools/list" => :tools_list,
    "prompts/list" => :prompts_list,
    "resources/list" => :resources_list,
    "resources/templates/list" => :resource_templates_list
  }
  @named %{"tools/call" => :tools_call, "prompts/get" => :prompt_get}

  defmacro __using__(version: version) do
    quote do
      alias MCP.Protocol.Legacy

      @behaviour MCP.Protocol
      @version unquote(version)
      @impl true
      def profile, do: Legacy.profile(@version)
      @impl true
      def version, do: @version
      @impl true
      def era, do: :session
      @impl true
      def detect(envelope), do: Legacy.detect(envelope, @version)
      @impl true
      def decode_request(raw, transport), do: MCP.Envelope.decode(raw, transport)
      @impl true
      def build_context(envelope, runtime),
        do: Legacy.build_context(envelope, runtime, __MODULE__)

      @impl true
      defdelegate resolve_operation(envelope), to: Legacy
      @impl true
      defdelegate validate_operation(operation, params, context), to: Legacy
      @impl true
      defdelegate validate_result(operation, result, context), to: Legacy
      @impl true
      defdelegate shape_result(operation, result, context), to: Legacy
      @impl true
      def shape_error(error, _context), do: MCP.Error.to_json_rpc(error)
      @impl true
      defdelegate shape_progress(token, fields, context), to: Legacy
      @impl true
      defdelegate transport_policy(envelope), to: Legacy
      @impl true
      def server_discovery(_runtime), do: :unsupported
      @impl true
      def request_metadata(_capabilities), do: %{}
    end
  end

  def profile(version) do
    requests = [
      {"initialize", :required, nil},
      {"ping", :optional, nil},
      {"tools/list", :optional, "tools"},
      {"tools/call", :required, "tools"},
      {"prompts/list", :optional, "prompts"},
      {"prompts/get", :required, "prompts"},
      {"resources/list", :optional, "resources"},
      {"resources/templates/list", :optional, "resources"},
      {"resources/read", :required, "resources"},
      {"completion/complete", :required, "completions"}
    ]

    methods =
      Enum.map(requests, fn {name, params, capability} ->
        Method.new!(
          name: name,
          kind: :request,
          directions: [:client_to_server],
          params: params,
          capability: capability,
          status: :implemented
        )
      end)

    notifications =
      Enum.map(
        [{"notifications/initialized", :optional}, {"notifications/cancelled", :required}],
        fn {name, params} ->
          Method.new!(
            name: name,
            kind: :notification,
            directions: [:client_to_server],
            params: params,
            status: :implemented
          )
        end
      )

    Profile.new!(
      version: version,
      status: :released,
      scope: :implemented_slice,
      era: :session,
      batching: :forbidden,
      request_metadata: %{request: :optional, notification: :optional},
      methods:
        methods ++
          notifications ++
          [
            Method.new!(
              name: "notifications/progress",
              kind: :notification,
              directions: [:server_to_client],
              params: :required,
              status: :implemented
            )
          ],
      capabilities: ["tools", "prompts", "resources", "completions"],
      transports: %{direct: :tested, streamable_http: :tested, stdio: :unsupported},
      limitations: %{
        http_sessions: :unsupported,
        server_requests: :unsupported,
        subscriptions: :unsupported,
        tasks: :unsupported,
        missing_http_version: :unsupported,
        lifecycle_enforcement: :client_owned
      },
      specification: "https://modelcontextprotocol.io/specification/" <> version
    )
  end

  def detect(%Envelope{transport: transport}, version) do
    if TransportContext.get_header(transport.request_headers, "mcp-protocol-version") == version,
      do: :exact,
      else: false
  end

  def build_context(envelope, runtime, protocol) do
    with :ok <- validate_transport(envelope.transport),
         :ok <- validate_version(envelope, protocol.version()),
         :ok <- validate_progress(envelope.params),
         :ok <- validate_unsupported_params(envelope.params) do
      initialize? = envelope.method == "initialize"

      context = %Context{
        protocol_version: protocol.version(),
        protocol: protocol,
        transport: envelope.transport,
        request_id: envelope.id,
        request_method: envelope.method,
        request_params: envelope.params,
        auth: envelope.transport.metadata[:auth],
        cancellation: envelope.transport.metadata[:cancellation],
        session: nil,
        server_info: implementation(runtime.server_info, protocol.version()),
        server_capabilities:
          Map.new(runtime.capabilities, fn {key, _value} -> {key, %{}} end)
          |> Map.take(["tools", "prompts", "resources", "completions"]),
        client_info: if(initialize?, do: envelope.params["clientInfo"]),
        client_capabilities:
          if(initialize?, do: Map.get(envelope.params, "capabilities", %{}), else: %{}),
        metadata: Map.get(envelope.params, "_meta", %{})
      }

      {:ok,
       %{context | progress: Progress.bind(envelope.transport.metadata[:progress_sink], context)}}
    end
  end

  defp validate_transport(%TransportContext{transport: transport})
       when transport in [:stdio, MCP.Transport.Stdio],
       do:
         {:error,
          Error.invalid_request("Legacy dialects currently support HTTP and direct dispatch only")}

  defp validate_transport(_transport), do: :ok

  defp validate_version(envelope, version) do
    header =
      TransportContext.get_header(envelope.transport.request_headers, "mcp-protocol-version")

    metadata = Map.get(envelope.params, "_meta", %{})

    cond do
      not is_map(metadata) ->
        {:error, Error.invalid_params("_meta must be an object")}

      metadata[@version_key] not in [nil, version] ->
        {:error, Error.invalid_params("Conflicting protocol metadata")}

      header == version ->
        :ok

      envelope.method == "initialize" and is_nil(header) ->
        :ok

      true ->
        {:error, Error.invalid_params("A matching MCP-Protocol-Version header is required")}
    end
  end

  defp validate_progress(params) do
    case get_in(params, ["_meta", "progressToken"]) do
      nil -> :ok
      token when is_binary(token) or is_integer(token) -> :ok
      _ -> {:error, Error.invalid_params("progressToken must be a string or integer")}
    end
  end

  defp validate_unsupported_params(params) do
    if Enum.any?(["task", "inputResponses", "requestState"], &Map.has_key?(params, &1)),
      do: {:error, Error.invalid_params("Tasks and multi-round-trip inputs are not supported")},
      else: :ok
  end

  def resolve_operation(%Envelope{method: "initialize"}), do: {:ok, :initialize}
  def resolve_operation(%Envelope{method: "notifications/initialized"}), do: {:ok, :initialized}
  def resolve_operation(%Envelope{method: "ping"}), do: {:ok, :ping}
  def resolve_operation(%Envelope{method: "completion/complete"}), do: {:ok, :completion_complete}

  def resolve_operation(%Envelope{method: "resources/read", params: %{"uri" => uri}})
      when is_binary(uri),
      do: {:ok, {:resource_read, uri}}

  def resolve_operation(%Envelope{
        method: "notifications/cancelled",
        params: %{"requestId" => id} = params
      })
      when is_binary(id) or is_integer(id), do: {:ok, {:cancel, id, params["reason"]}}

  def resolve_operation(%Envelope{method: method, params: params}) do
    cond do
      Map.has_key?(@lists, method) ->
        {:ok, Map.fetch!(@lists, method)}

      Map.has_key?(@named, method) and is_binary(params["name"]) and params["name"] != "" ->
        {:ok, {Map.fetch!(@named, method), params["name"]}}

      method in ["resources/read", "notifications/cancelled", "tools/call", "prompts/get"] ->
        {:error, Error.invalid_params("Missing or invalid operation arguments")}

      true ->
        :not_handled
    end
  end

  def validate_operation(:initialize, params, _context) do
    case params do
      %{
        "protocolVersion" => version,
        "capabilities" => capabilities,
        "clientInfo" => %{"name" => name, "version" => client_version}
      }
      when is_binary(version) and version != "" and is_map(capabilities) and is_binary(name) and
             is_binary(client_version) ->
        :ok

      _ ->
        {:error,
         Error.invalid_params(
           "initialize requires protocolVersion, capabilities and clientInfo name/version"
         )}
    end
  end

  def validate_operation(operation, _params, _context) when operation in [:initialized, :ping],
    do: :ok

  def validate_operation({:cancel, _id, reason}, _params, _context)
      when is_nil(reason) or is_binary(reason), do: :ok

  def validate_operation({:cancel, _id, _reason}, _params, _context),
    do: {:error, Error.invalid_params("Cancellation reason must be a string")}

  def validate_operation(operation, params, context) do
    with :ok <- require_capability(operation, context),
         :ok <- optional_cursor(params),
         do: validate_arguments(operation, params)
  end

  defp require_capability(operation, context) do
    capability =
      case operation do
        op when op in [:tools_list] -> "tools"
        {:tools_call, _} -> "tools"
        op when op in [:prompts_list] -> "prompts"
        {:prompt_get, _} -> "prompts"
        :completion_complete -> "completions"
        _ -> "resources"
      end

    if Map.has_key?(context.server_capabilities, capability),
      do: :ok,
      else: {:error, Error.method_not_found("Capability is not enabled: " <> capability)}
  end

  defp optional_cursor(params) do
    case Map.fetch(params, "cursor") do
      :error -> :ok
      {:ok, cursor} when is_binary(cursor) -> :ok
      _ -> {:error, Error.invalid_params("cursor must be a string")}
    end
  end

  defp validate_arguments({:resource_read, uri}, _params) do
    case URI.new(uri) do
      {:ok, %URI{scheme: scheme}} when is_binary(scheme) -> :ok
      _ -> {:error, Error.invalid_params("Resource URI must be absolute")}
    end
  end

  defp validate_arguments({kind, _name}, params) when kind in [:tools_call, :prompt_get] do
    if is_map(Map.get(params, "arguments", %{})),
      do: :ok,
      else: {:error, Error.invalid_params("arguments must be an object")}
  end

  defp validate_arguments(_operation, _params), do: :ok

  def validate_result(_operation, %Result{kind: kind}, _context)
      when kind in [:input_required, :subscription, :wire],
      do: {:error, Error.internal("Result kind is not supported by this legacy dialect")}

  def validate_result({:tools_call, _}, %Result{kind: :structured, value: value}, _context)
      when not is_map(value),
      do: {:error, Error.internal("Legacy structuredContent must be an object")}

  def validate_result({:tools_call, _}, %Result{kind: :raw, value: value}, _context)
      when is_map(value) do
    valid =
      is_list(Map.get(value, "content", [])) and
        is_boolean(Map.get(value, "isError", false)) and
        (not Map.has_key?(value, "structuredContent") or is_map(value["structuredContent"])) and
        not Enum.any?(
          ["inputRequests", "requestState", "resultType", "task"],
          &Map.has_key?(value, &1)
        )

    if valid, do: :ok, else: {:error, Error.internal("Invalid legacy tool result")}
  end

  def validate_result(:tools_list, %Result{value: tools}, _context) do
    if Enum.all?(tools, fn tool ->
         object_schema?(tool.input_schema) and
           (is_nil(tool.output_schema) or object_schema?(tool.output_schema))
       end),
       do: :ok,
       else: {:error, Error.internal("Legacy tools require object input/output schemas")}
  end

  def validate_result(_operation, _result, _context), do: :ok
  defp object_schema?(%{"type" => "object"}), do: true
  defp object_schema?(_schema), do: false

  def shape_result(operation, result, context) do
    operation |> shape(result, context) |> metadata(result)
  end

  defp shape(:tools_list, %Result{value: tools} = result, _context),
    do: paginated(%{"tools" => Enum.map(tools, &tool_definition/1)}, result)

  defp shape(:prompts_list, %Result{value: prompts} = result, context),
    do:
      paginated(
        %{
          "prompts" =>
            Enum.map(
              prompts,
              &(Prompt.definition_to_map(&1) |> implementation(context.protocol_version))
            )
        },
        result
      )

  defp shape(:resources_list, %Result{value: resources} = result, context),
    do:
      paginated(
        %{
          "resources" =>
            Enum.map(
              resources,
              &(Resource.definition_to_map(&1) |> implementation(context.protocol_version))
            )
        },
        result
      )

  defp shape(:resource_templates_list, %Result{value: resources} = result, context),
    do:
      paginated(
        %{
          "resourceTemplates" =>
            Enum.map(
              resources,
              &(Resource.definition_to_map(&1) |> implementation(context.protocol_version))
            )
        },
        result
      )

  defp shape(
         {:prompt_get, _},
         %Result{value: %{messages: messages, description: description}},
         _context
       ),
       do: maybe_put(%{"messages" => messages}, "description", description)

  defp shape({:resource_read, _}, %Result{value: contents}, _context),
    do: %{"contents" => contents}

  defp shape(:completion_complete, %Result{value: value}, _context),
    do: %{
      "completion" =>
        %{"values" => value.values}
        |> maybe_put("total", value.total)
        |> maybe_put("hasMore", value.has_more)
    }

  defp shape({:tools_call, _}, result, _context), do: tool_result(result)
  defp shape(_operation, %Result{kind: :raw, value: value}, _context), do: value

  defp tool_result(%Result{kind: :text, value: text}),
    do: %{"content" => [%{"type" => "text", "text" => text}], "isError" => false}

  defp tool_result(%Result{kind: :structured, value: value}),
    do: %{
      "content" => [%{"type" => "text", "text" => JSON.encode!(value)}],
      "structuredContent" => value,
      "isError" => false
    }

  defp tool_result(%Result{kind: :resource, value: content}),
    do: %{"content" => List.wrap(content), "isError" => false}

  defp tool_result(%Result{kind: :error, value: message}),
    do: %{"content" => [%{"type" => "text", "text" => message}], "isError" => true}

  defp tool_result(%Result{kind: :raw, value: value}),
    do: value |> Map.put_new("content", []) |> Map.put_new("isError", false)

  defp tool_definition(tool) do
    %{
      "name" => tool.name,
      "description" => tool.description,
      "inputSchema" => tool.input_schema,
      "outputSchema" => tool.output_schema,
      "annotations" => tool.annotations
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp paginated(value, result), do: maybe_put(value, "nextCursor", result.metadata[:next_cursor])

  defp metadata(value, result) do
    extra = result.metadata |> Enum.reject(fn {key, _} -> is_atom(key) end) |> Map.new()
    if extra == %{}, do: value, else: Map.update(value, "_meta", extra, &Map.merge(&1, extra))
  end

  defp implementation(value, "2025-06-18"), do: Map.drop(value, ["icons", "websiteUrl"])
  defp implementation(value, _version), do: value
  defp maybe_put(value, _key, nil), do: value
  defp maybe_put(value, key, item), do: Map.put(value, key, item)

  def shape_progress(token, fields, _context),
    do: %{
      "jsonrpc" => "2.0",
      "method" => "notifications/progress",
      "params" => Map.put(fields, "progressToken", token)
    }

  def transport_policy(%Envelope{method: "initialize"}), do: %Policy{allowed_methods: ["POST"]}

  def transport_policy(_envelope),
    do: %Policy{allowed_methods: ["POST"], required_headers: ["mcp-protocol-version"]}
end
