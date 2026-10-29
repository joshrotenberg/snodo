defmodule Snodo.Session.Exchange do
  @moduledoc false

  # Runs one client message on an initialize-era session. Transports call
  # dispatch/3 in place of Snodo.Server.dispatch/3 when the message's transport
  # context carries a session.
  #
  # An input_required result is answered here: each input request goes to the
  # client as a server-to-client request on the original request's response
  # stream, written by the transport process that owns the progress sink, and
  # the handler runs again with the answers as input responses. The request's
  # executor deadline covers every round, and cancelling the request kills the
  # worker waiting here, which the session notices.
  #
  # resources/subscribe and resources/unsubscribe change the session, so they
  # are admitted by the dialect and applied here rather than in the router.

  alias Snodo.Envelope
  alias Snodo.Error
  alias Snodo.Progress
  alias Snodo.Protocol.Inspector
  alias Snodo.Protocol.Registry
  alias Snodo.Router
  alias Snodo.Server
  alias Snodo.Server.Runtime
  alias Snodo.Session
  alias Snodo.Transport.Context, as: TransportContext

  @max_rounds 10
  @session_methods ["resources/subscribe", "resources/unsubscribe"]

  @doc false
  @spec max_rounds() :: pos_integer()
  def max_rounds, do: @max_rounds

  @spec dispatch(Runtime.t(), term(), TransportContext.t()) :: Server.dispatch_result()
  def dispatch(
        %Runtime{} = runtime,
        raw,
        %TransportContext{metadata: %{session: %Session{} = session}} = transport
      ) do
    result =
      case raw do
        %{"method" => method} when method in @session_methods ->
          session_operation(runtime, raw, transport, session)

        %{"method" => "notifications/cancelled"} ->
          cancel(runtime, raw, transport, session)
          Server.dispatch(runtime, raw, transport)

        _other ->
          run(runtime, raw, transport, session, 1)
      end

    record(result, raw, session)
    result
  end

  def dispatch(%Runtime{} = runtime, raw, %TransportContext{} = transport),
    do: Server.dispatch(runtime, raw, transport)

  defp run(runtime, raw, transport, session, round) do
    case Server.dispatch(runtime, raw, transport) do
      {:ok, %{"result" => %{"resultType" => "input_required"} = result}} ->
        continue(runtime, raw, transport, session, round, result)

      other ->
        other
    end
  end

  defp continue(runtime, raw, transport, _session, round, _result) when round >= @max_rounds do
    error =
      Error.internal("The handler still required input after #{@max_rounds} rounds")

    Server.reject(runtime, raw, transport, error)
  end

  defp continue(runtime, raw, transport, session, round, result) do
    case ask(session, transport, Map.get(result, "inputRequests", %{})) do
      {:ok, answers} ->
        metadata =
          transport.metadata
          |> Map.put(:input_responses, answers)
          |> Map.put(:request_state, Map.get(result, "requestState"))

        rebind_progress(metadata[:progress_sink])
        run(runtime, raw, %{transport | metadata: metadata}, session, round + 1)

      {:error, %Error{} = error} ->
        Server.reject(runtime, raw, transport, error)
    end
  end

  defp rebind_progress(%Progress.Sink{} = sink), do: Progress.rebind(sink)
  defp rebind_progress(_none), do: :ok

  # Every request goes out before any answer is awaited, so the client can
  # answer them in any order.
  defp ask(_session, _transport, requests) when map_size(requests) == 0, do: {:ok, %{}}

  defp ask(%Session{pid: pid} = session, transport, requests) do
    sink = transport.metadata[:progress_sink]
    monitor = Process.monitor(pid)

    try do
      with {:ok, pending} <- send_requests(session, sink, Enum.sort(requests)) do
        await_answers(pid, monitor, pending, %{})
      end
    after
      Process.demonitor(monitor, [:flush])
    end
  end

  defp send_requests(%Session{pid: pid} = session, sink, requests) do
    Enum.reduce_while(requests, {:ok, %{}}, fn {key, request}, {:ok, pending} ->
      with {:ok, id} <- Session.open_request(pid),
           :ok <- write(sink, server_request(id, request, session.protocol_version)) do
        {:cont, {:ok, Map.put(pending, id, key)}}
      else
        {:error, :closed} ->
          close_requests(pid, pending)
          {:halt, {:error, Error.internal("The session ended")}}

        {:error, reason} ->
          close_requests(pid, pending)
          {:halt, {:error, Error.internal("Could not send an input request", reason)}}
      end
    end)
  end

  defp close_requests(pid, pending),
    do: Enum.each(Map.keys(pending), &Session.close_request(pid, &1))

  defp await_answers(_pid, _monitor, pending, answers) when map_size(pending) == 0,
    do: {:ok, answers}

  defp await_answers(pid, monitor, pending, answers) do
    receive do
      {:mcp_session_answer, ^pid, id, response} when is_map_key(pending, id) ->
        {key, pending} = Map.pop(pending, id)

        case answer(response) do
          {:ok, result} ->
            await_answers(pid, monitor, pending, Map.put(answers, key, result))

          {:error, error} ->
            close_requests(pid, pending)
            {:error, error}
        end

      {:DOWN, ^monitor, :process, ^pid, _reason} ->
        {:error, Error.internal("The session ended")}
    end
  end

  defp answer(%{"result" => result}) when is_map(result), do: {:ok, result}

  defp answer(%{"error" => %{"code" => code, "message" => message}})
       when is_integer(code) and is_binary(message) do
    {:error,
     %Error{
       code: code,
       message: "The client refused an input request: " <> String.slice(message, 0, 256),
       kind: :protocol
     }}
  end

  defp answer(:closed), do: {:error, Error.internal("The session ended")}
  defp answer(_invalid), do: {:error, Error.invalid_params("Invalid answer to an input request")}

  # 2025-06-18 has no elicitation mode; a form request is its only kind.
  defp server_request(id, %{"method" => method} = request, version) do
    params = Map.get(request, "params", %{})

    params =
      if method == "elicitation/create" and version == "2025-06-18",
        do: Map.delete(params, "mode"),
        else: params

    %{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params}
  end

  defp write(%Progress.Sink{owner: owner, reference: reference, timeout: timeout}, message) do
    GenServer.call(owner, {:mcp_stream_message, reference, message}, timeout)
  catch
    :exit, {:timeout, _call} -> {:error, :timeout}
    :exit, _reason -> {:error, :closed_stream}
  end

  defp write(_no_sink, _message), do: {:error, :no_stream}

  defp cancel(runtime, raw, transport, %Session{pid: pid}) do
    case Server.resolve_notification(runtime, raw, transport) do
      {:ok, {:cancel, id, reason}} -> Session.cancel(pid, id, reason)
      _other -> :ok
    end
  end

  defp session_operation(runtime, raw, transport, session) do
    with {:ok, envelope} <- Envelope.decode(raw, transport),
         {:ok, protocol} <- Registry.select(runtime.protocol_registry, envelope),
         {:ok, decoded} <- protocol.decode_request(raw, transport),
         {:ok, _inspection} <- Inspector.inspect(protocol.profile(), decoded, :client_to_server),
         {:ok, context} <- protocol.build_context(decoded, runtime),
         {:ok, operation} <- resolve(protocol, decoded),
         :ok <- protocol.validate_operation(operation, decoded.params, context) do
      apply_operation(operation, runtime, context, session)
      reply(decoded)
    else
      {:error, %Error{} = error} -> Server.reject(runtime, raw, transport, error)
    end
  end

  defp resolve(protocol, envelope) do
    case protocol.resolve_operation(envelope) do
      {:ok, operation} -> {:ok, operation}
      :not_handled -> {:error, Error.method_not_found(envelope.method)}
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  # A resource the policy does not let this principal read is not subscribed,
  # as subscriptions/listen leaves it out of the accepted filter.
  defp apply_operation({:resource_subscribe, uri}, runtime, context, %Session{pid: pid}) do
    readable =
      if runtime.authorization,
        do:
          Router.filter_readable(runtime.router, [uri], context,
            authorization: runtime.authorization
          ),
        else: [uri]

    if readable == [uri], do: Session.subscribe(pid, uri, context), else: :ok
  end

  defp apply_operation({:resource_unsubscribe, uri}, _runtime, _context, %Session{pid: pid}),
    do: Session.unsubscribe(pid, uri)

  defp reply(%Envelope{kind: :notification}), do: {:ok, nil}

  defp reply(%Envelope{id: id}),
    do: {:ok, %{"jsonrpc" => "2.0", "id" => id, "result" => %{}}}

  defp record(
         {:ok, %{"result" => %{"protocolVersion" => version}}},
         %{"method" => "initialize", "params" => params},
         %Session{pid: pid}
       )
       when is_binary(version) do
    Session.ready(pid, version, params["clientInfo"], Map.get(params, "capabilities", %{}))
  end

  defp record(
         {:ok, %{"result" => _result}},
         %{"method" => "logging/setLevel", "params" => %{"level" => level}},
         %Session{pid: pid}
       ) do
    Session.put_log_level(pid, Snodo.Logging.parse_level(level))
  end

  defp record(_result, _raw, _session), do: :ok
end
