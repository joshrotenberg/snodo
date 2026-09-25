defmodule Snodo.Extension.Method do
  @moduledoc "An exact-versioned extension method mapped to a static operation term."

  alias Snodo.Protocol.Profile.Method, as: ProfileMethod

  @type t :: %__MODULE__{
          protocol_version: String.t(),
          name: String.t(),
          operation: term(),
          kind: :request,
          direction: :client_to_server,
          params: :required | :optional,
          rule: ProfileMethod.t()
        }

  @enforce_keys [:protocol_version, :name, :operation, :rule]
  defstruct [
    :protocol_version,
    :name,
    :operation,
    :rule,
    kind: :request,
    direction: :client_to_server,
    params: :required
  ]

  @spec new!(keyword()) :: t()
  def new!(opts) when is_list(opts) do
    version = Keyword.fetch!(opts, :protocol_version)
    name = Keyword.fetch!(opts, :name)
    operation = Keyword.fetch!(opts, :operation)
    kind = Keyword.get(opts, :kind, :request)
    direction = Keyword.get(opts, :direction, :client_to_server)
    params = Keyword.get(opts, :params, :required)

    validate_protocol_version!(version)
    validate_surface!(kind, direction)

    rule =
      ProfileMethod.new!(
        name: name,
        kind: kind,
        directions: [direction],
        params: params,
        status: :implemented,
        placement: :top_level
      )

    %__MODULE__{
      protocol_version: version,
      name: name,
      operation: operation,
      kind: kind,
      direction: direction,
      params: params,
      rule: rule
    }
    |> validate!()
  end

  @doc false
  @spec validate!(t()) :: t()
  def validate!(%__MODULE__{} = method) do
    validate_protocol_version!(method.protocol_version)
    validate_surface!(method.kind, method.direction)
    rule = ProfileMethod.validate!(method.rule)
    validate_rule_agreement!(method, rule)
    method
  end

  defp validate_protocol_version!(version) do
    unless is_binary(version) and version != "" do
      raise ArgumentError, "extension method protocol_version must be a non-empty string"
    end
  end

  defp validate_surface!(kind, direction) do
    unless kind == :request and direction == :client_to_server do
      raise ArgumentError,
            "the initial extension seam supports client-to-server requests only"
    end
  end

  defp validate_rule_agreement!(method, rule) do
    unless rule.name == method.name and rule.kind == method.kind and
             rule.directions == [method.direction] and rule.params == method.params and
             rule.status == :implemented and rule.placement == :top_level do
      raise ArgumentError, "extension method descriptor and inspection rule must agree"
    end
  end
end
