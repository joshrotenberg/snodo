defmodule MCP.Server do
  @moduledoc "Dialect-driven direct dispatch and a declarative server builder."

  alias MCP.Envelope
  alias MCP.Error
  alias MCP.Extension.Registry, as: ExtensionRegistry
  alias MCP.Extension.Route, as: ExtensionRoute
  alias MCP.Instrumentation
  alias MCP.JSONValue
  alias MCP.Pagination
  alias MCP.Protocol.Inspection
  alias MCP.Protocol.Inspector
  alias MCP.Protocol.Registry
  alias MCP.Result
  alias MCP.Router
  alias MCP.Server.Runtime
  alias MCP.Subscription
  alias MCP.Transport.Context, as: TransportContext

  @type dispatch_result :: {:ok, map() | nil} | {:stream, Subscription.t()}

  defmacro __using__(opts) do
    name = Keyword.fetch!(opts, :name)
    version = Keyword.fetch!(opts, :version)

    validate_identity_option!(name, :name)
    validate_identity_option!(version, :version)

    protocols =
      opts
      |> Keyword.get(:protocols, [MCP.Protocol.V2026_07_28])
      |> Enum.map(&Macro.expand(&1, __CALLER__))

    quote do
      import MCP.Server, only: [prompt: 1, resource: 1, tool: 1]

      Module.register_attribute(__MODULE__, :mcp_server_tools, accumulate: true)
      Module.register_attribute(__MODULE__, :mcp_server_prompts, accumulate: true)
      Module.register_attribute(__MODULE__, :mcp_server_resources, accumulate: true)
      Module.register_attribute(__MODULE__, :mcp_server_options, persist: true)

      @mcp_server_options %{
        name: unquote(name),
        version: unquote(version),
        protocols: unquote(protocols),
        extensions: unquote(Keyword.get(opts, :extensions, [])),
        capabilities: unquote(Keyword.get(opts, :capabilities)),
        instructions: unquote(Keyword.get(opts, :instructions)),
        discovery_cache: unquote(Keyword.get(opts, :discovery_cache, [])),
        tools_cache: unquote(Keyword.get(opts, :tools_cache, [])),
        prompts_cache: unquote(Keyword.get(opts, :prompts_cache, [])),
        resources_cache: unquote(Keyword.get(opts, :resources_cache, [])),
        pagination: unquote(Keyword.get(opts, :pagination, [])),
        schema_validator:
          unquote(Keyword.get(opts, :schema_validator, MCP.Schema.Validator.Passthrough)),
        subscription_source: unquote(Keyword.get(opts, :subscription_source)),
        instrumentation: unquote(Keyword.get(opts, :instrumentation)),
        authorization: unquote(Keyword.get(opts, :authorization))
      }

      @before_compile MCP.Server
    end
  end

  defp validate_identity_option!(value, _field) when is_binary(value), do: :ok

  defp validate_identity_option!({:@, _, [{attribute, _, _}]}, _field) when is_atom(attribute),
    do: :ok

  defp validate_identity_option!(_value, field) do
    raise ArgumentError,
          "MCP.Server expects #{inspect(field)} to be a string literal or module attribute"
  end

  defmacro tool(module_ast) do
    module = Macro.expand(module_ast, __CALLER__)

    quote do
      @mcp_server_tools unquote(module)
    end
  end

  defmacro resource(module_ast) do
    module = Macro.expand(module_ast, __CALLER__)

    quote do
      @mcp_server_resources unquote(module)
    end
  end

  defmacro prompt(module_ast) do
    module = Macro.expand(module_ast, __CALLER__)

    quote do
      @mcp_server_prompts unquote(module)
    end
  end

  defmacro __before_compile__(env) do
    tools = env.module |> Module.get_attribute(:mcp_server_tools) |> Enum.reverse()
    prompts = env.module |> Module.get_attribute(:mcp_server_prompts) |> Enum.reverse()
    resources = env.module |> Module.get_attribute(:mcp_server_resources) |> Enum.reverse()
    options = Module.get_attribute(env.module, :mcp_server_options)

    optional_runtime =
      []
      |> then(fn runtime ->
        if is_nil(options.subscription_source),
          do: runtime,
          else: Keyword.put(runtime, :subscription_source, options.subscription_source)
      end)
      |> then(fn runtime ->
        if is_nil(options.capabilities),
          do: runtime,
          else: Keyword.put(runtime, :capabilities, options.capabilities)
      end)

    quote do
      @doc "Builds a fresh immutable router from the declarative component list."
      def router do
        router =
          Enum.reduce(unquote(Macro.escape(tools)), MCP.Router.new(), fn tool, router ->
            MCP.Router.register_tool(router, tool)
          end)

        router =
          Enum.reduce(unquote(Macro.escape(prompts)), router, fn prompt, router ->
            MCP.Router.register_prompt(router, prompt)
          end)

        Enum.reduce(unquote(Macro.escape(resources)), router, fn resource, router ->
          MCP.Router.register_resource(router, resource)
        end)
      end

      @doc "Returns the explicitly configured protocol dialect modules."
      def protocols, do: unquote(Macro.escape(options.protocols))

      @doc "Builds immutable runtime data; it starts no process."
      def runtime(overrides \\ []) do
        base =
          [
            router: router(),
            protocols: protocols(),
            extensions: unquote(Macro.escape(options.extensions)),
            server_info: %{
              "name" => unquote(options.name),
              "version" => unquote(options.version)
            },
            instructions: unquote(Macro.escape(options.instructions)),
            discovery_cache: unquote(Macro.escape(options.discovery_cache)),
            tools_cache: unquote(Macro.escape(options.tools_cache)),
            prompts_cache: unquote(Macro.escape(options.prompts_cache)),
            resources_cache: unquote(Macro.escape(options.resources_cache)),
            pagination: unquote(Macro.escape(options.pagination)),
            schema_validator: unquote(options.schema_validator),
            instrumentation: unquote(Macro.escape(options.instrumentation)),
            authorization: unquote(Macro.escape(options.authorization))
          ] ++ unquote(Macro.escape(optional_runtime))

        base
        |> Keyword.merge(Keyword.drop(overrides, [:transports, :supervisor_name]))
        |> MCP.Server.Runtime.new()
      end

      def child_spec(opts) do
        %{
          id: __MODULE__,
          start:
            {MCP.Server.Supervisor, :start_link,
             [
               [
                 runtime: runtime(opts),
                 transports: Keyword.get(opts, :transports, []),
                 name: Keyword.get(opts, :supervisor_name)
               ]
             ]},
          type: :supervisor
        }
      end
    end
  end

  @doc false
  @spec resolve_notification(Runtime.t(), term(), TransportContext.t()) ::
          {:ok, term()} | :not_notification | {:error, Error.t()}
  def resolve_notification(%Runtime{} = runtime, raw, %TransportContext{} = transport) do
    with {:ok, %Envelope{kind: :notification} = envelope} <- Envelope.decode(raw, transport),
         {:ok, protocol} <- Registry.select(runtime.protocol_registry, envelope),
         {:ok, decoded} <- protocol.decode_request(raw, transport),
         {:ok, inspection} <-
           Inspector.inspect(protocol.profile(), decoded, :client_to_server),
         {:ok, context} <- protocol.build_context(decoded, runtime),
         :ok <- admit_profile_method(inspection),
         {:ok, operation} <- resolve_operation(protocol, decoded),
         :ok <- protocol.validate_operation(operation, decoded.params, context) do
      {:ok, operation}
    else
      {:ok, %Envelope{kind: :request}} -> :not_notification
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  @doc "Dispatches one decoded JSON-RPC map through the configured dialect and router."
  @spec dispatch(Runtime.t(), term(), TransportContext.t()) :: dispatch_result()
  def dispatch(%Runtime{} = runtime, raw, %TransportContext{} = transport) do
    Instrumentation.span(
      runtime.instrumentation,
      [:mcp_ex, :server, :dispatch],
      dispatch_metadata(raw, transport),
      fn -> dispatch_uninstrumented(runtime, raw, transport) end,
      &dispatch_finish_metadata/1
    )
  end

  defp dispatch_uninstrumented(runtime, raw, transport) do
    case Envelope.decode(raw, transport) do
      {:ok, envelope} -> dispatch_envelope(runtime, raw, envelope)
      {:error, %Error{} = error} -> {:ok, generic_error_response(error, readable_id(raw))}
    end
  rescue
    _exception -> {:ok, generic_error_response(Error.internal(), readable_id(raw))}
  end

  defp dispatch_metadata(raw, transport) do
    %{
      method: if(is_map(raw), do: Map.get(raw, "method"), else: nil),
      request_id: readable_id(raw),
      transport: transport.transport
    }
  end

  defp dispatch_finish_metadata({:stream, _subscription}), do: %{outcome: :stream}
  defp dispatch_finish_metadata({:ok, nil}), do: %{outcome: :no_reply}

  defp dispatch_finish_metadata({:ok, %{"error" => %{"code" => code}}}),
    do: %{outcome: :error, error_code: code}

  defp dispatch_finish_metadata({:ok, _response}), do: %{outcome: :ok}

  @doc "Shapes an execution-policy error through the selected protocol dialect."
  @spec reject(Runtime.t(), term(), TransportContext.t(), Error.t()) :: dispatch_result()
  def reject(
        %Runtime{} = runtime,
        raw,
        %TransportContext{} = transport,
        %Error{} = error
      ) do
    case Envelope.decode(raw, transport) do
      {:ok, envelope} -> shape_dispatch_error(runtime, envelope, error)
      {:error, _decode_error} -> {:ok, generic_error_response(error, readable_id(raw))}
    end
  rescue
    _exception -> {:ok, generic_error_response(Error.internal(), readable_id(raw))}
  end

  defp dispatch_envelope(runtime, raw, envelope) do
    with {:ok, protocol} <- Registry.select(runtime.protocol_registry, envelope),
         {:ok, decoded} <- protocol.decode_request(raw, envelope.transport),
         {:ok, inspection} <-
           Inspector.inspect(protocol.profile(), decoded, :client_to_server),
         {:ok, built_context} <- protocol.build_context(decoded, runtime),
         context = ExtensionRegistry.put_options(runtime.extension_registry, built_context),
         {:ok, context} <- ExtensionRegistry.negotiate(runtime.extension_registry, context) do
      dispatch_inspected(runtime, protocol, decoded, inspection, context)
    else
      {:error, %Error{} = error} ->
        shape_dispatch_error(runtime, envelope, error)
    end
  end

  defp dispatch_inspected(runtime, protocol, envelope, inspection, context) do
    case resolve_route(runtime, protocol, envelope, inspection, context) do
      {:ok, route} -> dispatch_route(runtime, protocol, envelope, route, context)
      {:error, %Error{} = error} -> shape_dispatch_error(runtime, envelope, error)
    end
  end

  defp dispatch_route(runtime, protocol, envelope, route, context) do
    with :ok <- validate_route(runtime, protocol, route, envelope.params, context),
         {:ok, result} <- execute_route(runtime, protocol, route, envelope.params, context),
         {:ok, shaped} <- shape_route_result(runtime, protocol, route, result, context) do
      case shaped do
        {:subscription, %Subscription{} = subscription} -> {:stream, subscription}
        result -> reply_or_no_reply(envelope, result)
      end
    else
      {:error, %Error{} = error} ->
        shape_route_error(runtime, protocol, envelope, route, context, error)
    end
  end

  defp resolve_route(
         _runtime,
         protocol,
         envelope,
         %Inspection{classification: :implemented},
         _context
       ) do
    with {:ok, operation} <- resolve_operation(protocol, envelope) do
      {:ok, {:protocol, operation}}
    end
  end

  defp resolve_route(
         _runtime,
         _protocol,
         envelope,
         %Inspection{classification: :unsupported},
         _context
       ) do
    {:error, Error.method_not_found(envelope.method)}
  end

  defp resolve_route(
         runtime,
         protocol,
         envelope,
         %Inspection{classification: :extension},
         context
       ) do
    with {:ok, %ExtensionRoute{} = route} <-
           ExtensionRegistry.resolve(
             runtime.extension_registry,
             protocol.version(),
             envelope,
             context
           ) do
      {:ok, {:extension, route}}
    end
  end

  defp resolve_operation(protocol, envelope) do
    case protocol.resolve_operation(envelope) do
      {:ok, operation} -> {:ok, operation}
      :not_handled -> {:error, Error.method_not_found(envelope.method)}
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  defp admit_profile_method(%Inspection{classification: :implemented}), do: :ok

  defp admit_profile_method(%Inspection{envelope: envelope}) do
    {:error, Error.method_not_found(envelope.method)}
  end

  defp validate_route(_runtime, protocol, {:protocol, operation}, params, context) do
    protocol.validate_operation(operation, params, context)
  end

  defp validate_route(runtime, _protocol, {:extension, route}, params, context) do
    ExtensionRegistry.validate(runtime.extension_registry, route, params, context)
  end

  defp execute_route(runtime, protocol, {:protocol, operation}, params, context) do
    ExtensionRegistry.around_dispatch(
      runtime.extension_registry,
      protocol.version(),
      operation,
      params,
      context,
      fn %MCP.Context{} = next_context ->
        execute(runtime, protocol, operation, params, next_context)
      end
    )
  end

  defp execute_route(runtime, _protocol, {:extension, route}, params, context) do
    ExtensionRegistry.dispatch(runtime.extension_registry, route, params, context)
  end

  defp shape_route_result(_runtime, protocol, {:protocol, operation}, result, context) do
    with :ok <- validate_protocol_result(protocol, operation, result, context) do
      shape_protocol_result(protocol, operation, result, context)
    end
  end

  defp shape_route_result(runtime, _protocol, {:extension, route}, result, context) do
    ExtensionRegistry.shape_result(runtime.extension_registry, route, result, context)
  end

  defp validate_protocol_result(protocol, operation, result, context) do
    if function_exported?(protocol, :validate_result, 3),
      do: protocol.validate_result(operation, result, context),
      else: :ok
  end

  defp shape_protocol_result(protocol, operation, result, context) do
    case result do
      %Result{kind: :subscription, value: %Subscription{} = subscription} ->
        {:ok, {:subscription, subscription}}

      %Result{} ->
        {:ok, protocol.shape_result(operation, result, context)}
    end
  end

  defp shape_route_error(runtime, _protocol, envelope, {:extension, route}, context, error) do
    case ExtensionRegistry.shape_error(runtime.extension_registry, route, error, context) do
      {:ok, shaped_error} -> {:ok, error_response(error, envelope.id, shaped_error)}
      {:error, %Error{} = shaping_error} -> shape_dispatch_error(runtime, envelope, shaping_error)
    end
  end

  defp shape_route_error(runtime, _protocol, envelope, {:protocol, _operation}, _context, error) do
    shape_dispatch_error(runtime, envelope, error)
  end

  defp execute(runtime, _protocol, :initialize, _params, context) do
    result = %{
      "protocolVersion" => context.protocol_version,
      "capabilities" => context.server_capabilities,
      "serverInfo" => context.server_info
    }

    result =
      if runtime.instructions,
        do: Map.put(result, "instructions", runtime.instructions),
        else: result

    {:ok, Result.raw(result)}
  end

  defp execute(_runtime, _protocol, operation, _params, _context)
       when operation in [:initialized, :ping],
       do: {:ok, Result.raw(%{})}

  defp execute(runtime, protocol, :server_discover, _params, _context) do
    case protocol.server_discovery(runtime) do
      :unsupported -> {:error, Error.method_not_found("server/discover")}
      discovery when is_map(discovery) -> {:ok, Result.raw(discovery)}
    end
  end

  defp execute(
         %Runtime{subscription_source: nil},
         _protocol,
         :subscriptions_listen,
         _params,
         _context
       ) do
    {:error, Error.method_not_found("subscriptions/listen")}
  end

  defp execute(
         %Runtime{subscription_source: source} = runtime,
         _protocol,
         :subscriptions_listen,
         %{"notifications" => requested_filter},
         context
       ) do
    with {:ok, %Subscription{} = subscription} <-
           Subscription.open(
             source,
             requested_filter,
             context,
             runtime.extension_registry
           ) do
      {:ok, Result.subscription(subscription)}
    end
  end

  defp execute(%Runtime{} = runtime, protocol, operation, params, context)
       when operation in [
              :tools_list,
              :prompts_list,
              :resources_list,
              :resource_templates_list
            ] do
    with {:ok, %Result{} = result} <-
           Router.dispatch(runtime.router, operation, params, context,
             schema_validator: runtime.schema_validator,
             authorization: runtime.authorization
           ),
         {:ok, %Result{} = result} <- apply_list_cache_policy(result, runtime, operation),
         {:ok, %Result{} = result} <-
           Pagination.page(result, protocol.version(), operation, params, runtime.pagination) do
      {:ok, result}
    end
  end

  defp execute(
         %Runtime{} = runtime,
         _protocol,
         {:resource_read, _uri} = operation,
         params,
         context
       ) do
    with {:ok, %Result{} = result} <-
           Router.dispatch(runtime.router, operation, params, context,
             schema_validator: runtime.schema_validator,
             authorization: runtime.authorization
           ) do
      apply_cache_policy(result, runtime.resources_cache, "Resource")
    end
  end

  defp execute(_runtime, _protocol, {:cancel, _request_id, _reason}, _params, _context) do
    {:ok, Result.raw(%{})}
  end

  defp execute(%Runtime{} = runtime, _protocol, operation, params, context) do
    Router.dispatch(runtime.router, operation, params, context,
      schema_validator: runtime.schema_validator,
      authorization: runtime.authorization
    )
  end

  defp apply_cache_policy(%Result{kind: :input_required} = result, _cache, _label),
    do: {:ok, result}

  defp apply_cache_policy(%Result{} = result, cache, label) do
    ttl_ms = Map.get(result.metadata, :ttl_ms, cache.ttl_ms)
    cache_scope = Map.get(result.metadata, :cache_scope, cache.scope)

    if is_integer(ttl_ms) and ttl_ms >= 0 and cache_scope in ["public", "private"] do
      metadata =
        result.metadata
        |> Map.put(:ttl_ms, ttl_ms)
        |> Map.put(:cache_scope, cache_scope)

      {:ok, %{result | metadata: metadata}}
    else
      {:error, Error.internal("#{label} returned invalid cache metadata")}
    end
  end

  defp apply_list_cache_policy(result, runtime, :tools_list),
    do: apply_cache_policy(result, runtime.tools_cache, "Tool")

  defp apply_list_cache_policy(result, runtime, :prompts_list),
    do: apply_cache_policy(result, runtime.prompts_cache, "Prompt")

  defp apply_list_cache_policy(result, runtime, operation)
       when operation in [:resources_list, :resource_templates_list],
       do: apply_cache_policy(result, runtime.resources_cache, "Resource")

  defp reply_or_no_reply(%Envelope{kind: :notification}, _result), do: {:ok, nil}

  defp reply_or_no_reply(%Envelope{id: id, kind: :request}, result) do
    response = %{"jsonrpc" => "2.0", "id" => id, "result" => result}

    if JSONValue.valid?(response) do
      {:ok, response}
    else
      {:ok, generic_error_response(Error.internal("Server produced an invalid result"), id)}
    end
  end

  defp shape_dispatch_error(runtime, %Envelope{} = envelope, %Error{} = error) do
    if envelope.kind == :notification do
      {:ok, nil}
    else
      case Registry.select(runtime.protocol_registry, envelope) do
        {:ok, protocol} ->
          context = minimal_error_context(protocol, envelope, runtime)
          {:ok, error_response(error, envelope.id, protocol.shape_error(error, context))}

        {:error, _selection_error} ->
          {:ok, generic_error_response(error, envelope.id)}
      end
    end
  end

  defp minimal_error_context(protocol, envelope, runtime) do
    case protocol.build_context(envelope, runtime) do
      {:ok, context} -> context
      {:error, _error} -> nil
    end
  end

  defp error_response(_error, id, shaped_error) do
    response = %{"jsonrpc" => "2.0", "id" => id, "error" => shaped_error}

    if JSONValue.valid?(response),
      do: response,
      else: generic_error_response(Error.internal(), id)
  end

  defp generic_error_response(error, nil) do
    %{"jsonrpc" => "2.0", "id" => nil, "error" => safe_json_rpc_error(error)}
  end

  defp generic_error_response(error, id) do
    %{"jsonrpc" => "2.0", "id" => id, "error" => safe_json_rpc_error(error)}
  end

  defp safe_json_rpc_error(error) do
    shaped = Error.to_json_rpc(error)

    if JSONValue.valid?(shaped),
      do: shaped,
      else: Error.to_json_rpc(Error.internal())
  end

  defp readable_id(raw) when is_map(raw) do
    case Map.get(raw, "id") do
      id when is_binary(id) or is_integer(id) -> id
      _invalid -> nil
    end
  end

  defp readable_id(_raw), do: nil
end
