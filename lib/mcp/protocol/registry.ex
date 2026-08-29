defmodule MCP.Protocol.Registry do
  @moduledoc "An immutable, explicitly configured registry of protocol dialects."

  alias MCP.Envelope
  alias MCP.Error
  alias MCP.Protocol.Profile

  @required_callbacks [
    profile: 0,
    version: 0,
    era: 0,
    detect: 1,
    decode_request: 2,
    build_context: 2,
    resolve_operation: 1,
    validate_operation: 3,
    shape_result: 3,
    shape_error: 2,
    transport_policy: 1,
    server_discovery: 1,
    request_metadata: 1
  ]

  @type t :: %__MODULE__{
          protocols: [module()],
          by_version: %{optional(String.t()) => module()}
        }

  @enforce_keys [:protocols, :by_version]
  defstruct [:protocols, :by_version]

  @spec new([module()]) :: t()
  def new(protocols) when is_list(protocols) do
    {ordered, by_version} =
      Enum.reduce(protocols, {[], %{}}, fn protocol, {ordered, by_version} ->
        validate_protocol!(protocol)
        version = protocol.profile().version

        if Map.has_key?(by_version, version) do
          raise ArgumentError, "duplicate MCP protocol version #{inspect(version)}"
        end

        {[protocol | ordered], Map.put(by_version, version, protocol)}
      end)

    %__MODULE__{protocols: Enum.reverse(ordered), by_version: by_version}
  end

  @spec versions(t(), keyword()) :: [String.t()]
  def versions(%__MODULE__{} = registry, opts \\ []) do
    case Keyword.get(opts, :era) do
      nil -> registry.protocols
      era -> Enum.filter(registry.protocols, &(&1.profile().era == era))
    end
    |> Enum.map(& &1.profile().version)
  end

  @spec profiles(t()) :: [Profile.t()]
  def profiles(%__MODULE__{} = registry), do: Enum.map(registry.protocols, & &1.profile())

  @spec fetch(t(), String.t()) :: {:ok, module()} | {:error, Error.t()}
  def fetch(%__MODULE__{} = registry, version) when is_binary(version) do
    case Map.fetch(registry.by_version, version) do
      {:ok, protocol} ->
        {:ok, protocol}

      :error ->
        {:error,
         Error.invalid_params("Protocol version is not enabled", %{
           "requested" => version,
           "enabled" => versions(registry)
         })}
    end
  end

  @spec select(t(), Envelope.t()) :: {:ok, module()} | {:error, Error.t()}
  def select(%__MODULE__{} = registry, %Envelope{} = envelope) do
    detect(registry, envelope)
  end

  defp detect(registry, envelope) do
    detections = Enum.map(registry.protocols, &{&1, &1.detect(envelope)})
    exact = for {protocol, :exact} <- detections, do: protocol
    fallback = for {protocol, :fallback} <- detections, do: protocol

    matches = if exact == [], do: fallback, else: exact

    case matches do
      [protocol] ->
        {:ok, protocol}

      [] ->
        {:error, Error.invalid_request("No configured protocol dialect recognized the request")}

      _protocols ->
        {:error, Error.invalid_request("Multiple protocol dialects matched the request")}
    end
  end

  defp validate_protocol!(protocol) when is_atom(protocol) do
    case Code.ensure_loaded(protocol) do
      {:module, ^protocol} -> :ok
      _ -> raise ArgumentError, "protocol module #{inspect(protocol)} could not be loaded"
    end

    Enum.each(@required_callbacks, fn {function, arity} ->
      unless function_exported?(protocol, function, arity) do
        raise ArgumentError,
              "protocol module #{inspect(protocol)} does not export #{function}/#{arity}"
      end
    end)

    unless match?(%Profile{}, protocol.profile()) do
      raise ArgumentError, "protocol module #{inspect(protocol)} returned an invalid profile"
    end

    profile = Profile.validate!(protocol.profile())

    unless protocol.version() == profile.version do
      raise ArgumentError,
            "protocol module #{inspect(protocol)} version/0 drifted from its profile"
    end

    unless protocol.era() == profile.era do
      raise ArgumentError, "protocol module #{inspect(protocol)} era/0 drifted from its profile"
    end

    Enum.each(profile.methods, fn
      %Profile.Method{validator: nil} ->
        :ok

      %Profile.Method{validator: {module, function}} ->
        unless Code.ensure_loaded?(module) and function_exported?(module, function, 1) do
          raise ArgumentError,
                "protocol profile validator #{inspect(module)}.#{function}/1 is unavailable"
        end
    end)
  end
end
