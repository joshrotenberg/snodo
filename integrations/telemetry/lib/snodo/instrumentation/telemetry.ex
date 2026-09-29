defmodule Snodo.Instrumentation.Telemetry do
  @moduledoc """
  A `Snodo.Instrumentation` sink that forwards every event to `:telemetry`.

  Install the separate `snodo_telemetry` package and pass this module wherever
  a sink is accepted:

      runtime = MyServer.runtime(instrumentation: Snodo.Instrumentation.Telemetry)

  Each event reaches `:telemetry.execute/3` under the name, with the
  measurements, and with the metadata the sink received. The instrumentation
  guide lists them. The sink takes no options.

  ## Span semantics

  `Snodo.Instrumentation` emits `:start`, `:stop`, and `:exception` events for
  a server dispatch and for a Tasks runner job. This sink gives the events of
  one span a shared `telemetry_span_context` reference in their metadata, as
  `:telemetry.span/3` does, so a handler can pair a `:stop` or `:exception`
  with its `:start`. Measurements are forwarded unchanged: `system_time` on
  `:start`, and `duration` in native time units on `:stop` and `:exception`.

  The reference is created on `:start` and kept in the emitting process until
  the matching `:stop` or `:exception`. A dispatch runs synchronously in the
  dispatching process, so nested dispatches form a stack. Runner jobs
  interleave in the runner process, so their references are keyed by
  `task_id`. A `:stop` or `:exception` with no recorded `:start` gets a fresh
  reference. Events that are not part of a span, such as the subscription
  events and the store transition, are forwarded without the key.
  """

  @behaviour Snodo.Instrumentation

  @impl Snodo.Instrumentation
  @spec handle_event([atom(), ...], map(), map(), term()) :: :ok
  def handle_event(event_name, measurements, metadata, _options) do
    :telemetry.execute(event_name, measurements, span_metadata(event_name, metadata))
  end

  defp span_metadata(event_name, metadata) do
    case List.pop_at(event_name, -1) do
      {:start, prefix} ->
        Map.put(metadata, :telemetry_span_context, push_context(prefix, metadata))

      {finish, prefix} when finish in [:stop, :exception] ->
        Map.put(metadata, :telemetry_span_context, pop_context(prefix, metadata))

      _point_event ->
        metadata
    end
  end

  defp push_context(prefix, metadata) do
    key = span_key(prefix, metadata)
    context = make_ref()
    _previous = Process.put(key, [context | Process.get(key, [])])
    context
  end

  defp pop_context(prefix, metadata) do
    key = span_key(prefix, metadata)

    case Process.get(key, []) do
      [context] ->
        _previous = Process.delete(key)
        context

      [context | rest] ->
        _previous = Process.put(key, rest)
        context

      [] ->
        make_ref()
    end
  end

  # Runner job events for different tasks interleave in the runner process;
  # dispatch events for one process nest.
  defp span_key(prefix, %{task_id: task_id}), do: {__MODULE__, prefix, task_id}
  defp span_key(prefix, _metadata), do: {__MODULE__, prefix}
end
