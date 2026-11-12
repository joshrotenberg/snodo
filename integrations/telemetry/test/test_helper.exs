# The OpenTelemetry SDK is a test-only dependency with runtime: false, so it
# is configured and started here: a simple processor, whose exporter each
# OpenTelemetry test points at itself, a processor that tests can make fail,
# and no default exporter. Mix has already loaded the application, so only
# its environment is set here.
Application.put_env(:opentelemetry, :traces_exporter, :none)

Application.put_env(:opentelemetry, :processors, [
  # The SDK stops calling on_end processors after one that does not return
  # true, so the failing processor goes first to be reached at all.
  {SnodoTest.Telemetry.FailingProcessor, %{}},
  # The SDK names a lone simple processor :global itself; with two processors
  # the name is set here, so :otel_simple_processor.set_exporter/2 finds it.
  {:otel_simple_processor, %{name: :global}}
])

{:ok, _started} = Application.ensure_all_started(:opentelemetry)

ExUnit.start(assert_receive_timeout: 1_000)
