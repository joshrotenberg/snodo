defmodule Snodo.Proxy.Extension do
  @moduledoc false

  @behaviour Snodo.Extension

  alias Snodo.Authorization
  alias Snodo.Authorization.Component
  alias Snodo.Client
  alias Snodo.Context
  alias Snodo.Error
  alias Snodo.Extension.Method
  alias Snodo.Progress
  alias Snodo.Proxy.Catalog
  alias Snodo.Proxy.Manager
  alias Snodo.Result

  @id "dev.snodo/proxy"

  @impl true
  def id, do: @id

  @impl true
  def methods do
    [
      Method.new!(
        protocol_version: "2026-07-28",
        name: "proxy/health",
        operation: :proxy_health,
        params: :optional
      )
    ]
  end

  @impl true
  def negotiate(_client, _server), do: {:ok, %{}}

  @impl true
  def validate_operation(:proxy_health, _params, _context), do: :ok

  @impl true
  def dispatch(:proxy_health, _params, context) do
    healthy? =
      context
      |> manager!()
      |> Manager.health()
      |> Enum.all?(fn {_id, %{status: status}} -> status == :up end)

    status = if healthy?, do: "up", else: "degraded"
    {:ok, Result.wire(%{"status" => status})}
  end

  @impl true
  def shape_result(:proxy_health, %Result{value: value}, _context), do: value

  @impl true
  def shape_error(%Error{} = error, _context) do
    %{"code" => error.code, "message" => error.message}
  end

  @impl true
  def around_dispatch(operation, params, %Context{} = context, next) do
    proxy = proxy!(context)

    case operation do
      :tools_list -> list(proxy, :tools, context)
      :prompts_list -> list(proxy, :prompts, context)
      :resources_list -> list(proxy, :resources, context)
      :resource_templates_list -> list(proxy, :resource_templates, context)
      {:tools_call, name} -> tool_call(proxy, name, params, context)
      {:prompt_get, name} -> prompt_get(proxy, name, params, context)
      {:resource_read, uri} -> resource_read(proxy, uri, context)
      _other -> next.(context)
    end
  end

  defp list(proxy, kind, context) do
    catalog = Manager.catalog(proxy)
    entries = catalog |> Map.fetch!(kind) |> Map.values()
    authorization = authorization(context)

    Enum.reduce_while(entries, {:ok, []}, fn entry, {:ok, visible} ->
      case Authorization.decide(authorization, :discovery, component(entry), context) do
        :ok -> {:cont, {:ok, [entry.public | visible]}}
        {:refused, _error} -> {:cont, {:ok, visible}}
        {:fault, error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, visible} ->
        key = list_key(kind)
        visible = Enum.sort_by(visible, &Map.fetch!(&1, sort_key(kind)))
        {:ok, Result.wire(%{key => visible})}

      {:error, error} ->
        {:error, error}
    end
  end

  defp tool_call(proxy, name, params, context) do
    with {:ok, entry} <- fetch(Manager.catalog(proxy), :tool, name),
         :ok <- authorize(entry, context),
         {:ok, arguments} <- tool_arguments(params) do
      entry.client
      |> Client.call_tool(entry.original, arguments, request_options(context))
      |> rewrite_content_uris(:tool, entry.id, Manager.catalog(proxy))
      |> forward_result()
    else
      {:invalid_arguments, message} -> {:ok, Result.error(message)}
      {:error, error} -> {:error, error}
    end
  end

  defp prompt_get(proxy, name, params, context) do
    with {:ok, entry} <- fetch(Manager.catalog(proxy), :prompt, name),
         :ok <- authorize(entry, context),
         {:ok, arguments} <- prompt_arguments(params) do
      entry.client
      |> Client.get_prompt(entry.original["name"], arguments, request_options(context))
      |> rewrite_content_uris(:prompt, entry.id, Manager.catalog(proxy))
      |> forward_result()
    end
  end

  defp resource_read(proxy, uri, context) do
    case Catalog.lookup_resource(Manager.catalog(proxy), uri) do
      {:ok, entry, original_uri} ->
        with :ok <- authorize(entry, context, uri) do
          entry.client
          |> Client.read_resource(original_uri, request_options(context))
          |> rewrite_content_uris(:resource, entry.id, Manager.catalog(proxy))
          |> forward_result()
        end

      :error ->
        {:error, Error.invalid_params("Resource not found", %{"uri" => uri})}

      {:error, :ambiguous} ->
        {:error, Error.invalid_params("Resource matches multiple templates", %{"uri" => uri})}
    end
  end

  defp fetch(catalog, kind, name) do
    case Catalog.lookup(catalog, kind, name) do
      {:ok, entry} -> {:ok, entry}
      :error -> {:error, Error.invalid_params("Unknown #{kind}: #{name}")}
    end
  end

  defp authorize(entry, context, requested_uri \\ nil) do
    authorization = authorization(context)
    component = component(entry, requested_uri)

    case Authorization.decide(authorization, :invocation, component, context) do
      :ok ->
        :ok

      {:refused, error} ->
        if Authorization.conceal?(authorization),
          do: {:error, concealed_error(entry, requested_uri)},
          else: {:error, error}

      {:fault, error} ->
        {:error, error}
    end
  end

  defp component(entry, requested_uri \\ nil) do
    uri =
      if entry.kind in [:resource, :resource_template],
        do: entry.public[uri_key(entry)],
        else: nil

    %Component{
      kind: entry.kind,
      name: entry.name,
      uri: uri,
      requested_uri: if(entry.kind == :resource_template, do: requested_uri)
    }
  end

  defp concealed_error(%{kind: :tool, name: name}, _uri),
    do: Error.invalid_params("Unknown tool: #{name}")

  defp concealed_error(%{kind: :prompt, name: name}, _uri),
    do: Error.invalid_params("Unknown prompt: #{name}")

  defp concealed_error(_entry, uri),
    do: Error.invalid_params("Resource not found", %{"uri" => uri})

  defp tool_arguments(params) do
    case Map.get(params, "arguments", %{}) do
      arguments when is_map(arguments) -> {:ok, arguments}
      _invalid -> {:invalid_arguments, "Tool arguments must be an object"}
    end
  end

  defp prompt_arguments(params) do
    case Map.get(params, "arguments", %{}) do
      arguments when is_map(arguments) -> {:ok, arguments}
      _invalid -> {:error, Error.invalid_params("Prompt arguments must be an object")}
    end
  end

  defp forward_result({:ok, result}) when is_map(result), do: {:ok, Result.wire(result)}

  defp forward_result({:input_required, result}) when is_map(result),
    do: {:ok, Result.wire(result)}

  defp forward_result({:error, %Error{} = error}), do: {:error, error}

  defp rewrite_content_uris({status, result}, kind, id, catalog)
       when status in [:ok, :input_required] and is_map(result) do
    rewritten =
      case {kind, result} do
        {:tool, %{"content" => contents}} when is_list(contents) ->
          Map.put(result, "content", Enum.map(contents, &rewrite_content(&1, id, catalog)))

        {:prompt, %{"messages" => messages}} when is_list(messages) ->
          Map.put(result, "messages", Enum.map(messages, &rewrite_message(&1, id, catalog)))

        {:resource, %{"contents" => contents}} when is_list(contents) ->
          Map.put(result, "contents", Enum.map(contents, &rewrite_uri(&1, id, catalog)))

        _other ->
          result
      end

    {status, rewritten}
  end

  defp rewrite_content_uris(result, _kind, _id, _catalog), do: result

  defp rewrite_message(%{"content" => content} = message, id, catalog),
    do: Map.put(message, "content", rewrite_content(content, id, catalog))

  defp rewrite_message(message, _id, _catalog), do: message

  defp rewrite_content(contents, id, catalog) when is_list(contents),
    do: Enum.map(contents, &rewrite_content(&1, id, catalog))

  defp rewrite_content(%{"type" => "resource_link"} = content, id, catalog),
    do: rewrite_uri(content, id, catalog)

  defp rewrite_content(%{"type" => "resource", "resource" => resource} = content, id, catalog)
       when is_map(resource),
       do: Map.put(content, "resource", rewrite_uri(resource, id, catalog))

  defp rewrite_content(content, _id, _catalog), do: content

  defp rewrite_uri(%{"uri" => uri} = content, id, catalog) when is_binary(uri) do
    public_uri = Catalog.uri(id, uri)

    case Catalog.lookup_resource(catalog, public_uri) do
      {:ok, _entry, _original_uri} -> Map.put(content, "uri", public_uri)
      _unknown_or_ambiguous -> content
    end
  end

  defp rewrite_uri(content, _id, _catalog), do: content

  defp request_options(context) do
    []
    |> maybe_put(:trace_context, context.trace_context, context.trace_context != %{})
    |> maybe_put(:request_state, context.request_state, is_binary(context.request_state))
    |> maybe_put(:input_responses, context.input_responses, context.input_responses != %{})
    |> maybe_put(:progress, progress_callback(context), not is_nil(context.progress))
  end

  defp progress_callback(%Context{progress: nil}), do: nil

  defp progress_callback(context) do
    fn params ->
      opts =
        []
        |> maybe_put(:total, params["total"], Map.has_key?(params, "total"))
        |> maybe_put(:message, params["message"], Map.has_key?(params, "message"))

      Progress.report(context, params["progress"], opts)
    end
  end

  defp maybe_put(opts, key, value, true), do: Keyword.put(opts, key, value)
  defp maybe_put(opts, _key, _value, false), do: opts

  defp manager!(context) do
    context.extension_options
    |> Map.fetch!(@id)
    |> Map.fetch!(:manager)
  end

  defp proxy!(context) do
    context.extension_options
    |> Map.fetch!(@id)
    |> Map.fetch!(:proxy)
  end

  defp authorization(context) do
    context.extension_options |> Map.fetch!(@id) |> Map.fetch!(:authorization)
  end

  defp list_key(:tools), do: "tools"
  defp list_key(:prompts), do: "prompts"
  defp list_key(:resources), do: "resources"
  defp list_key(:resource_templates), do: "resourceTemplates"

  defp sort_key(kind) when kind in [:tools, :prompts], do: "name"
  defp sort_key(:resources), do: "uri"
  defp sort_key(:resource_templates), do: "uriTemplate"

  defp uri_key(%{kind: :resource}), do: "uri"
  defp uri_key(%{kind: :resource_template}), do: "uriTemplate"
end
