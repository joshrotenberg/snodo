defmodule Snodo.Server.Runtime do
  @moduledoc "Immutable server configuration shared by direct and transport dispatch."

  alias Snodo.Authorization
  alias Snodo.Extension.Registry, as: ExtensionRegistry
  alias Snodo.Instrumentation
  alias Snodo.Pagination
  alias Snodo.Protocol.Legacy
  alias Snodo.Protocol.Profile
  alias Snodo.Protocol.Registry
  alias Snodo.Router
  alias Snodo.Schema.Validator.Passthrough
  alias Snodo.Subscription.Source

  require Logger

  @meta_key ~r/^(?:(?:[A-Za-z](?:[A-Za-z0-9-]*[A-Za-z0-9])?)(?:\.(?:[A-Za-z](?:[A-Za-z0-9-]*[A-Za-z0-9])?))*\/)?(?:[A-Za-z0-9](?:[A-Za-z0-9._-]*[A-Za-z0-9])?)?$/

  @type cache_policy :: %{ttl_ms: non_neg_integer(), scope: String.t()}
  @type t :: %__MODULE__{
          router: Router.t(),
          protocol_registry: Registry.t(),
          server_info: map(),
          capabilities: map(),
          instrumentation: Instrumentation.Config.t() | nil,
          schema_validator: module(),
          instructions: String.t() | nil,
          discovery_cache: cache_policy(),
          tools_cache: cache_policy(),
          prompts_cache: cache_policy(),
          resources_cache: cache_policy(),
          pagination: Pagination.t(),
          subscription_source: Source.Config.t() | nil,
          extension_registry: ExtensionRegistry.t(),
          authorization: Authorization.config()
        }

  @enforce_keys [:router, :protocol_registry, :server_info, :capabilities]
  defstruct [
    :router,
    :protocol_registry,
    :server_info,
    :capabilities,
    :schema_validator,
    :extension_registry,
    :instrumentation,
    :subscription_source,
    :authorization,
    :instructions,
    discovery_cache: %{ttl_ms: 0, scope: "private"},
    tools_cache: %{ttl_ms: 0, scope: "private"},
    prompts_cache: %{ttl_ms: 0, scope: "private"},
    resources_cache: %{ttl_ms: 0, scope: "private"},
    pagination: %Pagination{}
  ]

  @doc """
  Builds and validates a runtime. It starts no process.

  A module that uses `Snodo.Server` builds its runtime with `runtime/1`, which
  calls this function with the declared options and any overrides.

  Required options:

    * `:router` - the `Snodo.Router` with the registered components.
    * `:protocols` - the protocol dialect modules to enable, in preference
      order, such as `[Snodo.Protocol.V2026_07_28]`.
    * `:server_info` - a map with string `"name"` and `"version"` and,
      optionally, `"title"`, `"description"`, `"websiteUrl"`, and `"icons"`.

  Other options:

    * `:capabilities` - the server capabilities map. Defaults to `"tools"`,
      `"prompts"`, and `"resources"` for each kind the router has
      registered, plus `"completions"` when a registered prompt or resource
      template supports completion.
    * `:extensions` - `Snodo.Extension` modules or `{module, options}`
      tuples. Defaults to `[]`.
    * `:instructions` - a string returned in `server/discover` and
      `initialize` results, or `nil` (the default).
    * `:schema_validator` - a `Snodo.Schema.Validator` module. Defaults to
      `Snodo.Schema.Validator.Passthrough`.
    * `:subscription_source` - a `Snodo.Subscription.Source` module or
      `{module, options}`. Defaults to `nil`, which leaves
      `subscriptions/listen` unavailable.
    * `:instrumentation` - a `Snodo.Instrumentation` sink module or
      `{module, options}`. Defaults to `nil`.
    * `:authorization` - a `Snodo.Authorization` policy module or
      `{module, options}`. Defaults to `nil`.
    * `:discovery_cache`, `:tools_cache`, `:prompts_cache`,
      `:resources_cache` - `[ttl_ms: non_neg_integer, scope: "private" |
      "public"]`. Each defaults to `ttl_ms: 0, scope: "private"`.
    * `:pagination` - `[page_size: pos_integer]`. Defaults to a page size
      of 100.

  A missing required option raises `KeyError`. An invalid value raises
  `ArgumentError`, including a capability an enabled protocol profile does
  not support, `"completions"` without a completion-capable component, a
  `listChanged` or `subscribe` setting of `true` without a
  `:subscription_source`, and an advertised extension that is not installed.
  When an initialize-era dialect is enabled, a warning is logged naming any
  tool those clients cannot list.
  """
  @spec new(keyword()) :: t()
  def new(opts) when is_list(opts) do
    router = Keyword.fetch!(opts, :router)
    protocols = Keyword.fetch!(opts, :protocols)
    protocol_registry = Registry.new(protocols)

    extension_registry =
      opts
      |> Keyword.get(:extensions, [])
      |> ExtensionRegistry.new(protocol_registry)

    server_info = Keyword.fetch!(opts, :server_info)
    capabilities = Keyword.get(opts, :capabilities, default_capabilities(router))
    instructions = Keyword.get(opts, :instructions)
    schema_validator = Keyword.get(opts, :schema_validator, Passthrough)
    subscription_source = opts |> Keyword.get(:subscription_source) |> Source.normalize!()
    instrumentation = opts |> Keyword.get(:instrumentation) |> Instrumentation.normalize!()
    authorization = opts |> Keyword.get(:authorization) |> Authorization.normalize!()

    _validated_server_info = validate_server_info!(server_info)
    _validated_capabilities = validate_capabilities!(capabilities)
    validate_completion_advertisement!(capabilities, router)
    validate_subscription_advertisement!(capabilities, subscription_source)
    validate_protocol_capabilities!(capabilities, protocol_registry)
    ExtensionRegistry.validate_advertisement!(extension_registry, capabilities)
    _validated_instructions = validate_instructions!(instructions)
    validate_schema_validator!(schema_validator)
    warn_inexpressible_legacy_tools(router, protocols)

    %__MODULE__{
      router: router,
      protocol_registry: protocol_registry,
      server_info: server_info,
      capabilities: capabilities,
      schema_validator: schema_validator,
      extension_registry: extension_registry,
      instrumentation: instrumentation,
      subscription_source: subscription_source,
      authorization: authorization,
      instructions: instructions,
      discovery_cache: cache_policy(Keyword.get(opts, :discovery_cache, [])),
      tools_cache: cache_policy(Keyword.get(opts, :tools_cache, [])),
      prompts_cache: cache_policy(Keyword.get(opts, :prompts_cache, [])),
      resources_cache: cache_policy(Keyword.get(opts, :resources_cache, [])),
      pagination: Pagination.new(Keyword.get(opts, :pagination, []))
    }
  end

  defp warn_inexpressible_legacy_tools(router, protocols) do
    legacy_versions =
      for protocol <- protocols, protocol.era() == :session, do: protocol.version()

    names = if legacy_versions == [], do: [], else: Legacy.inexpressible_tools(router)

    if names != [] do
      Logger.warning(
        "Tools without object input and output schemas are hidden from " <>
          "initialize-era clients (#{Enum.join(legacy_versions, ", ")}): #{Enum.join(names, ", ")}"
      )
    end

    :ok
  end

  defp default_capabilities(%Router{} = router) do
    %{}
    |> maybe_put_capability("tools", map_size(router.tools) > 0)
    |> maybe_put_capability("prompts", map_size(router.prompts) > 0)
    |> maybe_put_capability("completions", Router.completion_capable?(router))
    |> maybe_put_capability(
      "resources",
      map_size(router.resources) > 0 or map_size(router.resource_templates) > 0
    )
  end

  defp maybe_put_capability(capabilities, key, true), do: Map.put(capabilities, key, %{})
  defp maybe_put_capability(capabilities, _key, false), do: capabilities

  defp cache_policy(opts) when is_list(opts) do
    validate_cache_policy!(%{
      ttl_ms: Keyword.get(opts, :ttl_ms, 0),
      scope: Keyword.get(opts, :scope, "private")
    })
  end

  defp cache_policy(%{ttl_ms: ttl_ms, scope: scope}) do
    validate_cache_policy!(%{ttl_ms: ttl_ms, scope: scope})
  end

  defp validate_cache_policy!(%{ttl_ms: ttl_ms, scope: scope} = policy)
       when is_integer(ttl_ms) and ttl_ms >= 0 and scope in ["public", "private"],
       do: policy

  defp validate_cache_policy!(_policy) do
    raise ArgumentError,
          "cache policy requires a non-negative integer :ttl_ms and public/private :scope"
  end

  defp validate_server_info!(%{"name" => name, "version" => version} = server_info)
       when is_binary(name) and is_binary(version) do
    validate_json_object!(server_info, "server_info")
    validate_optional_string!(server_info, "title", "server info title")
    validate_optional_string!(server_info, "description", "server info description")
    validate_optional_uri!(server_info, "websiteUrl", "server info websiteUrl")

    case Map.fetch(server_info, "icons") do
      {:ok, icons} when is_list(icons) -> Enum.each(icons, &validate_icon!/1)
      {:ok, _invalid} -> raise ArgumentError, "server info icons must be a list"
      :error -> :ok
    end

    server_info
  end

  defp validate_server_info!(_server_info) do
    raise ArgumentError, "server_info requires string name and version fields"
  end

  defp validate_icon!(%{"src" => src} = icon) when is_binary(src) do
    unless valid_uri?(src), do: raise(ArgumentError, "icon src must be a URI string")
    validate_optional_string!(icon, "mimeType", "icon mimeType")

    case Map.fetch(icon, "sizes") do
      {:ok, sizes} when is_list(sizes) ->
        unless Enum.all?(sizes, &is_binary/1),
          do: raise(ArgumentError, "icon sizes must be strings")

      {:ok, _invalid} ->
        raise ArgumentError, "icon sizes must be a list of strings"

      :error ->
        :ok
    end

    case Map.fetch(icon, "theme") do
      {:ok, theme} when theme in ["light", "dark"] -> :ok
      {:ok, _invalid} -> raise ArgumentError, "icon theme must be light or dark"
      :error -> :ok
    end
  end

  defp validate_icon!(_icon), do: raise(ArgumentError, "each server icon requires a string src")

  defp validate_capabilities!(capabilities) when is_map(capabilities) do
    validate_json_object!(capabilities, "capabilities")
    validate_object_registry!(capabilities, "experimental", false)
    validate_optional_object!(capabilities, "logging")
    validate_optional_object!(capabilities, "completions")
    validate_optional_boolean_fields!(capabilities, "prompts", ["listChanged"])

    validate_optional_boolean_fields!(capabilities, "resources", [
      "subscribe",
      "listChanged"
    ])

    validate_optional_boolean_fields!(capabilities, "tools", ["listChanged"])
    validate_object_registry!(capabilities, "extensions", true)

    capabilities
  end

  defp validate_capabilities!(_capabilities) do
    raise ArgumentError, "capabilities must be an object"
  end

  defp validate_completion_advertisement!(capabilities, router) do
    if Map.has_key?(capabilities, "completions") and not Router.completion_capable?(router) do
      raise ArgumentError,
            "completions capability requires a registered completion-capable prompt or resource template"
    end

    :ok
  end

  defp validate_subscription_advertisement!(capabilities, subscription_source) do
    notification_settings = [
      get_in(capabilities, ["tools", "listChanged"]),
      get_in(capabilities, ["prompts", "listChanged"]),
      get_in(capabilities, ["resources", "listChanged"]),
      get_in(capabilities, ["resources", "subscribe"])
    ]

    if true in notification_settings and is_nil(subscription_source) do
      raise ArgumentError,
            "listChanged/subscribe capabilities require a configured subscription_source"
    end

    :ok
  end

  defp validate_protocol_capabilities!(capabilities, %Registry{} = registry) do
    unsupported =
      registry
      |> Registry.profiles()
      |> Enum.flat_map(fn profile ->
        Enum.map(
          Profile.unsupported_capabilities(profile, capabilities),
          fn capability ->
            {profile.version, capability}
          end
        )
      end)

    case unsupported do
      [] ->
        :ok

      entries ->
        details =
          entries
          |> Enum.map_join(", ", fn {version, capability} ->
            "#{capability} for #{version}"
          end)

        raise ArgumentError,
              "server capabilities advertise unsupported protocol surfaces: #{details}"
    end
  end

  defp validate_instructions!(instructions) when is_nil(instructions) or is_binary(instructions),
    do: instructions

  defp validate_instructions!(_instructions) do
    raise ArgumentError, "instructions must be a string or nil"
  end

  defp validate_schema_validator!(validator) when is_atom(validator) do
    case Code.ensure_loaded(validator) do
      {:module, ^validator} ->
        unless function_exported?(validator, :validate, 2) do
          raise ArgumentError, "schema_validator must export validate/2"
        end

      _not_loaded ->
        raise ArgumentError, "schema_validator #{inspect(validator)} could not be loaded"
    end
  end

  defp validate_schema_validator!(_validator) do
    raise ArgumentError, "schema_validator must be a module"
  end

  defp validate_optional_string!(map, key, label) do
    case Map.fetch(map, key) do
      {:ok, value} when is_binary(value) -> :ok
      {:ok, _invalid} -> raise ArgumentError, "#{label} must be a string"
      :error -> :ok
    end
  end

  defp validate_optional_uri!(map, key, label) do
    case Map.fetch(map, key) do
      {:ok, value} when is_binary(value) ->
        unless valid_uri?(value), do: raise(ArgumentError, "#{label} must be a URI string")

      {:ok, _invalid} ->
        raise ArgumentError, "#{label} must be a URI string"

      :error ->
        :ok
    end
  end

  defp validate_optional_object!(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} when is_map(value) -> validate_json_object!(value, "#{key} capability")
      {:ok, _invalid} -> raise ArgumentError, "#{key} capability must be an object"
      :error -> :ok
    end
  end

  defp validate_optional_boolean_fields!(map, key, fields) do
    validate_optional_object!(map, key)

    case Map.fetch(map, key) do
      {:ok, settings} ->
        Enum.each(fields, &validate_optional_boolean_field!(settings, key, &1))

      :error ->
        :ok
    end
  end

  defp validate_object_registry!(map, key, require_prefix?) do
    case Map.fetch(map, key) do
      {:ok, registry} when is_map(registry) ->
        validate_json_object!(registry, "#{key} capability")
        Enum.each(registry, &validate_registry_entry!(&1, key, require_prefix?))

      {:ok, _invalid} ->
        raise ArgumentError, "#{key} capability must be an object"

      :error ->
        :ok
    end
  end

  defp validate_optional_boolean_field!(settings, capability, field) do
    case Map.fetch(settings, field) do
      {:ok, value} when is_boolean(value) -> :ok
      {:ok, _invalid} -> raise ArgumentError, "#{capability}.#{field} must be a boolean"
      :error -> :ok
    end
  end

  defp validate_registry_entry!({name, settings}, capability, require_prefix?) do
    valid_name? =
      is_binary(name) and
        (not require_prefix? or
           (Regex.match?(@meta_key, name) and String.contains?(name, "/")))

    unless valid_name? and is_map(settings) do
      raise ArgumentError, "#{capability} entries must map valid names to objects"
    end
  end

  defp validate_json_object!(value, label) do
    unless json_object?(value) do
      raise ArgumentError, "#{label} must contain only string keys and JSON values"
    end
  end

  defp valid_uri?(value) do
    case URI.new(value) do
      {:ok, %URI{scheme: scheme}} when is_binary(scheme) and scheme != "" -> true
      _uri -> false
    end
  end

  defp json_object?(value) when is_map(value) do
    Enum.all?(value, fn {key, nested} -> is_binary(key) and json_value?(nested) end)
  end

  defp json_value?(value)
       when is_nil(value) or is_boolean(value) or is_binary(value) or is_number(value),
       do: true

  defp json_value?(value) when is_list(value), do: Enum.all?(value, &json_value?/1)

  defp json_value?(value) when is_map(value) do
    json_object?(value)
  end

  defp json_value?(_value), do: false
end
