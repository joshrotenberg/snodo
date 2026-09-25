defmodule Snodo.Instrumentation do
  @moduledoc """
  Optional, dependency-free lifecycle instrumentation.

  Instrumentation sinks receive telemetry-shaped event names, numeric
  measurements, and deliberately bounded metadata. Sink failures are isolated:
  observability cannot change protocol, transport, or Tasks behavior.

  A sink may bridge events to `:telemetry`, OpenTelemetry, Logger, a metrics
  process, or a test collector without making any of those systems a framework
  dependency.
  """

  defmodule Config do
    @moduledoc "A normalized instrumentation sink: the sink module and its options."

    @enforce_keys [:module]
    defstruct [:module, :options]

    @type t :: %__MODULE__{module: module(), options: term()}
  end

  @type event_name :: [atom()]
  @type config :: module() | {module(), term()} | Config.t()

  @callback handle_event(
              event_name(),
              measurements :: map(),
              metadata :: map(),
              options :: term()
            ) :: term()

  @doc "Normalizes and validates an optional sink configuration."
  @spec normalize!(config() | nil) :: Config.t() | nil
  def normalize!(nil), do: nil
  def normalize!(%Config{} = config), do: validate!(config)
  def normalize!(module) when is_atom(module), do: validate!(%Config{module: module, options: []})

  def normalize!({module, options}) when is_atom(module) do
    validate!(%Config{module: module, options: options})
  end

  def normalize!(_invalid) do
    raise ArgumentError, "instrumentation must be a module or {module, options} pair"
  end

  @doc "Emits one event and isolates every sink failure."
  @spec emit(Config.t() | nil, event_name(), map(), map()) :: :ok
  def emit(nil, _event_name, _measurements, _metadata), do: :ok

  def emit(
        %Config{module: module, options: options},
        event_name,
        measurements,
        metadata
      )
      when is_list(event_name) and event_name != [] and is_map(measurements) and
             is_map(metadata) do
    _ignored = module.handle_event(event_name, measurements, metadata, options)
    :ok
  rescue
    _exception -> :ok
  catch
    _kind, _reason -> :ok
  end

  @doc false
  @spec span(Config.t() | nil, event_name(), map(), (-> result), (result -> map())) :: result
        when result: term()
  def span(config, prefix, metadata, operation, finish_metadata)
      when is_list(prefix) and is_map(metadata) and is_function(operation, 0) and
             is_function(finish_metadata, 1) do
    started_at = System.monotonic_time()

    emit(config, prefix ++ [:start], %{system_time: System.system_time()}, metadata)

    try do
      result = operation.()
      measurements = %{duration: System.monotonic_time() - started_at}
      emit(config, prefix ++ [:stop], measurements, Map.merge(metadata, finish_metadata.(result)))
      result
    rescue
      exception ->
        emit_exception(config, prefix, metadata, started_at, :error, exception.__struct__)
        reraise exception, __STACKTRACE__
    catch
      kind, reason ->
        emit_exception(config, prefix, metadata, started_at, kind, classify_caught(reason))
        :erlang.raise(kind, reason, __STACKTRACE__)
    end
  end

  defp emit_exception(config, prefix, metadata, started_at, kind, reason_class) do
    measurements = %{duration: System.monotonic_time() - started_at}
    exception_metadata = Map.merge(metadata, %{kind: kind, reason_class: reason_class})

    emit(config, prefix ++ [:exception], measurements, exception_metadata)
  end

  defp classify_caught(reason) when is_atom(reason), do: reason
  defp classify_caught(_reason), do: :non_atom

  defp validate!(%Config{module: module} = config) do
    case Code.ensure_loaded(module) do
      {:module, ^module} ->
        unless function_exported?(module, :handle_event, 4) do
          raise ArgumentError,
                "instrumentation sink #{inspect(module)} must export handle_event/4"
        end

        config

      _not_loaded ->
        raise ArgumentError, "instrumentation sink #{inspect(module)} could not be loaded"
    end
  end
end
