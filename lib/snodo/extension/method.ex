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

  @doc """
  Builds a method for an extension's `c:Snodo.Extension.methods/0` list.

  Options:

    * `:protocol_version` - the exact protocol version the method belongs
      to, such as `"2026-07-28"`. Required.
    * `:name` - the JSON-RPC method name. Required.
    * `:operation` - the term passed to the extension's
      `c:Snodo.Extension.validate_operation/3`, `c:Snodo.Extension.dispatch/3`,
      and `c:Snodo.Extension.shape_result/3`. Required.
    * `:params` - `:required` (the default) or `:optional`: whether a request
      must carry `params`.
    * `:kind` and `:direction` - only `:request` and `:client_to_server`,
      the defaults, are supported.

  A missing required option raises `KeyError`; an invalid value raises
  `ArgumentError`.

      Snodo.Extension.Method.new!(
        protocol_version: "2026-07-28",
        name: "dev.example/greet",
        operation: :greet
      )
  """
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
