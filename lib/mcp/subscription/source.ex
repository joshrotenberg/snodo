defmodule MCP.Subscription.Source do
  @moduledoc """
  Application-owned event source boundary for `subscriptions/listen`.

  Sources open a lightweight handle, pull one event at a time, and close that
  handle when the request is cancelled, disconnected, completed, or fails.
  `next/2` may block; the framework always invokes it in a dedicated worker and
  never requests another event until the previous event has been written.
  `open/3` must acknowledge only a subset of its requested filter. `close/3`
  should return promptly and release any application resources associated with
  a blocked pull.
  """

  alias MCP.Context
  alias MCP.Error
  alias MCP.Subscription.Event

  defmodule Config do
    @moduledoc false

    @enforce_keys [:module]
    defstruct [:module, :options]

    @type t :: %__MODULE__{module: module(), options: term()}
  end

  @type config :: module() | {module(), term()} | Config.t()
  @type close_reason :: :cancelled | :disconnected | :complete | {:error, term()} | term()

  @callback open(requested_filter :: map(), Context.t(), options :: term()) ::
              {:ok, accepted_filter :: map(), handle :: term()}
              | {:error, Error.t() | term()}
  @callback next(handle :: term(), options :: term()) ::
              {:ok, Event.t()} | :closed | {:error, term()}
  @callback close(handle :: term(), close_reason(), options :: term()) :: :ok | term()

  @doc false
  @spec normalize!(config() | nil) :: Config.t() | nil
  def normalize!(nil), do: nil
  def normalize!(%Config{} = config), do: validate!(config)
  def normalize!(module) when is_atom(module), do: validate!(%Config{module: module, options: []})

  def normalize!({module, options}) when is_atom(module) do
    validate!(%Config{module: module, options: options})
  end

  def normalize!(_invalid) do
    raise ArgumentError, "subscription_source must be a module or {module, options} pair"
  end

  defp validate!(%Config{module: module} = config) do
    case Code.ensure_loaded(module) do
      {:module, ^module} ->
        unless exports_callbacks?(module) do
          raise ArgumentError,
                "subscription_source #{inspect(module)} must export open/3, next/2, and close/3"
        end

        config

      _not_loaded ->
        raise ArgumentError, "subscription_source #{inspect(module)} could not be loaded"
    end
  end

  defp exports_callbacks?(module) do
    Enum.all?([open: 3, next: 2, close: 3], fn {name, arity} ->
      function_exported?(module, name, arity)
    end)
  end
end
