defmodule Snodo.Subscription do
  @moduledoc """
  An opened, request-scoped MCP subscription.

  Applications implement `Snodo.Subscription.Source`; this module owns filter
  narrowing, lifecycle safety, bounded pulling, and protocol wire shaping.
  """

  alias Snodo.Context
  alias Snodo.Error
  alias Snodo.Extension.Registry, as: ExtensionRegistry
  alias Snodo.JSONValue
  alias Snodo.Subscription.Event
  alias Snodo.Subscription.Filter
  alias Snodo.Subscription.Source
  alias Snodo.Subscription.Source.Config

  @type id :: integer() | String.t()
  @type t :: %__MODULE__{
          id: id(),
          protocol: module(),
          context: Context.t(),
          source: Config.t(),
          handle: term(),
          accepted_filter: map(),
          extension_registry: ExtensionRegistry.t(),
          extension_filters: %{optional(String.t()) => map()}
        }

  @enforce_keys [
    :id,
    :protocol,
    :context,
    :source,
    :handle,
    :accepted_filter,
    :extension_registry,
    :extension_filters
  ]
  defstruct [
    :id,
    :protocol,
    :context,
    :source,
    :handle,
    :accepted_filter,
    :extension_registry,
    :extension_filters
  ]

  @doc """
  Starts a monitored, demand-driven source worker owned by the caller.

  After each `continue/1`, the owner receives
  `{:mcp_subscription, worker, outcome}` where the outcome is `{:ok, event}`,
  `:closed`, or `{:error, reason}`.
  """
  @spec open(Config.t(), map(), Context.t()) :: {:ok, t()} | {:error, Error.t()}
  def open(%Config{} = source, requested_filter, %Context{} = context)
      when is_map(requested_filter) do
    open(source, requested_filter, context, ExtensionRegistry.empty())
  end

  @doc false
  @spec open(Config.t(), map(), Context.t(), ExtensionRegistry.t()) ::
          {:ok, t()} | {:error, Error.t()}
  def open(
        %Config{} = source,
        requested_filter,
        %Context{} = context,
        %ExtensionRegistry{} = extension_registry
      )
      when is_map(requested_filter) do
    core_filter = supported_filter(requested_filter, context.server_capabilities)

    with {:ok, extension_filter, extension_filters} <-
           ExtensionRegistry.subscription_filters(
             extension_registry,
             context.protocol_version,
             requested_filter,
             context
           ),
         {:ok, supported_filter} <- merge_supported_filters(core_filter, extension_filter),
         {:ok, accepted_filter, handle} <- source_open(source, supported_filter, context) do
      case validate_accepted_filter(accepted_filter, supported_filter) do
        :ok ->
          {:ok,
           %__MODULE__{
             id: context.request_id,
             protocol: context.protocol,
             context: context,
             source: source,
             handle: handle,
             accepted_filter: accepted_filter,
             extension_registry: extension_registry,
             extension_filters: project_extension_filters(accepted_filter, extension_filters)
           }}

        {:error, %Error{} = error} ->
          :ok = safe_close(source, handle, {:error, error})
          {:error, error}
      end
    else
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  @doc "Returns the first required acknowledgement notification."
  @spec acknowledgement(t()) :: {:ok, map()} | {:error, Error.t()}
  def acknowledgement(%__MODULE__{} = subscription) do
    shape(subscription, :shape_subscription_ack, [subscription.accepted_filter])
  end

  @doc "Shapes one requested source event or drops an event outside the accepted filter."
  @spec notification(t(), Event.t()) :: {:ok, map()} | :drop | {:error, Error.t()}
  def notification(%__MODULE__{} = subscription, %Event{kind: :extension} = event) do
    with :ok <- event_error(Event.validate(event)),
         {:ok, owned_filter} <- Map.fetch(subscription.extension_filters, event.extension_id),
         true <- Filter.subset?(event.selector, owned_filter) do
      ExtensionRegistry.shape_subscription_event(
        subscription.extension_registry,
        event,
        subscription.id,
        subscription.context
      )
    else
      :error -> :drop
      false -> :drop
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  def notification(%__MODULE__{} = subscription, %Event{} = event) do
    with :ok <- event_error(Event.validate(event)),
         true <- requested?(subscription.accepted_filter, event) do
      shape(subscription, :shape_subscription_event, [event])
    else
      false -> :drop
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  def notification(%__MODULE__{}, _invalid) do
    {:error, Error.internal("Subscription source returned an invalid event")}
  end

  @doc "Returns the final successful JSON-RPC response for graceful completion."
  @spec completion(t()) :: {:ok, map()} | {:error, Error.t()}
  def completion(%__MODULE__{} = subscription) do
    shape(subscription, :shape_subscription_result, [])
  end

  @doc "Returns a terminal JSON-RPC error response for a failed open stream."
  @spec failure(t(), term()) :: map()
  def failure(%__MODULE__{id: id}, reason) do
    %{
      "jsonrpc" => "2.0",
      "id" => id,
      "error" => Error.to_json_rpc(Error.internal("Subscription source failed", reason))
    }
  end

  @doc "Allows a subscription worker to pull exactly one more source outcome."
  @spec start_worker(t(), pid()) :: {pid(), reference()}
  def start_worker(%__MODULE__{} = subscription, owner) when is_pid(owner) do
    spawn_monitor(fn -> worker_loop(subscription, owner) end)
  end

  @doc false
  @spec continue(pid()) :: :ok
  def continue(worker) when is_pid(worker) do
    send(worker, :mcp_subscription_continue)
    :ok
  end

  @doc "Stops a worker and removes its process monitor."
  @spec stop_worker(pid(), reference()) :: :ok
  def stop_worker(worker, monitor) when is_pid(worker) and is_reference(monitor) do
    Process.demonitor(monitor, [:flush])
    if Process.alive?(worker), do: Process.exit(worker, :shutdown)
    :ok
  end

  @doc "Closes the application-owned source handle with an explicit reason."
  @spec close(t(), Source.close_reason()) :: :ok
  def close(%__MODULE__{source: source, handle: handle}, reason) do
    safe_close(source, handle, reason)
  end

  defp worker_loop(subscription, owner) do
    receive do
      :mcp_subscription_continue ->
        send(owner, {:mcp_subscription, self(), source_next(subscription)})
        worker_loop(subscription, owner)
    end
  end

  defp source_open(%Config{module: module, options: options}, filter, context) do
    case module.open(filter, context, options) do
      {:ok, accepted, handle} when is_map(accepted) ->
        {:ok, accepted, handle}

      {:error, %Error{} = error} ->
        {:error, error}

      {:error, reason} ->
        {:error, Error.internal("Subscription source failed to open", reason)}

      invalid ->
        {:error, Error.internal("Subscription source returned an invalid open result", invalid)}
    end
  rescue
    exception -> {:error, Error.internal("Subscription source failed to open", exception)}
  catch
    kind, reason -> {:error, Error.internal("Subscription source failed to open", {kind, reason})}
  end

  defp source_next(%__MODULE__{
         source: %Config{module: module, options: options},
         handle: handle
       }) do
    case module.next(handle, options) do
      {:ok, %Event{} = event} -> {:ok, event}
      :closed -> :closed
      {:error, reason} -> {:error, reason}
      invalid -> {:error, {:invalid_next_result, invalid}}
    end
  rescue
    exception -> {:error, exception}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp safe_close(%Config{module: module, options: options}, handle, reason) do
    _ignored = module.close(handle, reason, options)
    :ok
  rescue
    _exception -> :ok
  catch
    _kind, _reason -> :ok
  end

  defp supported_filter(requested, capabilities) do
    %{}
    |> maybe_accept_boolean(
      requested,
      "toolsListChanged",
      get_in(capabilities, ["tools", "listChanged"]) == true
    )
    |> maybe_accept_boolean(
      requested,
      "promptsListChanged",
      get_in(capabilities, ["prompts", "listChanged"]) == true
    )
    |> maybe_accept_boolean(
      requested,
      "resourcesListChanged",
      get_in(capabilities, ["resources", "listChanged"]) == true
    )
    |> maybe_accept_resources(requested, capabilities)
  end

  defp maybe_accept_boolean(filter, requested, key, true) do
    if Map.get(requested, key) == true, do: Map.put(filter, key, true), else: filter
  end

  defp maybe_accept_boolean(filter, _requested, _key, false), do: filter

  defp maybe_accept_resources(filter, requested, capabilities) do
    if get_in(capabilities, ["resources", "subscribe"]) == true do
      case Map.get(requested, "resourceSubscriptions") do
        resources when is_list(resources) -> Map.put(filter, "resourceSubscriptions", resources)
        _missing -> filter
      end
    else
      filter
    end
  end

  defp validate_accepted_filter(accepted, supported) do
    if Filter.subset?(accepted, supported),
      do: :ok,
      else: {:error, Error.internal("Subscription source accepted notifications not requested")}
  end

  defp requested?(filter, %Event{kind: :tools_list_changed}),
    do: Map.get(filter, "toolsListChanged") == true

  defp requested?(filter, %Event{kind: :prompts_list_changed}),
    do: Map.get(filter, "promptsListChanged") == true

  defp requested?(filter, %Event{kind: :resources_list_changed}),
    do: Map.get(filter, "resourcesListChanged") == true

  defp requested?(filter, %Event{kind: :resource_updated, uri: uri}) do
    uri in Map.get(filter, "resourceSubscriptions", [])
  end

  defp requested?(_filter, %Event{}), do: false

  defp merge_supported_filters(core_filter, extension_filter) do
    case Filter.merge(core_filter, extension_filter) do
      {:ok, merged} ->
        {:ok, merged}

      {:error, collisions} ->
        {:error,
         Error.internal("Extension subscription filters collide with core", %{keys: collisions})}
    end
  end

  defp project_extension_filters(accepted_filter, extension_filters) do
    extension_filters
    |> Enum.map(fn {id, contribution} ->
      {id, Filter.project(accepted_filter, contribution)}
    end)
    |> Enum.reject(fn {_id, contribution} -> map_size(contribution) == 0 end)
    |> Map.new()
  end

  defp shape(%__MODULE__{protocol: protocol, context: context} = subscription, callback, args) do
    if function_exported?(protocol, callback, length(args) + 2) do
      value = apply(protocol, callback, args ++ [subscription.id, context])

      if is_map(value) and JSONValue.valid?(value),
        do: {:ok, value},
        else: {:error, Error.internal("Protocol produced an invalid subscription message")}
    else
      {:error, Error.internal("Protocol does not implement subscription wire shaping")}
    end
  rescue
    exception ->
      {:error, Error.internal("Protocol failed to shape a subscription message", exception)}
  end

  defp event_error(:ok), do: :ok
  defp event_error({:error, message}), do: {:error, Error.internal(message)}
end
