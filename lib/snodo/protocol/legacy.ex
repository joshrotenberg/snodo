defmodule Snodo.Protocol.Legacy do
  @moduledoc false

  alias Snodo.Authorization

  alias Snodo.{Context, Envelope, Error, MRTR, Progress, Prompt, Resource, Result, Router, Tool}
  alias Snodo.Protocol.Profile
  alias Snodo.Protocol.Profile.Method
  alias Snodo.Session
  alias Snodo.Subscription.Event, as: SubscriptionEvent
  alias Snodo.TraceContext
  alias Snodo.Transport.Context, as: TransportContext
  alias Snodo.Transport.Policy

  @version_key "io.modelcontextprotocol/protocolVersion"
  @lists %{
    "tools/list" => :tools_list,
    "prompts/list" => :prompts_list,
    "resources/list" => :resources_list,
    "resources/templates/list" => :resource_templates_list
  }
  @named %{"tools/call" => :tools_call, "prompts/get" => :prompt_get}
  @session_operations %{
    "resources/subscribe" => :resource_subscribe,
    "resources/unsubscribe" => :resource_unsubscribe
  }
  @list_changed %{
    tools_list_changed: "notifications/tools/list_changed",
    prompts_list_changed: "notifications/prompts/list_changed",
    resources_list_changed: "notifications/resources/list_changed"
  }

  defmacro __using__(version: version) do
    quote do
      alias Snodo.Protocol.Legacy

      @behaviour Snodo.Protocol
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
      def decode_request(raw, transport), do: Snodo.Envelope.decode(raw, transport)
      @impl true
      def build_context(envelope, runtime),
        do: Legacy.build_context(envelope, runtime, __MODULE__)

      @impl true
      defdelegate resolve_operation(envelope), to: Legacy
      @impl true
      defdelegate validate_operation(operation, params, context), to: Legacy
      @doc false
      defdelegate validate_tool_schema(tool, version), to: Legacy
      @impl true
      defdelegate validate_result(operation, result, context), to: Legacy
      @impl true
      defdelegate shape_result(operation, result, context), to: Legacy
      @impl true
      def shape_error(error, _context), do: Snodo.Error.to_json_rpc(error)
      @impl true
      defdelegate shape_progress(token, fields, context), to: Legacy
      @impl true
      defdelegate transport_policy(envelope), to: Legacy
      @impl true
      defdelegate shape_subscription_event(event, id, context), to: Legacy
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
      {"completion/complete", :required, "completions"},
      {"logging/setLevel", :required, "logging"},
      {"resources/subscribe", :required, "resources"},
      {"resources/unsubscribe", :required, "resources"}
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
        [
          {"notifications/initialized", :optional},
          {"notifications/cancelled", :required},
          {"notifications/roots/list_changed", :optional}
        ],
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

    # Sent only on a session: server-initiated requests carry a handler's input
    # requests, and the notifications carry subscription source events.
    server_requests =
      Enum.map(["sampling/createMessage", "elicitation/create", "roots/list"], fn name ->
        Method.new!(
          name: name,
          kind: :request,
          directions: [:server_to_client],
          params: if(name == "roots/list", do: :optional, else: :required),
          status: :implemented
        )
      end)

    server_notifications =
      Enum.map(
        [
          {"notifications/tools/list_changed", :optional, "tools"},
          {"notifications/prompts/list_changed", :optional, "prompts"},
          {"notifications/resources/list_changed", :optional, "resources"},
          {"notifications/resources/updated", :required, "resources"}
        ],
        fn {name, params, capability} ->
          Method.new!(
            name: name,
            kind: :notification,
            directions: [:server_to_client],
            params: params,
            capability: capability,
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
            ),
            Method.new!(
              name: "notifications/message",
              kind: :notification,
              directions: [:server_to_client],
              params: :required,
              capability: "logging",
              status: :implemented
            )
          ] ++ server_requests ++ server_notifications,
      capabilities: ["tools", "prompts", "resources", "completions", "logging"],
      transports: %{direct: :tested, streamable_http: :tested, stdio: :tested},
      limitations: %{
        http_sessions: :opt_in,
        server_requests: :opt_in,
        subscriptions: :opt_in,
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
    with :ok <- validate_version(envelope, protocol.version()),
         :ok <- validate_progress(envelope.params),
         :ok <- validate_unsupported_params(envelope.params),
         :ok <-
           validate_expressible_tool(
             envelope,
             runtime.router,
             protocol.version(),
             runtime.authorization
           ) do
      initialize? = envelope.method == "initialize"
      metadata = envelope.transport.metadata
      session = session(metadata)

      context = %Context{
        protocol_version: protocol.version(),
        protocol: protocol,
        transport: envelope.transport,
        request_id: envelope.id,
        request_method: envelope.method,
        request_params: envelope.params,
        auth: envelope.transport.metadata[:auth],
        cancellation: envelope.transport.metadata[:cancellation],
        session: session,
        server_info: implementation(runtime.server_info, protocol.version()),
        server_capabilities: server_capabilities(runtime, session),
        client_info: client_info(envelope, session, initialize?),
        client_capabilities: client_capabilities(envelope, session, initialize?),
        input_responses: Map.get(metadata, :input_responses) || %{},
        request_state: Map.get(metadata, :request_state),
        metadata: Map.get(envelope.params, "_meta", %{}),
        trace_context: TraceContext.from_metadata(Map.get(envelope.params, "_meta", %{}))
      }

      sink = envelope.transport.metadata[:progress_sink]

      # Over stdio, and on a session, logging/setLevel sets the level for later
      # requests. Otherwise the client has set none, and these revisions let
      # the server choose.
      log_level =
        if Map.has_key?(runtime.capabilities, "logging"),
          do: metadata[:log_level] || session_log_level(session) || runtime.log_level

      {:ok,
       %{
         context
         | progress: Progress.bind(sink, context),
           logging: Snodo.Logging.bind(sink, context, log_level)
       }}
    end
  end

  defp session(%{session: %Session{} = session}), do: session
  defp session(_metadata), do: nil

  defp session_log_level(%Session{log_level: level}), do: level
  defp session_log_level(nil), do: nil

  defp client_info(envelope, _session, true), do: envelope.params["clientInfo"]
  defp client_info(_envelope, %Session{client_info: info}, false), do: info
  defp client_info(_envelope, nil, false), do: nil

  defp client_capabilities(envelope, _session, true),
    do: Map.get(envelope.params, "capabilities", %{})

  defp client_capabilities(_envelope, %Session{client_capabilities: capabilities}, false),
    do: capabilities

  defp client_capabilities(_envelope, nil, false), do: %{}

  # listChanged and subscribe are advertised only on a session with a
  # subscription source, the only place these clients can receive those
  # notifications. Other capability settings are not part of these revisions'
  # results.
  defp server_capabilities(runtime, session) do
    notifications? = not is_nil(session) and not is_nil(runtime.subscription_source)

    runtime.capabilities
    |> Map.take(["tools", "prompts", "resources", "completions", "logging", "experimental"])
    |> Map.new(fn
      {"experimental", value} ->
        {"experimental", value}

      {key, settings} when notifications? and key in ["tools", "prompts", "resources"] ->
        {key, Map.filter(settings, fn {name, value} -> notification_setting?(name, value) end)}

      {key, _value} ->
        {key, %{}}
    end)
  end

  defp notification_setting?(name, value),
    do: name in ["listChanged", "subscribe"] and value == true

  # The default preserves the initialize-era error before policy dispatch.
  # Concealment defers it until the router has checked authorization.
  defp validate_expressible_tool(
         %Envelope{method: "tools/call", params: %{"name" => name}},
         %Router{tools: tools},
         version,
         authorization
       )
       when is_binary(name) do
    if Authorization.conceal?(authorization) do
      :ok
    else
      case Map.fetch(tools, name) do
        {:ok, module} -> validate_tool_schema(Tool.definition(module), version)
        :error -> :ok
      end
    end
  end

  defp validate_expressible_tool(_envelope, _router, _version, _authorization), do: :ok

  @doc false
  def validate_tool_schema(tool, version) do
    if expressible?(tool) do
      :ok
    else
      {:error,
       Error.invalid_params(
         "Tool #{tool.name} is not available on #{version}: " <>
           "its input and output schemas must be JSON objects"
       )}
    end
  end

  @doc false
  # Names of the tools whose schemas an initialize-era dialect cannot express.
  # Those revisions require object input and output schemas, so these tools are
  # left out of tools/list and refused by tools/call.
  def inexpressible_tools(%Router{} = router) do
    router
    |> Router.list_tools()
    |> Enum.reject(&expressible?/1)
    |> Enum.map(& &1.name)
  end

  defp expressible?(tool),
    do:
      object_schema?(tool.input_schema) and
        (is_nil(tool.output_schema) or object_schema?(tool.output_schema))

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
      nil ->
        :ok

      token ->
        if Envelope.bounded_id?(token),
          do: :ok,
          else:
            {:error,
             Error.invalid_params(
               "progressToken must be a string of at most 256 bytes or an int64 integer"
             )}
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
  def resolve_operation(%Envelope{method: "logging/setLevel"}), do: {:ok, :logging_set_level}
  def resolve_operation(%Envelope{method: "completion/complete"}), do: {:ok, :completion_complete}

  def resolve_operation(%Envelope{method: "resources/read", params: %{"uri" => uri}})
      when is_binary(uri),
      do: {:ok, {:resource_read, uri}}

  def resolve_operation(%Envelope{
        method: "notifications/cancelled",
        params: %{"requestId" => id} = params
      })
      when is_binary(id) or is_integer(id) do
    {:ok, {:cancel, id, params["reason"]}}
  end

  # The URI is checked in validate_operation/3, after the session, so these
  # methods answer -32601 without one whatever their arguments.
  def resolve_operation(%Envelope{method: method, params: params})
      when is_map_key(@session_operations, method),
      do: {:ok, {Map.fetch!(@session_operations, method), params["uri"]}}

  def resolve_operation(%Envelope{method: method, params: params}) do
    cond do
      Map.has_key?(@lists, method) ->
        {:ok, Map.fetch!(@lists, method)}

      Map.has_key?(@named, method) and is_binary(params["name"]) and params["name"] != "" ->
        {:ok, {Map.fetch!(@named, method), params["name"]}}

      method in [
        "resources/read",
        "notifications/cancelled",
        "tools/call",
        "prompts/get"
      ] ->
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

  def validate_operation(:logging_set_level, params, context) do
    with :ok <- require_capability(:logging_set_level, context) do
      if Snodo.Logging.parse_level(params["level"]) && is_binary(params["level"]),
        do: :ok,
        else: {:error, Error.invalid_params("logging/setLevel requires a valid level")}
    end
  end

  # Subscriptions belong to a session; without one these methods do not exist.
  def validate_operation({kind, uri}, params, context)
      when kind in [:resource_subscribe, :resource_unsubscribe] do
    if match?(%Session{ready?: true}, context.session) and
         get_in(context.server_capabilities, ["resources", "subscribe"]) == true,
       do: validate_subscription_uri(uri, params),
       else: {:error, Error.method_not_found(context.request_method)}
  end

  def validate_operation({:cancel, _id, reason}, _params, _context)
      when is_nil(reason) or is_binary(reason) do
    :ok
  end

  def validate_operation({:cancel, _id, _reason}, _params, _context),
    do: {:error, Error.invalid_params("Cancellation reason must be a string")}

  def validate_operation(operation, params, context) do
    with :ok <- require_capability(operation, context),
         :ok <- optional_cursor(params),
         do: validate_arguments(operation, params)
  end

  defp validate_subscription_uri(uri, params) when is_binary(uri),
    do: validate_arguments({:resource_read, uri}, params)

  defp validate_subscription_uri(_uri, _params),
    do: {:error, Error.invalid_params("Missing or invalid operation arguments")}

  defp require_capability(operation, context) do
    capability =
      case operation do
        op when op in [:tools_list] -> "tools"
        {:tools_call, _} -> "tools"
        op when op in [:prompts_list] -> "prompts"
        {:prompt_get, _} -> "prompts"
        :completion_complete -> "completions"
        :logging_set_level -> "logging"
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

  # Input requests reach these clients as server-initiated requests, which
  # need a session to carry them.
  def validate_result(operation, %Result{kind: :input_required} = result, context) do
    if match?(%Context{session: %Session{ready?: true}}, context),
      do: MRTR.validate_result(operation, result, context),
      else: {:error, Error.internal("Input requests need an initialize-era session")}
  end

  def validate_result(_operation, %Result{kind: kind}, _context)
      when kind in [:subscription, :wire],
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

  def validate_result(_operation, _result, _context), do: :ok
  defp object_schema?(%{"type" => "object"}), do: true
  defp object_schema?(_schema), do: false

  # Never written to the client: Snodo.Session.Exchange sends the requests
  # and calls the handler again.
  def shape_result(_operation, %Result{kind: :input_required, value: value}, _context),
    do: Map.put(value, "resultType", "input_required")

  def shape_result(operation, result, context) do
    operation |> shape(result, context) |> metadata(result)
  end

  defp shape(:tools_list, %Result{value: tools} = result, context) do
    tools =
      tools
      |> Enum.filter(&expressible?/1)
      |> Enum.map(&tool_definition(&1, context.protocol_version))

    paginated(%{"tools" => tools}, result)
  end

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

  defp tool_result(%Result{kind: :content, value: content}),
    do: %{"content" => List.wrap(content), "isError" => false}

  defp tool_result(%Result{kind: :error, value: message}),
    do: %{"content" => [%{"type" => "text", "text" => message}], "isError" => true}

  defp tool_result(%Result{kind: :raw, value: value}),
    do: value |> Map.put_new("content", []) |> Map.put_new("isError", false)

  defp tool_definition(tool, version) do
    %{
      "name" => tool.name,
      "title" => tool.title,
      "description" => tool.description,
      "inputSchema" => tool.input_schema,
      "outputSchema" => tool.output_schema,
      "annotations" => tool.annotations,
      "icons" => tool.icons,
      "_meta" => tool.metadata
    }
    |> Enum.reject(fn
      {_key, nil} -> true
      {"icons", []} -> true
      {"_meta", metadata} when metadata == %{} -> true
      _entry -> false
    end)
    |> Map.new()
    |> implementation(version)
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

  def shape_subscription_event(%SubscriptionEvent{kind: :resource_updated} = event, _id, _context) do
    %{
      "jsonrpc" => "2.0",
      "method" => "notifications/resources/updated",
      "params" => Map.put(event.params, "uri", event.uri)
    }
  end

  def shape_subscription_event(%SubscriptionEvent{kind: kind} = event, _id, _context)
      when is_map_key(@list_changed, kind) do
    notification = %{"jsonrpc" => "2.0", "method" => Map.fetch!(@list_changed, kind)}
    if event.params == %{}, do: notification, else: Map.put(notification, "params", event.params)
  end

  def transport_policy(%Envelope{method: "initialize"}), do: %Policy{allowed_methods: ["POST"]}

  def transport_policy(_envelope),
    do: %Policy{allowed_methods: ["POST"], required_headers: ["mcp-protocol-version"]}
end
