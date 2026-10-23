defmodule Snodo.Client.Direct do
  @moduledoc """
  In-process transport for `Snodo.Client.direct/2`.

  Each request runs `Snodo.Server.dispatch/3` in the calling process with a
  `:direct` transport context, so `:timeout` does not apply. The context
  carries the dialect's version as the `mcp-protocol-version` request header,
  which is how the initialize-era dialects select themselves after
  `initialize`.

  A request with `progress:` runs the dispatch in a linked task instead, with
  a progress sink owned by the calling process. The caller acknowledges each
  of the handler's `Snodo.Progress.report/3` calls after passing the
  notification to the progress function, as a server transport does after
  writing it. A client with `on_log:` runs every request that way too, and
  passes each `Snodo.Logging.log/4` message to the log function. On an
  initialize-era version there is no connection to hold a level, so
  `logging/setLevel` has no lasting effect and the runtime's `:log_level`
  applies.

  A `subscriptions/listen` request opened with `Snodo.Client.listen/3` is
  dispatched in a process of its own, which then serves the server-side
  subscription as a server transport would: it owns the source worker, shapes
  each event through `Snodo.Subscription`, and closes the source when the
  stream ends. Closing the subscription closes the source with
  `{:cancelled, "Closed by the client"}`; the owner's exit closes it with
  `{:disconnected, {:owner_down, reason}}`.
  """

  @behaviour Snodo.Client.Transport

  alias Snodo.Client.Direct.Stream, as: SubscriptionStream
  alias Snodo.Progress
  alias Snodo.Server
  alias Snodo.Server.Runtime
  alias Snodo.Transport.Context, as: TransportContext

  @type state :: %{runtime: Runtime.t(), auth: term()}

  @impl true
  def connect(%Runtime{} = runtime, opts) do
    {:ok, %{runtime: runtime, auth: Keyword.get(opts, :auth)}}
  end

  @impl true
  def request(%{runtime: runtime} = state, message, opts) do
    transport = transport_context(state, Keyword.fetch!(opts, :dialect))

    case {Keyword.get(opts, :on_progress), Keyword.get(opts, :on_log)} do
      {nil, nil} ->
        # Snodo.Client sends subscriptions/listen through listen/3, so dispatch
        # always returns a response map here.
        {:ok, response} = Server.dispatch(runtime, message, transport)
        {:ok, response}

      callbacks ->
        dispatch_with_notifications(runtime, message, transport, callbacks)
    end
  end

  # A notification has no response; the initialize-era handshake sends one.
  # Anything else from the dispatch is reported rather than raised.
  @impl true
  def notify(%{runtime: runtime} = state, message, opts) do
    transport = transport_context(state, Keyword.fetch!(opts, :dialect))

    case Server.dispatch(runtime, message, transport) do
      {:ok, nil} ->
        :ok

      other ->
        {:error,
         Snodo.Client.Transport.connection_error("The server answered a notification", other)}
    end
  end

  @impl true
  def listen(%{runtime: runtime} = state, message, opts) do
    transport = transport_context(state, Keyword.fetch!(opts, :dialect))
    SubscriptionStream.open(runtime, message, transport, opts)
  end

  @impl true
  def close(_state), do: :ok

  defp transport_context(state, dialect) do
    %TransportContext{
      transport: :direct,
      request_headers: %{"mcp-protocol-version" => dialect.version()},
      metadata: if(is_nil(state.auth), do: %{}, else: %{auth: state.auth})
    }
  end

  defp dispatch_with_notifications(runtime, message, transport, callbacks) do
    sink = Progress.sink(self())
    transport = put_in(transport.metadata[:progress_sink], sink)

    task =
      Task.async(fn ->
        try do
          Server.dispatch(runtime, message, transport)
        after
          Progress.close(sink)
        end
      end)

    try do
      await(task, Progress.state(sink), callbacks)
    after
      Progress.close(sink)
      _result = Task.shutdown(task, :brutal_kill)
    end
  end

  defp await(%Task{ref: ref} = task, progress, callbacks) do
    reference = progress.sink.reference

    receive do
      {^ref, {:ok, response}} ->
        {:ok, response}

      {:"$gen_call", from, {:mcp_progress, ^reference, report}} ->
        case Progress.accept(progress, from, report) do
          {:ok, notification, progress} ->
            notify_caller(notification, callbacks)
            :ok = Progress.reply(from, report, :ok)
            await(task, progress, callbacks)

          {:error, reason} ->
            :ok = Progress.reply(from, report, {:error, reason})
            await(task, progress, callbacks)
        end

      {:DOWN, ^ref, :process, _pid, reason} ->
        exit(reason)
    end
  end

  defp notify_caller(%{"method" => "notifications/message", "params" => params}, {_, on_log}),
    do: if(on_log, do: on_log.(params))

  defp notify_caller(%{"params" => params}, {on_progress, _}),
    do: if(on_progress, do: on_progress.(params))
end
