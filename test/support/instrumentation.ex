defmodule SnodoTest.TestInstrumentationSink do
  @moduledoc false

  @behaviour Snodo.Instrumentation

  @impl true
  def handle_event(event_name, measurements, metadata, owner) when is_pid(owner) do
    send(owner, {:instrumentation, event_name, measurements, metadata})
    :ok
  end
end

defmodule SnodoTest.RaisingInstrumentationSink do
  @moduledoc false

  @behaviour Snodo.Instrumentation

  # Raising is the point: a sink fault must not reach protocol behavior.
  @spec handle_event(term(), map(), map(), term()) :: no_return()
  @impl true
  def handle_event(_event_name, _measurements, _metadata, _options) do
    raise "instrumentation failure"
  end
end
