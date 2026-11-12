# The OpenTelemetry SDK is a test-only dependency with runtime: false, so it
# is configured and started here: a simple processor, whose exporter each
# OpenTelemetry test points at itself, and no default exporter. Mix has
# already loaded the application, so only its environment is set here.
Application.put_env(:opentelemetry, :traces_exporter, :none)
Application.put_env(:opentelemetry, :processors, [{:otel_simple_processor, %{}}])
{:ok, _started} = Application.ensure_all_started(:opentelemetry)

ExUnit.start(assert_receive_timeout: 1_000)
