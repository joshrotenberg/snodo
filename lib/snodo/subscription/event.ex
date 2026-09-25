defmodule Snodo.Subscription.Event do
  @moduledoc """
  A protocol-neutral event emitted by an application subscription source.

  Constructors cover the core `subscriptions/listen` notification families
  and a generic extension-owned event envelope. The selected protocol dialect
  or negotiated extension adds wire method names and subscription metadata
  later, at the transport boundary.
  """

  alias Snodo.JSONValue

  @type kind ::
          :tools_list_changed
          | :prompts_list_changed
          | :resources_list_changed
          | :resource_updated
          | :extension

  @type t :: %__MODULE__{
          kind: kind(),
          uri: String.t() | nil,
          params: map(),
          metadata: map(),
          extension_id: String.t() | nil,
          selector: map(),
          payload: term()
        }

  @enforce_keys [:kind]
  defstruct [:kind, :uri, :extension_id, :payload, params: %{}, metadata: %{}, selector: %{}]

  @doc "Builds a `notifications/tools/list_changed` event."
  @spec tools_list_changed(keyword()) :: t()
  def tools_list_changed(opts \\ []), do: list_event(:tools_list_changed, opts)

  @doc "Builds a `notifications/prompts/list_changed` event."
  @spec prompts_list_changed(keyword()) :: t()
  def prompts_list_changed(opts \\ []), do: list_event(:prompts_list_changed, opts)

  @doc "Builds a `notifications/resources/list_changed` event."
  @spec resources_list_changed(keyword()) :: t()
  def resources_list_changed(opts \\ []), do: list_event(:resources_list_changed, opts)

  @doc "Builds a `notifications/resources/updated` event for one absolute URI."
  @spec resource_updated(String.t(), keyword()) :: t()
  def resource_updated(uri, opts \\ []) when is_binary(uri) and is_list(opts) do
    %__MODULE__{
      kind: :resource_updated,
      uri: uri,
      params: Keyword.get(opts, :params, %{}),
      metadata: Keyword.get(opts, :metadata, %{})
    }
  end

  @doc "Builds an event owned and wire-shaped by a negotiated extension."
  @spec extension(String.t(), map(), term(), keyword()) :: t()
  def extension(extension_id, selector, payload, opts \\ [])
      when is_binary(extension_id) and is_map(selector) and is_list(opts) do
    %__MODULE__{
      kind: :extension,
      extension_id: extension_id,
      selector: selector,
      payload: payload,
      metadata: Keyword.get(opts, :metadata, %{})
    }
  end

  @doc false
  @spec validate(t()) :: :ok | {:error, String.t()}
  def validate(%__MODULE__{kind: kind, params: params, metadata: metadata} = event)
      when kind in [
             :tools_list_changed,
             :prompts_list_changed,
             :resources_list_changed,
             :resource_updated
           ] do
    with :ok <- validate_object(params, "subscription event params must be a JSON object"),
         :ok <- validate_object(metadata, "subscription event metadata must be a JSON object"),
         :ok <- validate_core_uri(event) do
      validate_no_extension_fields(event)
    end
  end

  def validate(%__MODULE__{kind: :extension} = event) do
    cond do
      not is_binary(event.extension_id) or event.extension_id == "" ->
        {:error, "extension subscription events require an extension id"}

      not json_object?(event.selector) or map_size(event.selector) == 0 ->
        {:error, "extension subscription events require a non-empty JSON selector"}

      not json_object?(event.metadata) ->
        {:error, "subscription event metadata must be a JSON object"}

      not is_nil(event.uri) or event.params != %{} ->
        {:error, "extension subscription events cannot use core event fields"}

      true ->
        :ok
    end
  end

  def validate(_event), do: {:error, "subscription source returned an invalid event"}

  defp list_event(kind, opts) when is_list(opts) do
    %__MODULE__{
      kind: kind,
      params: Keyword.get(opts, :params, %{}),
      metadata: Keyword.get(opts, :metadata, %{})
    }
  end

  defp validate_object(value, message) do
    if json_object?(value), do: :ok, else: {:error, message}
  end

  defp validate_core_uri(%__MODULE__{kind: :resource_updated, uri: uri}) do
    if absolute_uri?(uri),
      do: :ok,
      else: {:error, "resource update events require an absolute URI"}
  end

  defp validate_core_uri(%__MODULE__{uri: nil}), do: :ok

  defp validate_core_uri(%__MODULE__{}) do
    {:error, "list change events cannot include a resource URI"}
  end

  defp validate_no_extension_fields(%__MODULE__{
         extension_id: nil,
         selector: selector,
         payload: nil
       })
       when map_size(selector) == 0,
       do: :ok

  defp validate_no_extension_fields(%__MODULE__{}) do
    {:error, "core subscription events cannot use extension event fields"}
  end

  defp json_object?(value) when is_map(value) do
    Enum.all?(value, fn {key, nested} -> is_binary(key) and JSONValue.valid?(nested) end)
  end

  defp json_object?(_value), do: false

  defp absolute_uri?(value) when is_binary(value) do
    case URI.new(value) do
      {:ok, %URI{scheme: scheme}} when is_binary(scheme) and scheme != "" -> true
      _invalid -> false
    end
  end

  defp absolute_uri?(_value), do: false
end
