defmodule Snodo.Extension.Registry do
  @moduledoc """
  Immutable registry for explicitly installed extension modules.

  Registration rejects collisions against the complete core catalog for an
  exact protocol revision, including unsupported and MRTR-only method names.
  Installation, advertisement, and peer negotiation are separate. Extension
  routes require negotiation; advertised compatible middleware can observe an
  unnegotiated request and enforce policy before core execution.
  """

  alias Snodo.Context
  alias Snodo.Envelope
  alias Snodo.Error
  alias Snodo.Extension.Method
  alias Snodo.Extension.Route
  alias Snodo.JSONValue
  alias Snodo.Protocol.Inspector
  alias Snodo.Protocol.Registry, as: ProtocolRegistry
  alias Snodo.Result
  alias Snodo.Subscription.Event, as: SubscriptionEvent
  alias Snodo.Subscription.Filter, as: SubscriptionFilter
  alias Snodo.Transport.Policy

  @required_callbacks [
    id: 0,
    methods: 0,
    negotiate: 2,
    validate_operation: 3,
    dispatch: 3,
    shape_result: 3,
    shape_error: 2
  ]

  @extension_id ~r/^(?:(?:[A-Za-z](?:[A-Za-z0-9-]*[A-Za-z0-9])?)(?:\.(?:[A-Za-z](?:[A-Za-z0-9-]*[A-Za-z0-9])?))*\/)(?:[A-Za-z0-9](?:[A-Za-z0-9._-]*[A-Za-z0-9])?)$/

  @type extension_options :: keyword() | map()
  @type entry :: module() | {module(), extension_options()}
  @type dispatch_result :: {:ok, Result.t()} | {:error, Error.t()}
  @type continuation :: (Context.t() -> dispatch_result())

  @type t :: %__MODULE__{
          by_id: %{optional(String.t()) => module()},
          routes: %{optional({String.t(), String.t()}) => Route.t()},
          versions_by_id: %{optional(String.t()) => MapSet.t(String.t())},
          options_by_id: %{optional(String.t()) => extension_options()},
          ordered_ids: [String.t()]
        }

  @enforce_keys [:by_id, :routes, :versions_by_id, :options_by_id, :ordered_ids]
  defstruct [:by_id, :routes, :versions_by_id, :options_by_id, :ordered_ids]

  @doc false
  @spec new([entry()], ProtocolRegistry.t()) :: t()
  def new(extensions, %ProtocolRegistry{} = protocol_registry) when is_list(extensions) do
    Enum.reduce(extensions, empty(), fn entry, registry ->
      register(registry, entry, protocol_registry)
    end)
  end

  @doc false
  @spec empty() :: t()
  def empty do
    %__MODULE__{
      by_id: %{},
      routes: %{},
      versions_by_id: %{},
      options_by_id: %{},
      ordered_ids: []
    }
  end

  @doc "Adds application-owned options for installed extensions compatible with the context."
  @spec put_options(t(), Context.t()) :: Context.t()
  def put_options(%__MODULE__{} = registry, %Context{} = context) do
    options =
      registry
      |> compatible_ids(context.protocol_version)
      |> Map.new(fn id -> {id, Map.fetch!(registry.options_by_id, id)} end)

    %{context | extension_options: options}
  end

  @doc false
  @spec validate_advertisement!(t(), map()) :: :ok
  def validate_advertisement!(%__MODULE__{} = registry, capabilities) when is_map(capabilities) do
    advertised = Map.get(capabilities, "extensions", %{})

    case Enum.find(Map.keys(advertised), &(not Map.has_key?(registry.by_id, &1))) do
      nil -> :ok
      id -> raise ArgumentError, "server advertises unregistered extension #{inspect(id)}"
    end
  end

  @doc false
  @spec negotiate(t(), Context.t()) :: {:ok, Context.t()} | {:error, Error.t()}
  def negotiate(%__MODULE__{} = registry, %Context{} = context) do
    Enum.reduce_while(context.extensions, {:ok, %{}}, fn
      {id, %{client: client, server: server}}, {:ok, negotiated} ->
        case negotiate_one(registry, id, context.protocol_version, client, server) do
          {:ok, settings} -> {:cont, {:ok, Map.put(negotiated, id, settings)}}
          :not_negotiated -> {:cont, {:ok, negotiated}}
          {:error, %Error{} = error} -> {:halt, {:error, error}}
        end

      {_id, _invalid_settings}, {:ok, _negotiated} ->
        {:halt, {:error, Error.invalid_params("Extension settings must be objects")}}
    end)
    |> case do
      {:ok, negotiated} -> {:ok, %{context | extensions: negotiated}}
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  @doc false
  @spec resolve(t(), String.t(), Envelope.t(), Context.t()) ::
          {:ok, Route.t()} | {:error, Error.t()}
  def resolve(
        %__MODULE__{} = registry,
        version,
        %Envelope{} = envelope,
        %Context{} = context
      ) do
    case fetch_route(registry, version, envelope.method) do
      {:ok, route} -> resolve_route(registry, route, envelope, context)
      :error -> {:error, Error.method_not_found(envelope.method)}
    end
  end

  @doc false
  @spec validate(t(), Route.t(), map(), Context.t()) :: :ok | {:error, Error.t()}
  def validate(%__MODULE__{}, %Route{} = route, params, %Context{} = context) do
    safe_callback(route.module, :validate_operation, [route.method.operation, params, context], fn
      :ok -> :ok
      {:error, %Error{} = error} -> {:error, error}
      other -> {:error, Error.internal("Extension validator returned an invalid result", other)}
    end)
  end

  @doc false
  @spec dispatch(t(), Route.t(), map(), Context.t()) ::
          {:ok, Result.t()} | {:error, Error.t()}
  def dispatch(%__MODULE__{}, %Route{} = route, params, %Context{} = context) do
    safe_callback(route.module, :dispatch, [route.method.operation, params, context], fn
      {:ok, %Result{} = result} -> {:ok, result}
      {:error, %Error{} = error} -> {:error, error}
      other -> {:error, Error.internal("Extension dispatcher returned an invalid result", other)}
    end)
  end

  @doc "Wraps core dispatch in advertised, compatible extension middleware."
  @spec around_dispatch(
          t(),
          String.t(),
          term(),
          map(),
          Context.t(),
          continuation()
        ) :: dispatch_result()
  def around_dispatch(
        %__MODULE__{} = registry,
        version,
        operation,
        params,
        %Context{} = context,
        next
      )
      when is_binary(version) and is_map(params) and is_function(next, 1) do
    middleware = middleware_modules(registry, version, context.server_capabilities)

    continuation =
      middleware
      |> Enum.reverse()
      |> Enum.reduce(next, fn module, continuation ->
        fn %Context{} = middleware_context ->
          safe_callback(
            module,
            :around_dispatch,
            [operation, params, middleware_context, continuation],
            &normalize_dispatch_result/1
          )
        end
      end)

    continuation.(context)
  end

  @doc "Applies an advertised extension route's exact-versioned transport policy hook."
  @spec transport_policy(t(), String.t(), Envelope.t(), map(), Policy.t()) ::
          {:ok, Policy.t()} | {:error, Error.t()}
  def transport_policy(
        %__MODULE__{} = registry,
        version,
        %Envelope{} = envelope,
        server_capabilities,
        %Policy{} = base_policy
      )
      when is_binary(version) and is_map(server_capabilities) do
    case fetch_route(registry, version, envelope.method) do
      {:ok, %Route{} = route} ->
        apply_transport_policy(route, envelope, server_capabilities, base_policy)

      :error ->
        {:ok, base_policy}
    end
  end

  @doc "Collects validated, collision-free subscription filter fields from advertised extensions."
  @spec subscription_filters(t(), String.t(), map(), Context.t()) ::
          {:ok, map(), %{optional(String.t()) => map()}} | {:error, Error.t()}
  def subscription_filters(
        %__MODULE__{} = registry,
        version,
        requested_filter,
        %Context{} = context
      )
      when is_binary(version) and is_map(requested_filter) do
    registry
    |> subscription_modules(version, context.server_capabilities, :subscription_filter, 2)
    |> Enum.reduce_while({:ok, %{}, %{}}, fn {id, module}, {:ok, merged, by_id} ->
      collect_subscription_filter(
        id,
        module,
        requested_filter,
        context,
        merged,
        by_id
      )
    end)
  end

  @doc "Shapes a protocol-neutral event through its negotiated owning extension."
  @spec shape_subscription_event(
          t(),
          SubscriptionEvent.t(),
          Snodo.Envelope.id(),
          Context.t()
        ) :: {:ok, map()} | :drop | {:error, Error.t()}
  def shape_subscription_event(
        %__MODULE__{} = registry,
        %SubscriptionEvent{kind: :extension, extension_id: id} = event,
        subscription_id,
        %Context{} = context
      ) do
    with true <- is_binary(id),
         true <- Map.has_key?(context.extensions, id),
         true <- supports?(registry, id, context.protocol_version),
         {:ok, module} <- Map.fetch(registry.by_id, id),
         true <- function_exported?(module, :shape_subscription_event, 3) do
      safe_callback(
        module,
        :shape_subscription_event,
        [event, subscription_id, context],
        &normalize_subscription_event/1
      )
    else
      _not_available_or_negotiated -> :drop
    end
  end

  @doc false
  @spec shape_result(t(), Route.t(), Result.t(), Context.t()) ::
          {:ok, map()} | {:error, Error.t()}
  def shape_result(%__MODULE__{}, %Route{} = route, %Result{} = result, %Context{} = context) do
    safe_callback(route.module, :shape_result, [route.method.operation, result, context], fn
      shaped when is_map(shaped) ->
        if JSONValue.valid?(shaped),
          do: {:ok, shaped},
          else: {:error, Error.internal("Extension shaped a non-JSON result")}

      other ->
        {:error, Error.internal("Extension shaped an invalid result", other)}
    end)
  end

  @doc false
  @spec shape_error(t(), Route.t(), Error.t(), Context.t()) ::
          {:ok, map()} | {:error, Error.t()}
  def shape_error(%__MODULE__{}, %Route{} = route, %Error{} = error, %Context{} = context) do
    safe_callback(route.module, :shape_error, [error, context], fn
      %{"code" => code, "message" => message} = shaped
      when is_integer(code) and is_binary(message) ->
        if JSONValue.valid?(shaped),
          do: {:ok, shaped},
          else: {:error, Error.internal("Extension shaped a non-JSON error")}

      other ->
        {:error, Error.internal("Extension shaped an invalid error", other)}
    end)
  end

  @doc false
  @spec project_capabilities(t(), String.t(), map()) :: map()
  def project_capabilities(%__MODULE__{} = registry, version, capabilities)
      when is_binary(version) and is_map(capabilities) do
    case Map.fetch(capabilities, "extensions") do
      {:ok, advertised} ->
        enabled =
          Map.new(advertised, fn {id, settings} -> {id, settings} end)
          |> Map.take(compatible_ids(registry, version))

        Map.put(capabilities, "extensions", enabled)

      :error ->
        capabilities
    end
  end

  @doc false
  @spec installed_ids(t()) :: [String.t()]
  def installed_ids(%__MODULE__{} = registry), do: registry.by_id |> Map.keys() |> Enum.sort()

  defp register(%__MODULE__{} = registry, entry, protocol_registry) do
    {extension, options} = normalize_entry!(entry)
    validate_module!(extension)
    id = extension.id()
    validate_id!(id)

    if Map.has_key?(registry.by_id, id) do
      raise ArgumentError, "duplicate extension id #{inspect(id)}"
    end

    methods = extension.methods()

    unless is_list(methods) and methods != [] and Enum.all?(methods, &match?(%Method{}, &1)) do
      raise ArgumentError,
            "extension #{inspect(id)} must declare at least one Snodo.Extension.Method"
    end

    registry = %{
      registry
      | by_id: Map.put(registry.by_id, id, extension),
        options_by_id: Map.put(registry.options_by_id, id, options),
        ordered_ids: registry.ordered_ids ++ [id]
    }

    Enum.reduce(methods, registry, fn method, acc ->
      register_method(acc, id, extension, method, protocol_registry)
    end)
  end

  defp register_method(registry, id, extension, %Method{} = method, protocol_registry) do
    method = Method.validate!(method)
    profile = fetch_profile!(protocol_registry, method.protocol_version)

    if Enum.any?(profile.methods, &(&1.name == method.name)) do
      raise ArgumentError,
            "extension method #{inspect(method.name)} collides with the #{method.protocol_version} core catalog"
    end

    key = {method.protocol_version, method.name}

    if Map.has_key?(registry.routes, key) do
      raise ArgumentError,
            "extension method #{inspect(method.name)} is already registered for #{method.protocol_version}"
    end

    route = %Route{extension_id: id, module: extension, method: method}

    versions =
      Map.update(
        registry.versions_by_id,
        id,
        MapSet.new([method.protocol_version]),
        fn existing ->
          MapSet.put(existing, method.protocol_version)
        end
      )

    %{registry | routes: Map.put(registry.routes, key, route), versions_by_id: versions}
  end

  defp fetch_profile!(protocol_registry, version) do
    case ProtocolRegistry.fetch(protocol_registry, version) do
      {:ok, protocol} -> protocol.profile()
      {:error, _error} -> raise ArgumentError, "extension targets unavailable protocol #{version}"
    end
  end

  defp fetch_route(registry, version, method) do
    Map.fetch(registry.routes, {version, method})
  end

  defp resolve_route(registry, route, envelope, context) do
    if Map.has_key?(context.extensions, route.extension_id) do
      case Inspector.inspect_method(route.method.rule, envelope, :client_to_server) do
        :ok -> {:ok, route}
        {:error, %Error{} = error} -> {:error, error}
      end
    else
      missing_capability_error(registry, route, envelope.method, context)
    end
  end

  defp missing_capability_error(registry, route, method, context) do
    module = Map.fetch!(registry.by_id, route.extension_id)

    if advertised?(context.server_capabilities, route.extension_id) and
         not advertised?(context.client_capabilities, route.extension_id) and
         function_exported?(module, :missing_capability_error, 2) do
      safe_callback(module, :missing_capability_error, [method, context], fn
        %Error{} = error ->
          {:error, error}

        :method_not_found ->
          {:error, Error.method_not_found(method)}

        other ->
          {:error,
           Error.internal("Extension missing_capability_error returned an invalid result", other)}
      end)
    else
      {:error, Error.method_not_found(method)}
    end
  end

  defp negotiate_one(registry, id, version, client, server)
       when is_map(client) and is_map(server) do
    with true <- supports?(registry, id, version),
         {:ok, module} <- Map.fetch(registry.by_id, id) do
      safe_callback(module, :negotiate, [client, server], fn
        {:ok, settings} when is_map(settings) ->
          {:ok, settings}

        :not_negotiated ->
          :not_negotiated

        {:error, %Error{} = error} ->
          {:error, error}

        other ->
          {:error, Error.internal("Extension negotiation returned an invalid result", other)}
      end)
    else
      _unavailable -> :not_negotiated
    end
  end

  defp negotiate_one(_registry, _id, _version, _client, _server) do
    {:error, Error.invalid_params("Extension settings must be objects")}
  end

  defp compatible_ids(registry, version) do
    Enum.filter(registry.ordered_ids, &supports?(registry, &1, version))
  end

  defp middleware_modules(registry, version, server_capabilities) do
    advertised = Map.get(server_capabilities, "extensions", %{})

    registry
    |> compatible_ids(version)
    |> Enum.filter(&Map.has_key?(advertised, &1))
    |> Enum.map(&Map.fetch!(registry.by_id, &1))
    |> Enum.filter(&function_exported?(&1, :around_dispatch, 4))
  end

  defp subscription_modules(registry, version, server_capabilities, callback, arity) do
    advertised = Map.get(server_capabilities, "extensions", %{})

    registry
    |> compatible_ids(version)
    |> Enum.filter(&Map.has_key?(advertised, &1))
    |> Enum.map(&{&1, Map.fetch!(registry.by_id, &1)})
    |> Enum.filter(fn {_id, module} -> function_exported?(module, callback, arity) end)
  end

  defp subscription_filter(module, requested_filter, context) do
    safe_callback(module, :subscription_filter, [requested_filter, context], fn
      {:ok, contribution} when is_map(contribution) ->
        cond do
          not SubscriptionFilter.valid?(contribution) ->
            {:error, Error.internal("Extension returned a non-JSON subscription filter")}

          not SubscriptionFilter.subset?(contribution, requested_filter) ->
            {:error, Error.internal("Extension accepted subscription filters not requested")}

          true ->
            {:ok, contribution}
        end

      {:error, %Error{} = error} ->
        {:error, error}

      other ->
        {:error, Error.internal("Extension returned an invalid subscription filter", other)}
    end)
  end

  defp collect_subscription_filter(id, module, requested, context, merged, by_id) do
    with {:ok, contribution} <- subscription_filter(module, requested, context),
         {:ok, next} <- merge_subscription_contribution(merged, contribution, id) do
      {:cont, {:ok, next, Map.put(by_id, id, contribution)}}
    else
      {:error, %Error{} = error} -> {:halt, {:error, error}}
    end
  end

  defp merge_subscription_contribution(merged, contribution, id) do
    case SubscriptionFilter.merge(merged, contribution) do
      {:ok, next} ->
        {:ok, next}

      {:error, collisions} ->
        {:error,
         Error.internal(
           "Extension subscription filters collide",
           %{extension: id, keys: collisions}
         )}
    end
  end

  defp normalize_subscription_event(shaped) when is_map(shaped) do
    if JSONValue.valid?(shaped),
      do: {:ok, shaped},
      else: {:error, Error.internal("Extension shaped a non-JSON subscription event")}
  end

  defp normalize_subscription_event(other) do
    {:error, Error.internal("Extension shaped an invalid subscription event", other)}
  end

  defp apply_transport_policy(route, envelope, server_capabilities, base_policy) do
    if advertised?(server_capabilities, route.extension_id) and
         function_exported?(route.module, :transport_policy, 2) do
      safe_callback(route.module, :transport_policy, [envelope, base_policy], fn
        %Policy{} = policy ->
          {:ok, policy}

        other ->
          {:error, Error.internal("Extension transport_policy returned an invalid result", other)}
      end)
    else
      {:ok, base_policy}
    end
  end

  defp advertised?(capabilities, id) do
    case Map.get(capabilities, "extensions", %{}) do
      extensions when is_map(extensions) -> Map.has_key?(extensions, id)
      _invalid -> false
    end
  end

  defp supports?(registry, id, version) do
    case Map.fetch(registry.versions_by_id, id) do
      {:ok, versions} -> MapSet.member?(versions, version)
      :error -> false
    end
  end

  defp normalize_entry!(extension) when is_atom(extension), do: {extension, []}

  defp normalize_entry!({extension, options}) when is_atom(extension) and is_map(options),
    do: {extension, options}

  defp normalize_entry!({extension, options}) when is_atom(extension) and is_list(options) do
    if Keyword.keyword?(options) do
      {extension, options}
    else
      raise ArgumentError, "extension options must be a keyword list or map"
    end
  end

  defp normalize_entry!({_extension, _options}) do
    raise ArgumentError, "extension entries must be modules or {module, keyword/map options}"
  end

  defp normalize_entry!(_entry) do
    raise ArgumentError, "extension entries must be modules or {module, keyword/map options}"
  end

  defp validate_module!(module) when is_atom(module) do
    case Code.ensure_loaded(module) do
      {:module, ^module} ->
        :ok

      _not_loaded ->
        raise ArgumentError, "extension module #{inspect(module)} could not be loaded"
    end

    Enum.each(@required_callbacks, fn {function, arity} ->
      unless function_exported?(module, function, arity) do
        raise ArgumentError,
              "extension module #{inspect(module)} does not export #{function}/#{arity}"
      end
    end)

    filter? = function_exported?(module, :subscription_filter, 2)
    shaper? = function_exported?(module, :shape_subscription_event, 3)

    if filter? != shaper? do
      raise ArgumentError,
            "extension module #{inspect(module)} must export both subscription_filter/2 and shape_subscription_event/3"
    end
  end

  defp validate_id!(id) do
    unless is_binary(id) and Regex.match?(@extension_id, id) do
      raise ArgumentError, "extension id must be a namespaced MCP capability key"
    end
  end

  defp normalize_dispatch_result({:ok, %Result{}} = result), do: result
  defp normalize_dispatch_result({:error, %Error{}} = result), do: result

  defp normalize_dispatch_result(other) do
    {:error, Error.internal("Extension around_dispatch returned an invalid result", other)}
  end

  defp safe_callback(module, function, args, normalize) do
    module
    |> apply(function, args)
    |> normalize.()
  rescue
    exception ->
      {:error, Error.internal("Extension callback raised", {exception, __STACKTRACE__})}
  catch
    kind, reason ->
      {:error, Error.internal("Extension callback terminated", {kind, reason, __STACKTRACE__})}
  end
end
