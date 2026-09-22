defmodule MCP.Protocol.V2026_07_28 do
  @moduledoc "Minimal server dialect for MCP 2026-07-28."

  @behaviour MCP.Protocol

  alias MCP.Completion
  alias MCP.Context
  alias MCP.Envelope
  alias MCP.Error
  alias MCP.Extension.Registry, as: ExtensionRegistry
  alias MCP.MRTR
  alias MCP.Progress
  alias MCP.Prompt
  alias MCP.Protocol
  alias MCP.Protocol.Profile
  alias MCP.Protocol.Profile.Method
  alias MCP.Protocol.Registry
  alias MCP.Resource
  alias MCP.Result
  alias MCP.Server.Runtime
  alias MCP.Subscription.Event, as: SubscriptionEvent
  alias MCP.Tool.Definition
  alias MCP.Transport.Context, as: TransportContext
  alias MCP.Transport.Policy

  @version "2026-07-28"
  @protocol_version_key "io.modelcontextprotocol/protocolVersion"
  @client_info_key "io.modelcontextprotocol/clientInfo"
  @client_capabilities_key "io.modelcontextprotocol/clientCapabilities"
  @server_info_key "io.modelcontextprotocol/serverInfo"
  @log_level_key "io.modelcontextprotocol/logLevel"
  @subscription_id_key "io.modelcontextprotocol/subscriptionId"
  @protocol_header "mcp-protocol-version"
  @method_header "mcp-method"
  @name_header "mcp-name"
  @cancel_method "notifications/cancelled"
  @logging_levels ~w(debug info notice warning error critical alert emergency)
  @meta_key ~r/^(?:(?:[A-Za-z](?:[A-Za-z0-9-]*[A-Za-z0-9])?)(?:\.(?:[A-Za-z](?:[A-Za-z0-9-]*[A-Za-z0-9])?))*\/)?(?:[A-Za-z0-9](?:[A-Za-z0-9._-]*[A-Za-z0-9])?)?$/

  @unsupported_server_notifications [
    {@cancel_method, nil, :required, :active},
    {"notifications/message", "logging", :required, :deprecated}
  ]

  @unsupported_embedded_requests [
    {"roots/list", :optional, :deprecated},
    {"sampling/createMessage", :required, :deprecated}
  ]

  @unsupported_methods Enum.map(
                         @unsupported_server_notifications,
                         fn {name, capability, params, lifecycle} ->
                           Method.new!(
                             name: name,
                             kind: :notification,
                             directions: [:server_to_client],
                             params: params,
                             capability: capability,
                             status: :unsupported,
                             lifecycle: lifecycle
                           )
                         end
                       ) ++
                         Enum.map(@unsupported_embedded_requests, fn {name, params, lifecycle} ->
                           Method.new!(
                             name: name,
                             kind: :request,
                             directions: [:server_to_client],
                             params: params,
                             status: :unsupported,
                             placement: :mrtr_embedded,
                             lifecycle: lifecycle
                           )
                         end)

  @profile Profile.new!(
             version: @version,
             status: :released,
             scope: :implemented_slice,
             era: :stateless,
             batching: :forbidden,
             request_metadata: %{request: :required, notification: :optional},
             methods:
               [
                 Method.new!(
                   name: "elicitation/create",
                   kind: :request,
                   directions: [:server_to_client],
                   params: :required,
                   status: :implemented,
                   placement: :mrtr_embedded
                 ),
                 Method.new!(
                   name: "server/discover",
                   kind: :request,
                   directions: [:client_to_server],
                   params: :required,
                   status: :implemented,
                   validator: {__MODULE__, :inspect_discover_params}
                 ),
                 Method.new!(
                   name: "completion/complete",
                   kind: :request,
                   directions: [:client_to_server],
                   params: :required,
                   capability: "completions",
                   status: :implemented,
                   validator: {__MODULE__, :inspect_completion_params}
                 ),
                 Method.new!(
                   name: "tools/list",
                   kind: :request,
                   directions: [:client_to_server],
                   params: :required,
                   capability: "tools",
                   status: :implemented,
                   validator: {__MODULE__, :inspect_tools_list_params}
                 ),
                 Method.new!(
                   name: "tools/call",
                   kind: :request,
                   directions: [:client_to_server],
                   params: :required,
                   capability: "tools",
                   status: :implemented,
                   validator: {__MODULE__, :inspect_tools_call_params}
                 ),
                 Method.new!(
                   name: "prompts/list",
                   kind: :request,
                   directions: [:client_to_server],
                   params: :required,
                   capability: "prompts",
                   status: :implemented,
                   validator: {__MODULE__, :inspect_prompts_list_params}
                 ),
                 Method.new!(
                   name: "prompts/get",
                   kind: :request,
                   directions: [:client_to_server],
                   params: :required,
                   capability: "prompts",
                   status: :implemented,
                   validator: {__MODULE__, :inspect_prompt_get_params}
                 ),
                 Method.new!(
                   name: "resources/list",
                   kind: :request,
                   directions: [:client_to_server],
                   params: :required,
                   capability: "resources",
                   status: :implemented,
                   validator: {__MODULE__, :inspect_resources_list_params}
                 ),
                 Method.new!(
                   name: "resources/templates/list",
                   kind: :request,
                   directions: [:client_to_server],
                   params: :required,
                   capability: "resources",
                   status: :implemented,
                   validator: {__MODULE__, :inspect_resource_templates_list_params}
                 ),
                 Method.new!(
                   name: "resources/read",
                   kind: :request,
                   directions: [:client_to_server],
                   params: :required,
                   capability: "resources",
                   status: :implemented,
                   validator: {__MODULE__, :inspect_resource_read_params}
                 ),
                 Method.new!(
                   name: "subscriptions/listen",
                   kind: :request,
                   directions: [:client_to_server],
                   params: :required,
                   status: :implemented,
                   validator: {__MODULE__, :inspect_subscriptions_listen_params}
                 ),
                 Method.new!(
                   name: @cancel_method,
                   kind: :notification,
                   directions: [:client_to_server],
                   params: :required,
                   status: :implemented,
                   validator: {__MODULE__, :inspect_cancelled_params}
                 ),
                 Method.new!(
                   name: "notifications/progress",
                   kind: :notification,
                   directions: [:server_to_client],
                   params: :required,
                   status: :implemented,
                   validator: {__MODULE__, :inspect_progress_params}
                 ),
                 Method.new!(
                   name: "notifications/subscriptions/acknowledged",
                   kind: :notification,
                   directions: [:server_to_client],
                   params: :required,
                   status: :implemented
                 ),
                 Method.new!(
                   name: "notifications/tools/list_changed",
                   kind: :notification,
                   directions: [:server_to_client],
                   params: :optional,
                   capability: "tools",
                   status: :implemented
                 ),
                 Method.new!(
                   name: "notifications/prompts/list_changed",
                   kind: :notification,
                   directions: [:server_to_client],
                   params: :optional,
                   capability: "prompts",
                   status: :implemented
                 ),
                 Method.new!(
                   name: "notifications/resources/list_changed",
                   kind: :notification,
                   directions: [:server_to_client],
                   params: :optional,
                   capability: "resources",
                   status: :implemented
                 ),
                 Method.new!(
                   name: "notifications/resources/updated",
                   kind: :notification,
                   directions: [:server_to_client],
                   params: :required,
                   capability: "resources",
                   status: :implemented
                 )
               ] ++ @unsupported_methods,
             capabilities: ["completions", "tools", "prompts", "resources"],
             transports: %{direct: :tested, stdio: :tested, streamable_http: :tested},
             limitations: %{
               official_server_conformance: :partial,
               schema_validation: :pluggable,
               subscriptions: :tested,
               multi_round_trip_requests: :elicitation_and_state,
               list_pagination: :tested,
               transport_policy_enforcement: :tested,
               method_catalog: :complete,
               schema_commit: "5f5440bb26a62e2cf3440b92da5a667efa03b267"
             },
             specification: "https://modelcontextprotocol.io/specification/2026-07-28"
           )

  @core_methods Profile.method_names(@profile,
                  kind: :request,
                  status: :implemented,
                  direction: :client_to_server
                )

  @impl true
  def profile, do: @profile

  @impl true
  def version, do: @version

  @impl true
  def era, do: :stateless

  @impl true
  def detect(%Envelope{kind: :notification, method: @cancel_method} = envelope) do
    header = TransportContext.get_header(envelope.transport.request_headers, @protocol_header)
    metadata = Map.get(Protocol.request_meta(envelope), @protocol_version_key)
    if header in [nil, @version] and metadata in [nil, @version], do: :exact, else: false
  end

  def detect(%Envelope{kind: :request, method: method} = envelope) do
    metadata_version = Map.get(Protocol.request_meta(envelope), @protocol_version_key)

    header_version =
      TransportContext.get_header(envelope.transport.request_headers, @protocol_header)

    cond do
      metadata_version == @version or header_version == @version -> :exact
      not is_nil(metadata_version) or not is_nil(header_version) -> :fallback
      method in @core_methods -> :fallback
      true -> false
    end
  end

  def detect(%Envelope{}), do: false

  @impl true
  def decode_request(raw, %TransportContext{} = transport), do: Envelope.decode(raw, transport)

  @impl true
  def build_context(%Envelope{} = envelope, %Runtime{} = runtime) do
    with {:ok, metadata} <- metadata_object(envelope),
         :ok <- validate_request_metadata(envelope, metadata, runtime),
         {:ok, client_info} <- optional_client_info(metadata),
         {:ok, client_capabilities} <- client_capabilities(envelope, metadata) do
      context = %Context{
        protocol_version: @version,
        protocol: __MODULE__,
        client_info: client_info,
        client_capabilities: client_capabilities,
        server_info: runtime.server_info,
        server_capabilities: runtime.capabilities,
        session: nil,
        auth: envelope.transport.metadata[:auth],
        transport: envelope.transport,
        request_id: envelope.id,
        request_method: envelope.method,
        request_params: envelope.params,
        request_state: Map.get(envelope.params, "requestState"),
        input_responses: Map.get(envelope.params, "inputResponses", %{}),
        cancellation: envelope.transport.metadata[:cancellation],
        extensions: negotiated_extensions(client_capabilities, runtime.capabilities),
        metadata: metadata
      }

      sink =
        if envelope.method != "subscriptions/listen",
          do: envelope.transport.metadata[:progress_sink]

      {:ok, %{context | progress: Progress.bind(sink, context)}}
    end
  end

  @impl true
  def resolve_operation(%Envelope{kind: :request, method: "server/discover"}),
    do: {:ok, :server_discover}

  def resolve_operation(%Envelope{kind: :request, method: "completion/complete"}),
    do: {:ok, :completion_complete}

  def resolve_operation(%Envelope{kind: :request, method: "tools/list"}),
    do: {:ok, :tools_list}

  def resolve_operation(%Envelope{kind: :request, method: "prompts/list"}),
    do: {:ok, :prompts_list}

  def resolve_operation(%Envelope{
        kind: :request,
        method: "prompts/get",
        params: %{"name" => name}
      })
      when is_binary(name) and name != "" do
    {:ok, {:prompt_get, name}}
  end

  def resolve_operation(%Envelope{kind: :request, method: "prompts/get"}) do
    {:error, Error.invalid_params("prompts/get requires a string name")}
  end

  def resolve_operation(%Envelope{kind: :request, method: "resources/list"}),
    do: {:ok, :resources_list}

  def resolve_operation(%Envelope{kind: :request, method: "resources/templates/list"}),
    do: {:ok, :resource_templates_list}

  def resolve_operation(%Envelope{kind: :request, method: "subscriptions/listen"}),
    do: {:ok, :subscriptions_listen}

  def resolve_operation(%Envelope{
        kind: :request,
        method: "resources/read",
        params: %{"uri" => uri}
      })
      when is_binary(uri) and uri != "" do
    {:ok, {:resource_read, uri}}
  end

  def resolve_operation(%Envelope{kind: :request, method: "resources/read"}) do
    {:error, Error.invalid_params("resources/read requires an absolute URI")}
  end

  def resolve_operation(%Envelope{
        kind: :request,
        method: "tools/call",
        params: %{"name" => name}
      })
      when is_binary(name) and name != "" do
    {:ok, {:tools_call, name}}
  end

  def resolve_operation(%Envelope{kind: :request, method: "tools/call"}) do
    {:error, Error.invalid_params("tools/call requires a string name")}
  end

  def resolve_operation(%Envelope{
        kind: :notification,
        method: @cancel_method,
        params: %{"requestId" => request_id} = params
      })
      when is_binary(request_id) or is_integer(request_id) do
    reason = Map.get(params, "reason")
    metadata = Map.get(params, "_meta", %{})

    if (is_nil(reason) or is_binary(reason)) and valid_meta_object?(metadata) do
      {:ok, {:cancel, request_id, reason}}
    else
      :not_handled
    end
  end

  def resolve_operation(%Envelope{}), do: :not_handled

  @impl true
  def validate_operation(:server_discover, _params, %Context{}), do: :ok

  def validate_operation(:completion_complete, params, %Context{} = context) do
    with :ok <- require_server_capability(context, "completions", "completion/complete") do
      validate_completion_params(params)
    end
  end

  def validate_operation(:tools_list, params, %Context{} = context) do
    with :ok <- require_server_capability(context, "tools", "tools/list") do
      validate_optional_cursor(params)
    end
  end

  def validate_operation(:resources_list, params, %Context{} = context) do
    with :ok <- require_server_capability(context, "resources", "resources/list") do
      validate_optional_cursor(params)
    end
  end

  def validate_operation(:prompts_list, params, %Context{} = context) do
    with :ok <- require_server_capability(context, "prompts", "prompts/list") do
      validate_optional_cursor(params)
    end
  end

  def validate_operation({:prompt_get, _name}, params, %Context{} = context) do
    with :ok <- require_server_capability(context, "prompts", "prompts/get") do
      validate_prompt_arguments(params)
    end
  end

  def validate_operation(:resource_templates_list, params, %Context{} = context) do
    with :ok <-
           require_server_capability(context, "resources", "resources/templates/list") do
      validate_optional_cursor(params)
    end
  end

  def validate_operation({:resource_read, _uri}, params, %Context{} = context) do
    with :ok <- require_server_capability(context, "resources", "resources/read") do
      validate_resource_uri(params)
    end
  end

  def validate_operation({:tools_call, _name}, params, %Context{} = context) do
    with :ok <- require_server_capability(context, "tools", "tools/call") do
      validate_arguments(params)
    end
  end

  def validate_operation(:subscriptions_listen, params, %Context{}) do
    case inspect_subscriptions_listen_params(params) do
      :ok -> :ok
      {:error, message} -> {:error, Error.invalid_params(message)}
    end
  end

  def validate_operation({:cancel, _request_id, _reason}, _params, %Context{}), do: :ok

  def validate_operation(_operation, _params, %Context{}) do
    {:error, Error.invalid_params()}
  end

  @impl true
  def validate_result(operation, result, context),
    do: MRTR.validate_result(operation, result, context)

  @impl true
  def shape_result(_operation, %Result{kind: :input_required, value: value} = result, context) do
    value
    |> Map.put("resultType", "input_required")
    |> stamp_response_metadata(result, context)
  end

  def shape_result(_operation, %Result{kind: :wire, value: value} = result, context)
      when is_map(value) do
    stamp_response_metadata(value, result, context)
  end

  def shape_result(:server_discover, %Result{kind: :raw, value: value} = result, context)
      when is_map(value) do
    value
    |> complete_result()
    |> stamp_response_metadata(result, context)
  end

  def shape_result(
        :completion_complete,
        %Result{
          kind: :completion,
          value: %{values: values, total: total, has_more: has_more}
        } = result,
        context
      ) do
    completion =
      %{"values" => values}
      |> maybe_put("total", total)
      |> maybe_put("hasMore", has_more)

    %{"resultType" => "complete", "completion" => completion}
    |> stamp_response_metadata(result, context)
  end

  def shape_result(:tools_list, %Result{kind: :tools, value: tools} = result, context) do
    %{
      "resultType" => "complete",
      "tools" => Enum.map(tools, &shape_tool_definition/1),
      "ttlMs" => result.metadata[:ttl_ms] || 0,
      "cacheScope" => result.metadata[:cache_scope] || "private"
    }
    |> maybe_put("nextCursor", result.metadata[:next_cursor])
    |> stamp_response_metadata(result, context)
  end

  def shape_result(:prompts_list, %Result{kind: :prompts, value: prompts} = result, context)
      when is_list(prompts) do
    %{
      "resultType" => "complete",
      "prompts" => Enum.map(prompts, &Prompt.definition_to_map/1),
      "ttlMs" => cache_ttl(result),
      "cacheScope" => cache_scope(result)
    }
    |> maybe_put("nextCursor", result.metadata[:next_cursor])
    |> stamp_response_metadata(result, context)
  end

  def shape_result(
        {:prompt_get, _name},
        %Result{kind: :prompt_get, value: %{messages: messages, description: description}} =
          result,
        context
      )
      when is_list(messages) do
    %{"resultType" => "complete", "messages" => messages}
    |> maybe_put("description", description)
    |> stamp_response_metadata(result, context)
  end

  def shape_result(
        :resources_list,
        %Result{kind: :resources, value: resources} = result,
        context
      )
      when is_list(resources) do
    %{
      "resultType" => "complete",
      "resources" => Enum.map(resources, &Resource.definition_to_map/1),
      "ttlMs" => cache_ttl(result),
      "cacheScope" => cache_scope(result)
    }
    |> maybe_put("nextCursor", result.metadata[:next_cursor])
    |> stamp_response_metadata(result, context)
  end

  def shape_result(
        :resource_templates_list,
        %Result{kind: :resource_templates, value: templates} = result,
        context
      )
      when is_list(templates) do
    %{
      "resultType" => "complete",
      "resourceTemplates" => Enum.map(templates, &Resource.definition_to_map/1),
      "ttlMs" => cache_ttl(result),
      "cacheScope" => cache_scope(result)
    }
    |> maybe_put("nextCursor", result.metadata[:next_cursor])
    |> stamp_response_metadata(result, context)
  end

  def shape_result(
        {:resource_read, _uri},
        %Result{kind: :resource_read, value: contents} = result,
        context
      )
      when is_list(contents) do
    %{
      "resultType" => "complete",
      "contents" => contents,
      "ttlMs" => cache_ttl(result),
      "cacheScope" => cache_scope(result)
    }
    |> stamp_response_metadata(result, context)
  end

  def shape_result({:tools_call, _name}, %Result{} = result, context) do
    result
    |> shape_tool_result()
    |> complete_result()
    |> stamp_response_metadata(result, context)
  end

  def shape_result(_operation, %Result{kind: :raw, value: value} = result, context)
      when is_map(value) do
    value
    |> complete_result()
    |> stamp_response_metadata(result, context)
  end

  def shape_result(_operation, %Result{} = result, context) do
    %{"value" => result.value}
    |> complete_result()
    |> stamp_response_metadata(result, context)
  end

  @impl true
  def shape_error(%Error{} = error, %Context{}), do: Error.to_json_rpc(error)
  def shape_error(%Error{} = error, nil), do: Error.to_json_rpc(error)

  @impl true
  def shape_progress(token, fields, %Context{}) do
    %{
      "jsonrpc" => "2.0",
      "method" => "notifications/progress",
      "params" => Map.put(fields, "progressToken", token)
    }
  end

  @impl true
  def shape_subscription_ack(accepted_filter, id, %Context{}) do
    %{
      "jsonrpc" => "2.0",
      "method" => "notifications/subscriptions/acknowledged",
      "params" => %{
        "_meta" => %{@subscription_id_key => id},
        "notifications" => accepted_filter
      }
    }
  end

  @impl true
  def shape_subscription_event(%SubscriptionEvent{} = event, id, %Context{}) do
    params =
      event.params
      |> Map.put("_meta", subscription_metadata(event, id))
      |> maybe_put_resource_uri(event)

    %{
      "jsonrpc" => "2.0",
      "method" => subscription_event_method(event.kind),
      "params" => params
    }
  end

  @impl true
  def shape_subscription_result(id, %Context{} = context) do
    %{
      "jsonrpc" => "2.0",
      "id" => id,
      "result" => %{
        "resultType" => "complete",
        "_meta" => %{
          @subscription_id_key => id,
          @server_info_key => context.server_info
        }
      }
    }
  end

  @impl true
  def transport_policy(%Envelope{method: method})
      when method in ["tools/call", "prompts/get", "resources/read"] do
    %Policy{
      allowed_methods: ["POST"],
      require_protocol_header?: true,
      allow_session_id?: false,
      required_headers: [@protocol_header, @method_header, @name_header],
      mirrored_headers: %{
        @protocol_header => %{path: ["params", "_meta", @protocol_version_key]},
        @method_header => %{path: ["method"]},
        @name_header => %{
          path: name_source_path(method),
          encoding: :base64_sentinel
        }
      }
    }
  end

  def transport_policy(%Envelope{method: "subscriptions/listen"}) do
    %Policy{
      allowed_methods: ["POST"],
      require_protocol_header?: true,
      allow_session_id?: false,
      required_headers: [@protocol_header, @method_header],
      mirrored_headers: %{
        @protocol_header => %{path: ["params", "_meta", @protocol_version_key]},
        @method_header => %{path: ["method"]}
      },
      stream_mode: :sse
    }
  end

  def transport_policy(%Envelope{}) do
    %Policy{
      allowed_methods: ["POST"],
      require_protocol_header?: true,
      allow_session_id?: false,
      required_headers: [@protocol_header, @method_header],
      mirrored_headers: %{
        @protocol_header => %{path: ["params", "_meta", @protocol_version_key]},
        @method_header => %{path: ["method"]}
      }
    }
  end

  def transport_policy(nil) do
    %Policy{
      allowed_methods: ["POST"],
      require_protocol_header?: true,
      allow_session_id?: false,
      required_headers: [@protocol_header, @method_header],
      mirrored_headers: %{
        @protocol_header => %{path: ["params", "_meta", @protocol_version_key]},
        @method_header => %{path: ["method"]}
      }
    }
  end

  defp name_source_path("resources/read"), do: ["params", "uri"]
  defp name_source_path(_named_method), do: ["params", "name"]

  @impl true
  def server_discovery(%Runtime{} = runtime) do
    cache = runtime.discovery_cache

    capabilities =
      @profile
      |> Profile.project_capabilities(runtime.capabilities)
      |> then(
        &ExtensionRegistry.project_capabilities(
          runtime.extension_registry,
          @version,
          &1
        )
      )

    %{
      "supportedVersions" => Registry.versions(runtime.protocol_registry),
      "capabilities" => capabilities,
      "ttlMs" => cache.ttl_ms,
      "cacheScope" => cache.scope
    }
    |> maybe_put("instructions", runtime.instructions)
  end

  @impl true
  def request_metadata(client_capabilities) when is_map(client_capabilities) do
    %{
      @protocol_version_key => @version,
      @client_capabilities_key => client_capabilities
    }
  end

  def protocol_version_key, do: @protocol_version_key
  def client_info_key, do: @client_info_key
  def client_capabilities_key, do: @client_capabilities_key
  def server_info_key, do: @server_info_key

  @doc false
  def inspect_discover_params(params) when is_map(params), do: :ok

  @doc false
  def inspect_completion_params(params) when is_map(params) do
    case Completion.parse(params) do
      {:ok, %Completion{}} -> :ok
      {:error, %Error{message: message}} -> {:error, message}
    end
  end

  @doc false
  def inspect_tools_list_params(params) when is_map(params) do
    inspect_optional_cursor(params, "tools/list")
  end

  @doc false
  def inspect_prompts_list_params(params) when is_map(params) do
    inspect_optional_cursor(params, "prompts/list")
  end

  @doc false
  def inspect_prompt_get_params(params) when is_map(params) do
    with :ok <- inspect_prompt_name(params),
         :ok <- MRTR.inspect_params(params) do
      inspect_prompt_arguments(params)
    end
  end

  @doc false
  def inspect_resources_list_params(params) when is_map(params) do
    inspect_optional_cursor(params, "resources/list")
  end

  @doc false
  def inspect_resource_templates_list_params(params) when is_map(params) do
    inspect_optional_cursor(params, "resources/templates/list")
  end

  @doc false
  def inspect_resource_read_params(params) when is_map(params) do
    with :ok <- MRTR.inspect_params(params) do
      inspect_read_uri(params)
    end
  end

  defp inspect_read_uri(params) do
    case Map.fetch(params, "uri") do
      {:ok, uri} when is_binary(uri) and uri != "" ->
        if valid_uri?(uri),
          do: :ok,
          else: {:error, "resources/read uri must be an absolute URI"}

      _missing_or_invalid ->
        {:error, "resources/read requires a non-empty string uri"}
    end
  end

  @doc false
  def inspect_subscriptions_listen_params(params) when is_map(params) do
    case Map.fetch(params, "notifications") do
      {:ok, notifications} when is_map(notifications) ->
        with :ok <- inspect_subscription_filter_object(notifications),
             :ok <- inspect_subscription_boolean(notifications, "toolsListChanged"),
             :ok <- inspect_subscription_boolean(notifications, "promptsListChanged"),
             :ok <- inspect_subscription_boolean(notifications, "resourcesListChanged") do
          inspect_resource_subscriptions(notifications)
        end

      _missing_or_invalid ->
        {:error, "subscriptions/listen requires a notifications object"}
    end
  end

  @doc false
  def inspect_tools_call_params(params) when is_map(params) do
    with :ok <- inspect_tool_name(params),
         :ok <- MRTR.inspect_params(params) do
      inspect_tool_arguments(params)
    end
  end

  @doc false
  def inspect_cancelled_params(params) when is_map(params) do
    with :ok <- inspect_cancelled_request_id(params) do
      inspect_cancelled_reason(params)
    end
  end

  @doc false
  def inspect_progress_params(params) when is_map(params) do
    cond do
      not (is_binary(params["progressToken"]) or is_integer(params["progressToken"])) ->
        {:error, "progress notification requires a string or integer progressToken"}

      not is_number(params["progress"]) ->
        {:error, "progress notification requires numeric progress"}

      Map.has_key?(params, "total") and not is_number(params["total"]) ->
        {:error, "progress notification total must be numeric"}

      Map.has_key?(params, "message") and not is_binary(params["message"]) ->
        {:error, "progress notification message must be a string"}

      true ->
        :ok
    end
  end

  defp inspect_tool_name(params) do
    case Map.fetch(params, "name") do
      {:ok, name} when is_binary(name) and name != "" -> :ok
      _missing_or_invalid -> {:error, "tools/call requires a non-empty string name"}
    end
  end

  defp inspect_prompt_name(params) do
    case Map.fetch(params, "name") do
      {:ok, name} when is_binary(name) and name != "" -> :ok
      _missing_or_invalid -> {:error, "prompts/get requires a non-empty string name"}
    end
  end

  defp inspect_optional_cursor(params, method) do
    case Map.fetch(params, "cursor") do
      :error -> :ok
      {:ok, cursor} when is_binary(cursor) -> :ok
      {:ok, _invalid} -> {:error, "#{method} cursor must be a string"}
    end
  end

  defp inspect_tool_arguments(params) do
    case Map.fetch(params, "arguments") do
      :error -> :ok
      {:ok, arguments} when is_map(arguments) -> :ok
      {:ok, _invalid} -> {:error, "tools/call arguments must be an object"}
    end
  end

  defp inspect_prompt_arguments(params) do
    case Map.fetch(params, "arguments") do
      :error ->
        :ok

      {:ok, arguments} when is_map(arguments) ->
        inspect_prompt_argument_map(arguments)

      {:ok, _invalid} ->
        {:error, "prompts/get arguments must be an object"}
    end
  end

  defp inspect_prompt_argument_map(arguments) do
    if Enum.all?(arguments, fn {key, value} -> is_binary(key) and is_binary(value) end),
      do: :ok,
      else: {:error, "prompts/get arguments must map strings to strings"}
  end

  defp inspect_cancelled_request_id(params) do
    case Map.fetch(params, "requestId") do
      {:ok, request_id} when is_binary(request_id) or is_integer(request_id) -> :ok
      _missing_or_invalid -> {:error, "notifications/cancelled requires a requestId"}
    end
  end

  defp inspect_cancelled_reason(params) do
    case Map.fetch(params, "reason") do
      :error -> :ok
      {:ok, reason} when is_binary(reason) -> :ok
      {:ok, _invalid} -> {:error, "notifications/cancelled reason must be a string"}
    end
  end

  defp inspect_subscription_filter_object(notifications) do
    if json_object?(notifications),
      do: :ok,
      else: {:error, "subscriptions/listen notifications must be a JSON object"}
  end

  defp inspect_subscription_boolean(notifications, key) do
    case Map.fetch(notifications, key) do
      :error -> :ok
      {:ok, value} when is_boolean(value) -> :ok
      {:ok, _invalid} -> {:error, "subscriptions/listen #{key} must be a boolean"}
    end
  end

  defp inspect_resource_subscriptions(notifications) do
    case Map.fetch(notifications, "resourceSubscriptions") do
      :error ->
        :ok

      {:ok, subscriptions} when is_list(subscriptions) ->
        if Enum.all?(subscriptions, &(is_binary(&1) and valid_uri?(&1))),
          do: :ok,
          else:
            {:error,
             "subscriptions/listen resourceSubscriptions must contain absolute URI strings"}

      {:ok, _invalid} ->
        {:error, "subscriptions/listen resourceSubscriptions must be a list"}
    end
  end

  defp metadata_object(%Envelope{params: params}) do
    case Map.fetch(params, "_meta") do
      {:ok, metadata} when is_map(metadata) -> {:ok, metadata}
      {:ok, _invalid} -> {:error, Error.invalid_params("_meta must be an object")}
      :error -> {:ok, %{}}
    end
  end

  defp validate_request_metadata(%Envelope{kind: :notification}, _metadata, _runtime), do: :ok

  defp validate_request_metadata(%Envelope{kind: :request} = envelope, metadata, runtime) do
    with :ok <- validate_meta_object(metadata),
         :ok <- validate_optional_progress_token(metadata),
         :ok <- validate_optional_log_level(metadata),
         {:ok, requested} <- required_string(metadata, @protocol_version_key),
         :ok <- validate_protocol_header(envelope.transport, requested) do
      validate_supported_version(requested, runtime)
    end
  end

  defp validate_protocol_header(%TransportContext{} = transport, body_version) do
    case TransportContext.get_header(transport.request_headers, @protocol_header) do
      nil ->
        :ok

      ^body_version ->
        :ok

      header_version when is_binary(header_version) ->
        {:error,
         %Error{
           code: -32_020,
           message: "Protocol header does not match request metadata",
           kind: :protocol,
           data: %{"header" => header_version, "body" => body_version}
         }}
    end
  end

  defp validate_supported_version(@version, %Runtime{}), do: :ok

  defp validate_supported_version(requested, %Runtime{} = runtime) do
    {:error,
     %Error{
       code: -32_022,
       message: "Unsupported protocol version",
       kind: :protocol,
       data: %{
         "requested" => requested,
         "supported" => Registry.versions(runtime.protocol_registry)
       }
     }}
  end

  defp optional_client_info(metadata) do
    case Map.fetch(metadata, @client_info_key) do
      {:ok, %{"name" => name, "version" => version} = info}
      when is_binary(name) and is_binary(version) ->
        validate_implementation(info)

      {:ok, _invalid} ->
        {:error, Error.invalid_params("Client info must include string name and version")}

      :error ->
        {:ok, nil}
    end
  end

  defp client_capabilities(%Envelope{kind: :notification}, metadata) do
    case Map.get(metadata, @client_capabilities_key, %{}) do
      capabilities when is_map(capabilities) -> validate_capabilities(capabilities)
      _invalid -> {:error, Error.invalid_params("Client capabilities must be an object")}
    end
  end

  defp client_capabilities(%Envelope{kind: :request}, metadata) do
    case Map.fetch(metadata, @client_capabilities_key) do
      {:ok, capabilities} when is_map(capabilities) -> validate_capabilities(capabilities)
      {:ok, _invalid} -> {:error, Error.invalid_params("Client capabilities must be an object")}
      :error -> {:error, Error.invalid_params("Missing required client capabilities metadata")}
    end
  end

  defp validate_capabilities(capabilities) do
    with :ok <- validate_string_keyed_json_object(capabilities, "Client capabilities"),
         :ok <- validate_optional_object(capabilities, "roots", "Client roots capability"),
         :ok <- validate_sampling_capability(capabilities),
         :ok <- validate_elicitation_capability(capabilities),
         :ok <- validate_object_registry(capabilities, "experimental", false),
         :ok <- validate_object_registry(capabilities, "extensions", true) do
      {:ok, capabilities}
    end
  end

  defp required_string(metadata, key) do
    case Map.fetch(metadata, key) do
      {:ok, value} when is_binary(value) -> {:ok, value}
      {:ok, _invalid} -> {:error, Error.invalid_params("#{key} must be a string")}
      :error -> {:error, Error.invalid_params("Missing required #{key} metadata")}
    end
  end

  defp require_server_capability(%Context{} = context, capability, method) do
    if Map.has_key?(context.server_capabilities, capability) do
      :ok
    else
      {:error, Error.method_not_found(method)}
    end
  end

  defp validate_optional_cursor(params) do
    case Map.fetch(params, "cursor") do
      {:ok, cursor} when is_binary(cursor) ->
        :ok

      {:ok, _invalid} ->
        {:error, Error.invalid_params("Cursor must be a string")}

      :error ->
        :ok
    end
  end

  defp validate_resource_uri(params) do
    case inspect_resource_read_params(params) do
      :ok -> :ok
      {:error, message} -> {:error, Error.invalid_params(message)}
    end
  end

  defp validate_arguments(params) do
    case Map.fetch(params, "arguments") do
      {:ok, arguments} when is_map(arguments) -> :ok
      {:ok, _invalid} -> {:error, Error.invalid_params("Tool arguments must be an object")}
      :error -> :ok
    end
  end

  defp validate_prompt_arguments(params) do
    case inspect_prompt_arguments(params) do
      :ok -> :ok
      {:error, message} -> {:error, Error.invalid_params(message)}
    end
  end

  defp validate_completion_params(params) do
    case Completion.parse(params) do
      {:ok, %Completion{}} -> :ok
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  defp validate_meta_object(metadata) do
    if valid_meta_object?(metadata) do
      :ok
    else
      {:error, Error.invalid_params("_meta contains an invalid key or non-JSON value")}
    end
  end

  defp valid_meta_object?(metadata) when is_map(metadata) do
    Enum.all?(metadata, fn {key, value} ->
      is_binary(key) and Regex.match?(@meta_key, key) and json_value?(value)
    end)
  end

  defp valid_meta_object?(_metadata), do: false

  defp validate_optional_progress_token(metadata) do
    case Map.fetch(metadata, "progressToken") do
      {:ok, token} when is_binary(token) or is_integer(token) ->
        :ok

      {:ok, _invalid} ->
        {:error, Error.invalid_params("progressToken must be a string or integer")}

      :error ->
        :ok
    end
  end

  defp validate_optional_log_level(metadata) do
    case Map.fetch(metadata, @log_level_key) do
      {:ok, level} when level in @logging_levels -> :ok
      {:ok, _invalid} -> {:error, Error.invalid_params("Invalid MCP request log level")}
      :error -> :ok
    end
  end

  defp validate_implementation(info) do
    with :ok <- validate_string_keyed_json_object(info, "Client info"),
         :ok <- validate_optional_string(info, "title", "Client info title"),
         :ok <- validate_optional_string(info, "description", "Client info description"),
         :ok <- validate_optional_uri(info, "websiteUrl", "Client info websiteUrl"),
         :ok <- validate_optional_icons(info) do
      {:ok, info}
    end
  end

  defp validate_optional_icons(info) do
    case Map.fetch(info, "icons") do
      {:ok, icons} when is_list(icons) -> validate_icons(icons)
      {:ok, _invalid} -> {:error, Error.invalid_params("Client info icons must be a list")}
      :error -> :ok
    end
  end

  defp validate_icons(icons) do
    if Enum.all?(icons, &valid_icon?/1) do
      :ok
    else
      {:error, Error.invalid_params("Client info contains an invalid icon")}
    end
  end

  defp valid_icon?(%{"src" => src} = icon) when is_binary(src) do
    valid_uri?(src) and
      valid_optional_string?(icon, "mimeType") and
      valid_optional_string_list?(icon, "sizes") and
      valid_optional_enum?(icon, "theme", ["light", "dark"]) and
      json_object?(icon)
  end

  defp valid_icon?(_icon), do: false

  defp valid_optional_uri?(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} when is_binary(value) -> valid_uri?(value)
      {:ok, _invalid} -> false
      :error -> true
    end
  end

  defp validate_optional_uri(map, key, label) do
    if valid_optional_uri?(map, key),
      do: :ok,
      else: {:error, Error.invalid_params("#{label} must be a URI string")}
  end

  defp valid_uri?(value) do
    case URI.new(value) do
      {:ok, %URI{scheme: scheme}} when is_binary(scheme) and scheme != "" -> true
      _uri -> false
    end
  end

  defp validate_sampling_capability(capabilities) do
    with :ok <- validate_optional_object(capabilities, "sampling", "Client sampling capability") do
      validate_sampling_settings(Map.fetch(capabilities, "sampling"))
    end
  end

  defp validate_sampling_settings({:ok, sampling}) do
    with :ok <- validate_optional_object(sampling, "context", "Sampling context capability") do
      validate_optional_object(sampling, "tools", "Sampling tools capability")
    end
  end

  defp validate_sampling_settings(:error), do: :ok

  defp validate_elicitation_capability(capabilities) do
    with :ok <-
           validate_optional_object(capabilities, "elicitation", "Client elicitation capability") do
      validate_elicitation_settings(Map.fetch(capabilities, "elicitation"))
    end
  end

  defp validate_elicitation_settings({:ok, elicitation}) do
    with :ok <- validate_optional_object(elicitation, "form", "Elicitation form capability"),
         :ok <- validate_optional_object(elicitation, "url", "Elicitation URL capability") do
      if map_size(elicitation) == 0 or Map.has_key?(elicitation, "form") or
           Map.has_key?(elicitation, "url"),
         do: :ok,
         else: {:error, Error.invalid_params("Elicitation capability requires a supported mode")}
    end
  end

  defp validate_elicitation_settings(:error), do: :ok

  defp validate_optional_object(map, key, label) do
    case Map.fetch(map, key) do
      {:ok, value} when is_map(value) ->
        if json_object?(value),
          do: :ok,
          else: {:error, Error.invalid_params("#{label} must be an object")}

      {:ok, _invalid} ->
        {:error, Error.invalid_params("#{label} must be an object")}

      :error ->
        :ok
    end
  end

  defp validate_object_registry(map, key, require_prefix?) do
    case Map.fetch(map, key) do
      {:ok, registry} when is_map(registry) ->
        valid? =
          Enum.all?(registry, fn {name, settings} ->
            valid_name? =
              is_binary(name) and
                (not require_prefix? or
                   (Regex.match?(@meta_key, name) and String.contains?(name, "/")))

            valid_name? and json_object?(settings)
          end)

        if valid?,
          do: :ok,
          else:
            {:error,
             Error.invalid_params("Client #{key} entries must map valid names to objects")}

      {:ok, _invalid} ->
        {:error, Error.invalid_params("Client #{key} capability must be an object")}

      :error ->
        :ok
    end
  end

  defp validate_optional_string(map, key, label) do
    if valid_optional_string?(map, key),
      do: :ok,
      else: {:error, Error.invalid_params("#{label} must be a string")}
  end

  defp validate_string_keyed_json_object(map, label) do
    if json_object?(map),
      do: :ok,
      else:
        {:error, Error.invalid_params("#{label} must contain only string keys and JSON values")}
  end

  defp valid_optional_string?(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} -> is_binary(value)
      :error -> true
    end
  end

  defp valid_optional_string_list?(map, key) do
    case Map.fetch(map, key) do
      {:ok, values} when is_list(values) -> Enum.all?(values, &is_binary/1)
      {:ok, _invalid} -> false
      :error -> true
    end
  end

  defp valid_optional_enum?(map, key, allowed) do
    case Map.fetch(map, key) do
      {:ok, value} -> value in allowed
      :error -> true
    end
  end

  defp json_object?(value) when is_map(value) do
    Enum.all?(value, fn {key, nested} -> is_binary(key) and json_value?(nested) end)
  end

  defp json_object?(_value), do: false

  defp json_value?(value)
       when is_nil(value) or is_boolean(value) or is_binary(value) or is_number(value),
       do: true

  defp json_value?(value) when is_list(value), do: Enum.all?(value, &json_value?/1)
  defp json_value?(value) when is_map(value), do: json_object?(value)
  defp json_value?(_value), do: false

  defp negotiated_extensions(client_capabilities, server_capabilities) do
    client_extensions = Map.get(client_capabilities, "extensions", %{})
    server_extensions = Map.get(server_capabilities, "extensions", %{})

    intersect_extensions(client_extensions, server_extensions)
  end

  defp intersect_extensions(client_extensions, server_extensions)
       when is_map(client_extensions) and is_map(server_extensions) do
    Enum.reduce(server_extensions, %{}, fn {name, server_settings}, negotiated ->
      case Map.fetch(client_extensions, name) do
        {:ok, client_settings} ->
          Map.put(negotiated, name, %{client: client_settings, server: server_settings})

        :error ->
          negotiated
      end
    end)
  end

  defp intersect_extensions(_client_extensions, _server_extensions), do: %{}

  defp shape_tool_result(%Result{kind: :text, value: text}) do
    %{"content" => [%{"type" => "text", "text" => text}], "isError" => false}
  end

  defp shape_tool_result(%Result{kind: :structured, value: value}) do
    %{
      "content" => [%{"type" => "text", "text" => JSON.encode!(value)}],
      "structuredContent" => value,
      "isError" => false
    }
  end

  defp shape_tool_result(%Result{kind: :resource, value: value}) do
    %{"content" => List.wrap(value), "isError" => false}
  end

  defp shape_tool_result(%Result{kind: :error, value: message}) do
    %{"content" => [%{"type" => "text", "text" => message}], "isError" => true}
  end

  defp shape_tool_result(%Result{kind: :raw, value: value}) when is_map(value) do
    value
    |> Map.put_new("content", [])
    |> Map.put_new("isError", false)
  end

  defp shape_tool_definition(%Definition{} = definition) do
    %{
      "name" => definition.name,
      "description" => definition.description,
      "inputSchema" => definition.input_schema,
      "outputSchema" => definition.output_schema,
      "annotations" => definition.annotations
    }
    |> Enum.reduce(%{}, fn
      {_key, nil}, shaped -> shaped
      {"annotations", value}, shaped when value == %{} -> shaped
      {key, value}, shaped -> Map.put(shaped, key, value)
    end)
  end

  defp cache_ttl(%Result{metadata: %{ttl_ms: ttl_ms}})
       when is_integer(ttl_ms) and ttl_ms >= 0,
       do: ttl_ms

  defp cache_ttl(%Result{}), do: 0

  defp cache_scope(%Result{metadata: %{cache_scope: scope}})
       when scope in ["private", "public"],
       do: scope

  defp cache_scope(%Result{}), do: "private"

  defp complete_result(result), do: Map.put(result, "resultType", "complete")

  defp subscription_event_method(:tools_list_changed),
    do: "notifications/tools/list_changed"

  defp subscription_event_method(:prompts_list_changed),
    do: "notifications/prompts/list_changed"

  defp subscription_event_method(:resources_list_changed),
    do: "notifications/resources/list_changed"

  defp subscription_event_method(:resource_updated), do: "notifications/resources/updated"

  defp subscription_metadata(%SubscriptionEvent{} = event, id) do
    params_metadata =
      case Map.get(event.params, "_meta", %{}) do
        metadata when is_map(metadata) -> metadata
        _invalid -> %{}
      end

    params_metadata
    |> Map.merge(event.metadata)
    |> Map.put(@subscription_id_key, id)
  end

  defp maybe_put_resource_uri(params, %SubscriptionEvent{kind: :resource_updated, uri: uri}),
    do: Map.put(params, "uri", uri)

  defp maybe_put_resource_uri(params, %SubscriptionEvent{}), do: params

  defp stamp_response_metadata(result, %Result{} = handler_result, %Context{} = context) do
    wire_metadata =
      case Map.get(result, "_meta", %{}) do
        metadata when is_map(metadata) -> metadata
        _invalid -> %{}
      end

    handler_metadata =
      handler_result.metadata
      |> Enum.reject(fn {key, _value} -> is_atom(key) end)
      |> Map.new()

    response_metadata =
      wire_metadata
      |> Map.merge(handler_metadata)
      |> Map.put(@server_info_key, context.server_info)

    Map.put(result, "_meta", response_metadata)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
