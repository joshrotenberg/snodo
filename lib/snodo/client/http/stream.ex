defmodule Snodo.Client.HTTP.Stream do
  @moduledoc false
  # One `subscriptions/listen` stream of an HTTP client. The process owns the
  # subscription's buffer and control messages; a linked reader process holds
  # the connection and blocks in `recv`, feeding each decoded message here.
  # Closing the socket from this process ends the reader's read, which is how
  # `close/1` and the owner's exit cancel the stream on the server.

  use GenServer

  alias Snodo.Client.HTTP
  alias Snodo.Client.Response
  alias Snodo.Client.Subscription.Buffer
  alias Snodo.Client.Transport

  @acknowledgement "notifications/subscriptions/acknowledged"

  # `{:challenge, status, challenge}` is a 401 or 403 for the transport's
  # token provider; the process has stopped and the caller may open again.
  @doc false
  @spec open(map(), [{String.t(), String.t()}], map(), keyword()) ::
          {:ok, map(), pid()}
          | {:error, Snodo.Error.t()}
          | {:challenge, 401 | 403, Snodo.Client.Challenge.t() | nil}
  def open(http, headers, message, opts) do
    {:ok, pid} = GenServer.start(__MODULE__, {http, headers, message, opts})

    case GenServer.call(pid, :open, :infinity) do
      {:ok, accepted} -> {:ok, accepted, pid}
      {:error, error} -> {:error, error}
      {:challenge, _status, _challenge} = challenge -> challenge
    end
  end

  @impl GenServer
  def init({http, headers, message, opts}) do
    _previous = Process.flag(:trap_exit, true)
    owner = Keyword.fetch!(opts, :owner)
    ref = Keyword.fetch!(opts, :ref)

    {:ok,
     %{
       http: http,
       headers: headers,
       message: message,
       timeout: Keyword.fetch!(opts, :timeout),
       ref: ref,
       owner_monitor: Process.monitor(owner),
       buffer: Buffer.new(owner, ref, opts),
       caller: nil,
       reader: nil,
       socket: nil
     }}
  end

  @impl GenServer
  def handle_call(:open, from, %{reader: nil} = state) do
    stream = self()
    %{http: http, headers: headers, message: message, timeout: timeout} = state
    reader = spawn_link(fn -> HTTP.read_stream(stream, http, headers, message, timeout) end)
    {:noreply, %{state | caller: from, reader: reader}}
  end

  def handle_call({:mcp_client_close, ref}, _from, %{ref: ref} = state) do
    {:stop, :normal, :ok, disconnect(state)}
  end

  def handle_call({:mcp_client_close, _other}, _from, state), do: {:reply, :ok, state}

  @impl GenServer
  def handle_info({:mcp_stream_socket, socket}, state), do: {:noreply, %{state | socket: socket}}

  def handle_info({:mcp_stream_message, message}, state), do: handle_message(state, message)

  # A challenge is read from the response head, before any event, so the
  # opener is still waiting for it.
  def handle_info({:mcp_stream_end, {:challenge, _status, _challenge} = challenge}, state)
      when state.caller != nil do
    {:stop, :normal, reply(%{state | reader: nil, socket: nil}, challenge)}
  end

  def handle_info({:mcp_stream_end, outcome}, state) do
    state = %{state | reader: nil, socket: nil}

    cond do
      state.caller != nil ->
        {:stop, :normal, reply(state, {:error, ended_before_acknowledgement(outcome)})}

      Buffer.terminal?(state.buffer) ->
        {:noreply, state}

      true ->
        finish(state, stream_end_reason(outcome))
    end
  end

  def handle_info({:mcp_client_demand, ref, n}, %{ref: ref} = state) do
    state = %{state | buffer: Buffer.demand(state.buffer, n)}
    if Buffer.done?(state.buffer), do: {:stop, :normal, state}, else: {:noreply, state}
  end

  def handle_info({:DOWN, monitor, :process, _owner, _reason}, %{owner_monitor: monitor} = state) do
    {:stop, :normal, disconnect(state)}
  end

  def handle_info({:EXIT, reader, :normal}, %{reader: reader} = state),
    do: {:noreply, %{state | reader: nil}}

  def handle_info({:EXIT, reader, reason}, %{reader: reader} = state) do
    error = Transport.connection_error("The HTTP stream reader exited", reason)
    handle_info({:mcp_stream_end, {:error, error}}, state)
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl GenServer
  def terminate(_reason, state) do
    _state = disconnect(state)
    :ok
  end

  defp handle_message(state, %{"method" => @acknowledgement, "params" => params} = message)
       when not is_nil(state.caller) do
    case params do
      %{"notifications" => accepted} when is_map(accepted) ->
        {:noreply, reply(state, {:ok, accepted})}

      _invalid ->
        error =
          Transport.connection_error(
            "The server sent an invalid subscription acknowledgement",
            message
          )

        {:stop, :normal, disconnect(reply(state, {:error, error}))}
    end
  end

  defp handle_message(state, %{"method" => @acknowledgement}), do: {:noreply, state}

  defp handle_message(state, %{"method" => method, "params" => params} = message)
       when is_binary(method) and is_map(params) and not is_map_key(message, "id") do
    {:noreply, %{state | buffer: Buffer.push(state.buffer, {:notification, method, params})}}
  end

  defp handle_message(%{message: %{"id" => id}} = state, %{"id" => id} = response)
       when not is_map_key(response, "method") do
    if state.caller do
      {:stop, :normal, disconnect(reply(state, {:error, before_acknowledgement(response)}))}
    else
      finish(disconnect(state), Response.terminal(response))
    end
  end

  defp handle_message(state, _other), do: {:noreply, state}

  # The connection is gone; the process stays until the owner has taken the
  # queued events and the terminal message.
  defp finish(state, close_reason) do
    state = %{state | buffer: Buffer.close(state.buffer, close_reason)}
    if Buffer.done?(state.buffer), do: {:stop, :normal, state}, else: {:noreply, state}
  end

  defp reply(%{caller: from} = state, response) do
    GenServer.reply(from, response)
    %{state | caller: nil}
  end

  defp disconnect(%{reader: reader, socket: socket} = state) do
    if reader do
      Process.unlink(reader)
      Process.exit(reader, :kill)
    end

    if socket, do: HTTP.close_socket(socket)
    %{state | reader: nil, socket: nil}
  end

  defp stream_end_reason({:response, response}), do: Response.terminal(response)
  defp stream_end_reason({:error, error}), do: {:error, error}

  defp stream_end_reason(:ended),
    do: {:error, Transport.connection_error("The HTTP connection closed", :closed)}

  defp ended_before_acknowledgement({:response, response}), do: before_acknowledgement(response)
  defp ended_before_acknowledgement({:error, error}), do: error
  defp ended_before_acknowledgement(:ended), do: ended_early(:ended)

  defp before_acknowledgement(response) do
    case Response.terminal(response) do
      {:error, error} -> error
      :complete -> ended_early(response)
    end
  end

  defp ended_early(cause) do
    Transport.connection_error("The server ended the subscription before acknowledging it", cause)
  end
end
