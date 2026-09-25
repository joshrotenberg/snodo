defmodule Snodo.Transport.Plug.Stream do
  @moduledoc false
  use GenServer

  alias Plug.Conn
  alias Snodo.Subscription

  def open(response, owner, lease) do
    {:ok, stream} = GenServer.start(__MODULE__, {response.subscription, owner, lease})
    {:stream, response, stream}
  end

  def serve(conn, response, stream, keepalive_ms) do
    monitor = Process.monitor(stream)

    try do
      conn =
        conn |> Conn.merge_resp_headers(response.headers) |> Conn.send_chunked(response.status)

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

  @impl true
  def init({subscription, owner, lease}) do
    lease_monitor = Process.monitor(lease)
    {worker, worker_monitor} = Subscription.start_worker(subscription, self())

    {:ok,
     %{
       subscription: subscription,
       owner: owner,
       lease: lease,
       lease_monitor: lease_monitor,
       worker: worker,
       worker_monitor: worker_monitor,
       close_reason: :disconnected
     }}
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

  def handle_info({:DOWN, monitor, :process, _pid, reason}, %{worker_monitor: monitor} = state) do
    send(state.owner, {:mcp_plug_stream, self(), {:error, reason}})
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    :ok = Subscription.stop_worker(state.worker, state.worker_monitor)
    :ok = Subscription.close(state.subscription, state.close_reason)
  end

  defp loop(conn, stream, monitor, subscription, keepalive_ms) do
    receive do
      {:mcp_plug_stream, ^stream, {:ok, event}} ->
        case Subscription.notification(subscription, event) do
          {:ok, message} ->
            continue(conn, stream, monitor, subscription, keepalive_ms, message)

          :drop ->
            GenServer.cast(stream, :continue)
            loop(conn, stream, monitor, subscription, keepalive_ms)

          {:error, reason} ->
            finish(conn, stream, subscription, {:error, reason})
        end

      {:mcp_plug_stream, ^stream, :closed} ->
        finish(conn, stream, subscription, :complete)

      {:mcp_plug_stream, ^stream, {:error, reason}} ->
        finish(conn, stream, subscription, {:error, reason})

      {:DOWN, ^monitor, :process, ^stream, reason} ->
        final_chunk(conn, Subscription.failure(subscription, reason))
    after
      keepalive_ms ->
        case Conn.chunk(conn, ": keepalive\r\n\r\n") do
          {:ok, conn} -> loop(conn, stream, monitor, subscription, keepalive_ms)
          {:error, _reason} -> conn
        end
    end
  end

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

  defp stop(stream, reason) do
    GenServer.call(stream, {:stop, reason})
  catch
    :exit, _reason -> :ok
  end
end
