defmodule Snodo.Client.Direct.Stream do
  @moduledoc false
  # One `subscriptions/listen` stream of an in-process client. The process
  # dispatches the request, then serves the server-side subscription the way
  # a server transport does: it owns the source worker, shapes each event
  # through `Snodo.Subscription`, and closes the source when the stream ends.
  # The shaped messages are read back as a remote transport would read them,
  # so the owner sees the same methods and params over every transport.

  use GenServer

  alias Snodo.Client.Response
  alias Snodo.Client.Subscription.Buffer
  alias Snodo.Client.Transport
  alias Snodo.Server
  alias Snodo.Subscription

  @cancelled_by_client {:cancelled, "Closed by the client"}

  @doc false
  @spec open(Snodo.Server.Runtime.t(), map(), Snodo.Transport.Context.t(), keyword()) ::
          {:ok, map(), pid()} | {:error, Snodo.Error.t()}
  def open(runtime, message, transport, opts) do
    {:ok, pid} = GenServer.start(__MODULE__, {runtime, message, transport, opts})

    case GenServer.call(pid, :open, :infinity) do
      {:ok, accepted} -> {:ok, accepted, pid}
      {:error, error} -> {:error, error}
    end
  end

  @impl GenServer
  def init({runtime, message, transport, opts}) do
    owner = Keyword.fetch!(opts, :owner)
    ref = Keyword.fetch!(opts, :ref)

    {:ok,
     %{
       runtime: runtime,
       message: message,
       transport: transport,
       ref: ref,
       owner_monitor: Process.monitor(owner),
       buffer: Buffer.new(owner, ref, opts),
       subscription: nil,
       worker: nil,
       monitor: nil
     }}
  end

  @impl GenServer
  def handle_call(:open, _from, %{subscription: nil} = state) do
    transport = %{
      state.transport
      | metadata: Map.put(state.transport.metadata, :subscription_owner, self())
    }

    case Server.dispatch(state.runtime, state.message, transport) do
      {:stream, %Subscription{} = subscription} ->
        start_stream(state, subscription)

      {:ok, response} when is_map(response) ->
        {:stop, :normal, {:error, before_acknowledgement(response)}, state}

      {:ok, nil} ->
        {:stop, :normal, {:error, Transport.connection_error("The server sent no response", nil)},
         state}
    end
  end

  def handle_call({:mcp_client_close, ref}, _from, %{ref: ref} = state) do
    {:stop, :normal, :ok, stop_stream(state, @cancelled_by_client)}
  end

  def handle_call({:mcp_client_close, _other}, _from, state), do: {:reply, :ok, state}

  @impl GenServer
  def handle_info({:mcp_client_demand, ref, n}, %{ref: ref} = state) do
    state = %{state | buffer: Buffer.demand(state.buffer, n)}
    if Buffer.done?(state.buffer), do: {:stop, :normal, state}, else: {:noreply, state}
  end

  def handle_info({:mcp_subscription, worker, outcome}, %{worker: worker} = state) do
    handle_outcome(state, outcome)
  end

  def handle_info({:DOWN, monitor, :process, _worker, reason}, %{monitor: monitor} = state) do
    close_reason = Response.terminal(Subscription.failure(state.subscription, reason))
    :ok = Subscription.close(state.subscription, {:error, reason})
    finish(%{state | worker: nil, monitor: nil}, close_reason)
  end

  def handle_info({:DOWN, monitor, :process, _owner, reason}, %{owner_monitor: monitor} = state) do
    {:stop, :normal, stop_stream(state, {:disconnected, {:owner_down, reason}})}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp start_stream(state, subscription) do
    case Subscription.acknowledgement(subscription) do
      {:ok, %{"params" => %{"notifications" => accepted}}} when is_map(accepted) ->
        {worker, monitor} = Subscription.start_worker(subscription, self())
        :ok = Subscription.continue(worker)
        state = %{state | subscription: subscription, worker: worker, monitor: monitor}
        {:reply, {:ok, accepted}, state}

      {:ok, acknowledgement} ->
        :ok = Subscription.close(subscription, {:error, :invalid_acknowledgement})

        {:stop, :normal,
         {:error,
          Transport.connection_error(
            "The server sent an invalid subscription acknowledgement",
            acknowledgement
          )}, state}

      {:error, error} ->
        :ok = Subscription.close(subscription, {:error, error})
        {:stop, :normal, {:error, error}, state}
    end
  end

  defp handle_outcome(state, {:ok, event}) do
    case Subscription.notification(state.subscription, event) do
      {:ok, %{"method" => method, "params" => params}} ->
        :ok = Subscription.continue(state.worker)
        {:noreply, %{state | buffer: Buffer.push(state.buffer, {:notification, method, params})}}

      {:ok, _notification_without_params} ->
        :ok = Subscription.continue(state.worker)
        {:noreply, state}

      :drop ->
        :ok = Subscription.continue(state.worker)
        {:noreply, state}

      {:error, error} ->
        close_reason = Response.terminal(Subscription.failure(state.subscription, error))
        finish(stop_stream(state, {:error, error}), close_reason)
    end
  end

  defp handle_outcome(state, :closed) do
    close_reason =
      case Subscription.completion(state.subscription) do
        {:ok, completion} -> Response.terminal(completion)
        {:error, error} -> Response.terminal(Subscription.failure(state.subscription, error))
      end

    finish(stop_stream(state, :complete), close_reason)
  end

  defp handle_outcome(state, {:error, reason}) do
    close_reason = Response.terminal(Subscription.failure(state.subscription, reason))
    finish(stop_stream(state, {:error, reason}), close_reason)
  end

  # The source is closed and the worker stopped; the process stays until the
  # owner has taken the queued events and the terminal message.
  defp finish(state, close_reason) do
    state = %{state | buffer: Buffer.close(state.buffer, close_reason)}
    if Buffer.done?(state.buffer), do: {:stop, :normal, state}, else: {:noreply, state}
  end

  defp stop_stream(%{subscription: nil} = state, _reason), do: state

  defp stop_stream(state, reason) do
    if Buffer.terminal?(state.buffer) do
      state
    else
      :ok = Subscription.close(state.subscription, reason)
      if state.worker, do: :ok = Subscription.stop_worker(state.worker, state.monitor)
      %{state | worker: nil, monitor: nil}
    end
  end

  defp before_acknowledgement(response) do
    case Response.terminal(response) do
      {:error, error} ->
        error

      :complete ->
        Transport.connection_error(
          "The server ended the subscription before acknowledging it",
          response
        )
    end
  end
end
