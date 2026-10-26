defmodule Snodo.Transport.Plug.Stream do
  @moduledoc false
  use GenServer

  alias Plug.Conn
  alias Snodo.Server.Executor
  alias Snodo.Subscription

  def open(response, owner, lease, slot) do
    case GenServer.start(__MODULE__, {response.subscription, owner, lease, slot}) do
      {:ok, stream} -> {:stream, response, stream}
      {:error, {:shutdown, reason}} -> {:error, reason}
    end
  end

  def serve(conn, response, stream, keepalive_ms) do
    monitor = Process.monitor(stream)

    try do
      conn = open_response(conn, response)

      case Subscription.acknowledgement(response.subscription) do
        {:ok, message} ->
          case chunk(conn, message) do
            {:ok, conn} ->
              GenServer.cast(stream, :continue)
              loop(conn, stream, monitor, response.subscription, keepalive_ms)

            {:error, _reason} ->
              conn
          end

        {:error, _reason} ->
          conn
      end
    after
      Process.demonitor(monitor, [:flush])
      stop(stream, :disconnected)
    end
  end

  # A request that waited past the disconnect probe already has an open event
  # stream with the same status and content type; keep writing to it.
  defp open_response(%Conn{state: :chunked} = conn, _response), do: conn

  defp open_response(conn, response),
    do: conn |> Conn.merge_resp_headers(response.headers) |> Conn.send_chunked(response.status)

  @impl true
  def init({subscription, owner, lease, {executor, pool, limit}}) do
    case acquire_slot(executor, pool, limit) do
      {:ok, executor_pid} ->
        executor_monitor = Process.monitor(executor_pid)
        lease_monitor = Process.monitor(lease)
        {worker, worker_monitor} = Subscription.start_worker(subscription, self())

        {:ok,
         %{
           subscription: subscription,
           owner: owner,
           lease: lease,
           executor_monitor: executor_monitor,
           lease_monitor: lease_monitor,
           worker: worker,
           worker_monitor: worker_monitor,
           close_reason: :disconnected
         }}

      {:error, :exhausted} ->
        :ok = Subscription.close(subscription, {:error, :overloaded})
        {:stop, {:shutdown, :exhausted}}

      {:error, :unavailable} ->
        :ok = Subscription.close(subscription, {:error, :executor_unavailable})
        {:stop, {:shutdown, :unavailable}}
    end
  end

  @impl true
  def handle_cast(:continue, state) do
    :ok = Subscription.continue(state.worker)
    {:noreply, state}
  end

  @impl true
  def handle_call({:stop, reason}, _from, state),
    do: {:stop, :normal, :ok, %{state | close_reason: reason}}

  @impl true
  def handle_info({:mcp_subscription, worker, outcome}, %{worker: worker} = state) do
    send(state.owner, {:mcp_plug_stream, self(), outcome})
    {:noreply, state}
  end

  def handle_info({:DOWN, monitor, :process, _pid, _reason}, %{lease_monitor: monitor} = state) do
    {:stop, :normal, state}
  end

  def handle_info({:DOWN, monitor, :process, _pid, _reason}, %{executor_monitor: monitor} = state) do
    {:stop, :normal, %{state | close_reason: {:error, :executor_unavailable}}}
  end

  def handle_info({:DOWN, monitor, :process, _pid, reason}, %{worker_monitor: monitor} = state) do
    send(state.owner, {:mcp_plug_stream, self(), {:error, reason}})
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    :ok = Subscription.close(state.subscription, state.close_reason)
    :ok = Subscription.stop_worker(state.worker, state.worker_monitor)
  end

  # When the parent is known, only its shutdown exit ends the stream; exits
  # from other linked processes are ignored. When it is not known (no
  # recorded ancestors, or a registered parent name that no longer
  # resolves), any shutdown exit from any linked process ends the stream,
  # because a pid that never matches would silently ignore the shutdown.
  # ThousandIsland starts the handler through DynamicSupervisor.start_child/2
  # (connection.ex), so the first ancestor is that supervisor, which also
  # sends the shutdown exit. This is verified over HTTP/1.x by the Bandit
  # shutdown test; HTTP/2 stream process layout is not tested, and if the
  # first ancestor differs there, the shutdown waits for the supervisor's
  # timeout as it did before this change.
  defp parent do
    case Process.get(:"$ancestors") do
      [parent | _] when is_pid(parent) -> parent
      [parent | _] when is_atom(parent) -> Process.whereis(parent) || :any
      _unknown -> :any
    end
  end

  defp loop(conn, stream, monitor, subscription, keepalive_ms) do
    parent = parent()

    receive do
      {:mcp_plug_stream, ^stream, outcome} ->
        stream_outcome(outcome, conn, stream, monitor, subscription, keepalive_ms)

      {:DOWN, ^monitor, :process, ^stream, reason} ->
        final_chunk(conn, Subscription.failure(subscription, reason))

      # The handler traps exits, so a server shutdown arrives as a message.
      # Without this clause the stream would hold shutdown until the
      # connection supervisor's timeout kills it.
      {:EXIT, from, reason}
      when (parent == :any or from == parent) and
             (reason == :shutdown or
                (is_tuple(reason) and tuple_size(reason) == 2 and elem(reason, 0) == :shutdown)) ->
        finish(conn, stream, subscription, :complete)
    after
      keepalive_ms ->
        case Conn.chunk(conn, ": keepalive\r\n\r\n") do
          {:ok, conn} -> loop(conn, stream, monitor, subscription, keepalive_ms)
          {:error, _reason} -> conn
        end
    end
  end

  defp stream_outcome({:ok, event}, conn, stream, monitor, subscription, keepalive_ms) do
    case Subscription.notification(subscription, event) do
      {:ok, message} ->
        continue(conn, stream, monitor, subscription, keepalive_ms, message)

      :drop ->
        GenServer.cast(stream, :continue)
        loop(conn, stream, monitor, subscription, keepalive_ms)

      {:error, reason} ->
        finish(conn, stream, subscription, {:error, reason})
    end
  end

  defp stream_outcome(:closed, conn, stream, _monitor, subscription, _keepalive_ms),
    do: finish(conn, stream, subscription, :complete)

  defp stream_outcome({:error, reason}, conn, stream, _monitor, subscription, _keepalive_ms),
    do: finish(conn, stream, subscription, {:error, reason})

  defp continue(conn, stream, monitor, subscription, keepalive_ms, message) do
    case chunk(conn, message) do
      {:ok, conn} ->
        GenServer.cast(stream, :continue)
        loop(conn, stream, monitor, subscription, keepalive_ms)

      {:error, _reason} ->
        conn
    end
  end

  defp finish(conn, stream, subscription, reason) do
    message =
      case reason do
        :complete ->
          case Subscription.completion(subscription) do
            {:ok, completion} -> completion
            {:error, error} -> Subscription.failure(subscription, error)
          end

        {:error, error} ->
          Subscription.failure(subscription, error)
      end

    stop(stream, reason)
    final_chunk(conn, message)
  end

  defp final_chunk(conn, message) do
    case chunk(conn, message) do
      {:ok, conn} -> conn
      {:error, _reason} -> conn
    end
  end

  defp chunk(conn, message),
    do: Conn.chunk(conn, ["event: message\r\ndata: ", JSON.encode!(message), "\r\n\r\n"])

  defp acquire_slot(executor, pool, limit) do
    Executor.acquire_slot_with_executor(executor, pool, limit)
  catch
    :exit, _reason -> {:error, :unavailable}
  end

  defp stop(stream, reason) do
    GenServer.call(stream, {:stop, reason})
  catch
    :exit, _reason -> :ok
  end
end
