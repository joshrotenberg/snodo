defmodule Snodo.Extension do
  @moduledoc """
  Behaviour for explicitly installed, exact-versioned out-of-tree extensions.

  Extension-owned routes deliberately cover top-level client-to-server
  requests only. An optional `around_dispatch/4` callback can wrap core
  protocol execution for an advertised, exact-version-compatible extension.
  Its continuation accepts a request context, allowing middleware to pass a
  derived immutable context to the next extension and ultimately the core
  handler. Middleware also runs before peer negotiation succeeds, and can
  inspect `Snodo.Context.extensions` to distinguish negotiated requests.

  An optional `missing_capability_error/2` callback can customize the error for
  an extension-owned method when the server advertised the extension but the
  client did not. Extensions without the callback retain method-not-found
  behavior.

  An optional `transport_policy/2` callback can adapt the selected protocol's
  transport policy for an extension-owned route. The callback is considered
  only for an exact-version-compatible route advertised by the server;
  installed-only extensions cannot affect transport admission.

  Extensions may optionally contribute fields to `subscriptions/listen` with
  `subscription_filter/2` and shape matching source events with
  `shape_subscription_event/3`. The framework invokes these callbacks only for
  an installed, advertised, exact-version-compatible extension and retains
  per-extension filter ownership through the stream lifecycle.

  Other outbound methods and MRTR-embedded operations require additional
  routing infrastructure and cannot be advertised as extension-owned routes
  through this behaviour yet.
  """

  alias Snodo.Context
  alias Snodo.Error
  alias Snodo.Extension.Method
  alias Snodo.Result
  alias Snodo.Transport.Policy

  @type dispatch_result :: {:ok, Result.t()} | {:error, Error.t()}
  @type continuation :: (Context.t() -> dispatch_result())

  @callback id() :: String.t()
  @callback methods() :: [Method.t()]
  @callback negotiate(client_settings :: map(), server_settings :: map()) ::
              {:ok, map()} | :not_negotiated | {:error, Error.t()}
  @callback validate_operation(operation :: term(), params :: map(), Context.t()) ::
              :ok | {:error, Error.t()}
  @callback dispatch(operation :: term(), params :: map(), Context.t()) ::
              dispatch_result()
  @callback shape_result(operation :: term(), Result.t(), Context.t()) :: map()
  @callback shape_error(Error.t(), Context.t()) :: map()
  @callback around_dispatch(
              operation :: term(),
              params :: map(),
              Context.t(),
              continuation()
            ) :: dispatch_result()
  @callback missing_capability_error(method :: String.t(), Context.t()) ::
              Error.t() | :method_not_found
  @callback transport_policy(Snodo.Envelope.t(), Policy.t()) :: Policy.t()
  @callback subscription_filter(requested_filter :: map(), Context.t()) ::
              {:ok, accepted_filter :: map()} | {:error, Error.t()}
  @callback shape_subscription_event(
              Snodo.Subscription.Event.t(),
              Snodo.Envelope.id(),
              Context.t()
            ) :: map()

  @optional_callbacks around_dispatch: 4,
                      missing_capability_error: 2,
                      transport_policy: 2,
                      subscription_filter: 2,
                      shape_subscription_event: 3
end
