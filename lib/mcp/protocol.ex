defmodule MCP.Protocol do
  @moduledoc """
  Behaviour for version-specific lifecycle, admission, routing, and wire shaping.

  Dialects are supplied explicitly to a runtime. Merely loading a dialect module
  never enables it.
  """

  alias MCP.Context
  alias MCP.Envelope
  alias MCP.Error
  alias MCP.Protocol.Profile
  alias MCP.Result
  alias MCP.Server.Runtime
  alias MCP.Subscription.Event, as: SubscriptionEvent
  alias MCP.Transport.Context, as: TransportContext
  alias MCP.Transport.Policy

  @callback profile() :: Profile.t()
  @callback version() :: String.t()
  @callback era() :: :session | :stateless
  @callback detect(Envelope.t()) :: :exact | :fallback | false
  @callback decode_request(map(), TransportContext.t()) ::
              {:ok, Envelope.t()} | {:error, Error.t()}
  @callback build_context(Envelope.t(), Runtime.t()) ::
              {:ok, Context.t()} | {:error, Error.t()}
  @callback resolve_operation(Envelope.t()) ::
              {:ok, term()} | :not_handled | {:error, Error.t()}
  @callback validate_operation(term(), map(), Context.t()) :: :ok | {:error, Error.t()}
  @callback shape_result(term(), Result.t(), Context.t()) :: map()
  @callback shape_error(Error.t(), Context.t() | nil) :: map()
  @callback transport_policy(Envelope.t() | nil) :: Policy.t()
  @callback server_discovery(Runtime.t()) :: map() | :unsupported
  @callback request_metadata(map()) :: map()
  @callback shape_subscription_ack(map(), MCP.Envelope.id(), Context.t()) :: map()
  @callback shape_subscription_event(SubscriptionEvent.t(), MCP.Envelope.id(), Context.t()) ::
              map()
  @callback shape_subscription_result(MCP.Envelope.id(), Context.t()) :: map()

  @optional_callbacks shape_subscription_ack: 3,
                      shape_subscription_event: 3,
                      shape_subscription_result: 2

  @doc "Returns the exact profiles bundled in-tree, independent of a runtime allowlist."
  @spec builtin_profiles() :: [Profile.t()]
  def builtin_profiles, do: [MCP.Protocol.V2026_07_28.profile()]

  @doc "Returns the bundled profile versions in preference order."
  @spec builtin_versions() :: [String.t()]
  def builtin_versions, do: Enum.map(builtin_profiles(), & &1.version)

  @doc "Returns the untouched `_meta` map or an empty map."
  @spec request_meta(Envelope.t()) :: map()
  def request_meta(%Envelope{params: params}) do
    case Map.get(params, "_meta", %{}) do
      metadata when is_map(metadata) -> metadata
      _invalid -> %{}
    end
  end
end
