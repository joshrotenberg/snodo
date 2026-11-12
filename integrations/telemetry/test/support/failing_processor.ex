defmodule SnodoTest.Telemetry.FailingProcessor do
  @moduledoc false

  # A span processor, configured before the exporting simple processor, that
  # fails in on_start or on_end while a test sets its mode. The mode is a
  # persistent term because the SDK calls processors in the process that
  # starts or ends the span.
  #
  # It implements the :otel_span_processor callbacks without declaring the
  # behaviour: the SDK is a test-only dependency outside the Dialyzer PLT, and
  # it looks the callbacks up at runtime.

  @type mode :: :off | :raise_on_start | :raise_on_end | :exit_on_end

  @spec set_mode(mode()) :: :ok
  def set_mode(mode), do: :persistent_term.put(__MODULE__, mode)

  def on_start(_context, span, _config) do
    if mode() == :raise_on_start, do: raise("processor failure on start")
    span
  end

  def on_end(_span, _config) do
    case mode() do
      :raise_on_end -> raise "processor failure on end"
      :exit_on_end -> exit(:processor_down)
      _other -> true
    end
  end

  def force_flush(_config), do: :ok

  defp mode, do: :persistent_term.get(__MODULE__, :off)
end
