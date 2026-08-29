defmodule MCP.Protocol.Profile.Method do
  @moduledoc "A declarative method rule for one exact MCP protocol profile."

  @type kind :: :request | :notification
  @type direction :: :client_to_server | :server_to_client
  @type params_policy :: :required | :optional
  @type status :: :implemented | :unsupported
  @type placement :: :top_level | :mrtr_embedded
  @type lifecycle :: :active | :deprecated
  @type validator :: {module(), atom()}

  @type t :: %__MODULE__{
          name: String.t(),
          kind: kind(),
          directions: [direction()],
          params: params_policy(),
          capability: String.t() | nil,
          status: status(),
          placement: placement(),
          lifecycle: lifecycle(),
          validator: validator() | nil
        }

  @enforce_keys [:name, :kind, :directions, :params, :status]
  defstruct [
    :name,
    :kind,
    :directions,
    :params,
    :capability,
    :validator,
    :status,
    placement: :top_level,
    lifecycle: :active
  ]

  @spec new!(keyword()) :: t()
  def new!(opts) when is_list(opts) do
    method = struct!(__MODULE__, opts)
    validate!(method)
  end

  @doc false
  @spec validate!(t()) :: t()
  def validate!(%__MODULE__{} = method) do
    validate_name!(method.name)
    validate_kind!(method.kind)
    validate_directions!(method.directions)
    validate_params!(method.params)
    validate_capability!(method.capability)
    validate_status!(method.status)
    validate_placement!(method.placement)
    validate_lifecycle!(method.lifecycle)
    validate_validator!(method.validator)

    method
  end

  defp validate_name!(name) do
    unless is_binary(name) and name != "" do
      raise ArgumentError, "protocol method name must be a non-empty string"
    end
  end

  defp validate_kind!(kind) do
    unless kind in [:request, :notification] do
      raise ArgumentError, "protocol method kind must be :request or :notification"
    end
  end

  defp validate_directions!(directions) do
    valid_directions = [:client_to_server, :server_to_client]

    unless directions != [] and Enum.uniq(directions) == directions and
             Enum.all?(directions, &(&1 in valid_directions)) do
      raise ArgumentError, "protocol method directions must be a unique, non-empty direction list"
    end
  end

  defp validate_params!(params) do
    unless params in [:required, :optional] do
      raise ArgumentError, "protocol method params policy must be :required or :optional"
    end
  end

  defp validate_capability!(capability) do
    unless is_nil(capability) or (is_binary(capability) and capability != "") do
      raise ArgumentError, "protocol method capability must be nil or a non-empty string"
    end
  end

  defp validate_status!(status) do
    unless status in [:implemented, :unsupported] do
      raise ArgumentError, "protocol method status must be :implemented or :unsupported"
    end
  end

  defp validate_placement!(placement) do
    unless placement in [:top_level, :mrtr_embedded] do
      raise ArgumentError, "protocol method placement must be :top_level or :mrtr_embedded"
    end
  end

  defp validate_lifecycle!(lifecycle) do
    unless lifecycle in [:active, :deprecated] do
      raise ArgumentError, "protocol method lifecycle must be :active or :deprecated"
    end
  end

  defp validate_validator!(validator) do
    unless valid_validator?(validator) do
      raise ArgumentError, "protocol method validator must be nil or a {module, function} pair"
    end
  end

  defp valid_validator?(nil), do: true
  defp valid_validator?({module, function}), do: is_atom(module) and is_atom(function)
  defp valid_validator?(_validator), do: false
end

defmodule MCP.Protocol.Profile do
  @moduledoc """
  Immutable, exact-revision protocol facts used by admission and support reports.

  A profile catalogs one pinned revision and distinguishes implemented rules
  from known-but-unsupported rules. Admission executes only the implemented
  subset; catalog completeness is not a claim of full conformance.
  """

  alias MCP.Protocol.Profile.Method

  @standard_capabilities ~w(completions logging prompts resources tools)
  @open_capabilities ~w(experimental extensions)
  @capability_setting_requirements %{
    {"prompts", "listChanged"} => [
      {"notifications/prompts/list_changed", :server_to_client}
    ],
    {"resources", "listChanged"} => [
      {"notifications/resources/list_changed", :server_to_client}
    ],
    {"resources", "subscribe"} => [
      {"subscriptions/listen", :client_to_server},
      {"notifications/subscriptions/acknowledged", :server_to_client},
      {"notifications/resources/updated", :server_to_client}
    ],
    {"tools", "listChanged"} => [
      {"notifications/tools/list_changed", :server_to_client}
    ]
  }

  @type status :: :released | :experimental | :deprecated
  @type scope :: :complete | :implemented_slice
  @type batching :: :allowed | :forbidden
  @type metadata_policy :: %{request: :required | :optional, notification: :required | :optional}
  @type transport_status :: :tested | :implemented | :unsupported | :unmeasured

  @type t :: %__MODULE__{
          version: String.t(),
          status: status(),
          scope: scope(),
          era: :session | :stateless,
          batching: batching(),
          request_metadata: metadata_policy(),
          methods: [Method.t()],
          capabilities: [String.t()],
          transports: %{optional(atom()) => transport_status()},
          limitations: %{optional(atom()) => atom() | String.t()},
          specification: String.t()
        }

  @enforce_keys [
    :version,
    :status,
    :scope,
    :era,
    :batching,
    :request_metadata,
    :methods,
    :capabilities,
    :transports,
    :limitations,
    :specification
  ]
  defstruct @enforce_keys

  @spec new!(keyword()) :: t()
  def new!(opts) when is_list(opts) do
    profile = struct!(__MODULE__, opts)
    validate!(profile)
  end

  @spec fetch_method(t(), String.t()) :: {:ok, Method.t()} | :error
  def fetch_method(%__MODULE__{methods: methods}, name) when is_binary(name) do
    case Enum.find(methods, &(&1.name == name)) do
      %Method{} = method -> {:ok, method}
      nil -> :error
    end
  end

  @spec fetch_method(t(), String.t(), Method.direction()) :: {:ok, Method.t()} | :error
  def fetch_method(%__MODULE__{methods: methods}, name, direction)
      when is_binary(name) and direction in [:client_to_server, :server_to_client] do
    case Enum.find(methods, &(&1.name == name and direction in &1.directions)) do
      %Method{} = method -> {:ok, method}
      nil -> :error
    end
  end

  @spec method_names(t(), keyword()) :: [String.t()]
  def method_names(%__MODULE__{methods: methods}, filters \\ []) do
    methods
    |> Enum.filter(fn method ->
      Enum.all?(filters, fn
        {:kind, kind} -> method.kind == kind
        {:status, status} -> method.status == status
        {:direction, direction} -> direction in method.directions
      end)
    end)
    |> Enum.map(& &1.name)
    |> Enum.uniq()
  end

  @spec metadata_policy(t(), :request | :notification) :: :required | :optional
  def metadata_policy(%__MODULE__{request_metadata: policy}, kind), do: Map.fetch!(policy, kind)

  @spec unsupported_capabilities(t(), map()) :: [String.t()]
  def unsupported_capabilities(%__MODULE__{} = profile, capabilities) when is_map(capabilities) do
    unsupported_names =
      capabilities
      |> Map.keys()
      |> Enum.reject(&(&1 in profile.capabilities or &1 in @open_capabilities))

    unsupported_settings = unsupported_capability_settings(profile, capabilities)
    Enum.sort(unsupported_names ++ unsupported_settings)
  end

  @spec project_capabilities(t(), map()) :: map()
  def project_capabilities(%__MODULE__{} = profile, capabilities) when is_map(capabilities) do
    Map.take(capabilities, profile.capabilities ++ @open_capabilities)
  end

  defp unsupported_capability_settings(profile, capabilities) do
    for {{capability, setting}, requirements} <- @capability_setting_requirements,
        capability in profile.capabilities,
        get_in(capabilities, [capability, setting]) == true,
        not implemented_requirements?(profile, requirements) do
      "#{capability}.#{setting}"
    end
  end

  defp implemented_requirements?(profile, requirements) do
    Enum.all?(requirements, fn {method_name, direction} ->
      case fetch_method(profile, method_name, direction) do
        {:ok, %Method{status: :implemented}} -> true
        _unsupported_or_absent -> false
      end
    end)
  end

  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = profile) do
    %{
      "protocolVersion" => profile.version,
      "status" => Atom.to_string(profile.status),
      "scope" => Atom.to_string(profile.scope),
      "era" => Atom.to_string(profile.era),
      "batching" => Atom.to_string(profile.batching),
      "requestMetadata" => stringify_atom_values(profile.request_metadata),
      "methods" => Enum.map(profile.methods, &method_to_map/1),
      "capabilities" => profile.capabilities,
      "transports" => stringify_atom_keys_and_values(profile.transports),
      "limitations" => stringify_atom_keys_and_values(profile.limitations),
      "specification" => profile.specification
    }
  end

  defp method_to_map(%Method{} = method) do
    %{
      "name" => method.name,
      "kind" => Atom.to_string(method.kind),
      "directions" => Enum.map(method.directions, &Atom.to_string/1),
      "params" => Atom.to_string(method.params),
      "capability" => method.capability,
      "status" => Atom.to_string(method.status),
      "placement" => Atom.to_string(method.placement),
      "lifecycle" => Atom.to_string(method.lifecycle)
    }
  end

  defp stringify_atom_values(map) do
    Map.new(map, fn {key, value} -> {Atom.to_string(key), Atom.to_string(value)} end)
  end

  defp stringify_atom_keys_and_values(map) do
    Map.new(map, fn {key, value} ->
      value = if is_atom(value), do: Atom.to_string(value), else: value
      {Atom.to_string(key), value}
    end)
  end

  @doc false
  @spec validate!(t()) :: t()
  def validate!(%__MODULE__{} = profile) do
    validate_version!(profile.version)
    validate_profile_status!(profile.status)
    validate_scope!(profile.scope)
    validate_era!(profile.era)
    validate_batching!(profile.batching)
    validate_metadata_policy!(profile.request_metadata)
    validate_methods!(profile.methods)
    validate_capabilities!(profile.capabilities)
    validate_method_capabilities!(profile.methods, profile.capabilities)
    validate_transports!(profile.transports)
    validate_limitations!(profile.limitations)
    validate_specification!(profile.specification)

    profile
  end

  defp validate_version!(version) do
    unless is_binary(version) and version != "" do
      raise ArgumentError, "protocol profile version must be a non-empty string"
    end
  end

  defp validate_profile_status!(status) do
    unless status in [:released, :experimental, :deprecated] do
      raise ArgumentError, "protocol profile status is invalid"
    end
  end

  defp validate_scope!(scope) do
    unless scope in [:complete, :implemented_slice] do
      raise ArgumentError, "protocol profile scope must be :complete or :implemented_slice"
    end
  end

  defp validate_era!(era) do
    unless era in [:session, :stateless] do
      raise ArgumentError, "protocol profile era must be :session or :stateless"
    end
  end

  defp validate_batching!(batching) do
    unless batching in [:allowed, :forbidden] do
      raise ArgumentError, "protocol profile batching must be :allowed or :forbidden"
    end
  end

  defp validate_metadata_policy!(policy) do
    unless policy in [
             %{request: :required, notification: :required},
             %{request: :required, notification: :optional},
             %{request: :optional, notification: :required},
             %{request: :optional, notification: :optional}
           ] do
      raise ArgumentError, "protocol profile request_metadata policy is invalid"
    end
  end

  defp validate_methods!(methods) do
    unless is_list(methods) and Enum.all?(methods, &match?(%Method{}, &1)) do
      raise ArgumentError, "protocol profile methods must contain Method structs"
    end

    Enum.each(methods, &Method.validate!/1)

    directional_names =
      for method <- methods, direction <- method.directions do
        {method.name, direction}
      end

    unless Enum.uniq(directional_names) == directional_names do
      raise ArgumentError, "protocol profile contains overlapping method direction rules"
    end
  end

  defp validate_capabilities!(capabilities) do
    unless is_list(capabilities) and Enum.uniq(capabilities) == capabilities and
             Enum.all?(capabilities, &(&1 in @standard_capabilities)) do
      raise ArgumentError,
            "protocol profile capabilities must be unique standard capability names"
    end
  end

  defp validate_method_capabilities!(methods, capabilities) do
    method_capabilities = methods |> Enum.map(& &1.capability) |> Enum.reject(&is_nil/1)

    unless Enum.all?(method_capabilities, &(&1 in @standard_capabilities)) do
      raise ArgumentError, "protocol methods reference unknown standard capabilities"
    end

    implemented_capabilities =
      methods
      |> Enum.filter(&(&1.status == :implemented))
      |> Enum.map(& &1.capability)
      |> Enum.reject(&is_nil/1)

    unless Enum.all?(implemented_capabilities, &(&1 in capabilities)) do
      raise ArgumentError, "protocol methods reference capabilities absent from the profile"
    end
  end

  defp validate_transports!(transports) do
    unless valid_status_map?(transports, [:tested, :implemented, :unsupported, :unmeasured]) do
      raise ArgumentError, "protocol profile transports contain an invalid status"
    end
  end

  defp validate_limitations!(limitations) do
    valid? =
      is_map(limitations) and
        Enum.all?(limitations, fn {key, value} ->
          is_atom(key) and (is_atom(value) or is_binary(value))
        end)

    unless valid? do
      raise ArgumentError, "protocol profile limitations must map atom keys to atom/string values"
    end
  end

  defp validate_specification!(specification) do
    unless valid_uri?(specification) do
      raise ArgumentError, "protocol profile specification must be an absolute URI"
    end
  end

  defp valid_status_map?(map, statuses) when is_map(map) do
    Enum.all?(map, fn {key, value} -> is_atom(key) and value in statuses end)
  end

  defp valid_status_map?(_map, _statuses), do: false

  defp valid_uri?(value) when is_binary(value) do
    case URI.new(value) do
      {:ok, %URI{scheme: scheme}} when is_binary(scheme) and scheme != "" -> true
      _invalid -> false
    end
  end

  @doc false
  def standard_capabilities, do: @standard_capabilities

  @doc false
  def open_capabilities, do: @open_capabilities
end
