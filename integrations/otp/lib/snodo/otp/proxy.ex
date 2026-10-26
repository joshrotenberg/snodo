defmodule Snodo.OTP.Proxy do
  @moduledoc """
  A local GenServer that stands in for a GenServer behind an MCP endpoint.
  Application code keeps `GenServer.call/3` and `GenServer.cast/2`; each
  becomes a `tools/call` chosen by the contract.

  Requests go out one at a time, in the order the proxy receives them, and
  each waits for its result before the next is sent. That keeps the ordering
  OTP gives a sender and a GenServer: casts arrive in order, and a call sees
  every cast sent before it. The remote GenServer handles one message at a
  time anyway; the cost is that requests do not overlap on the wire.

  Failure semantics follow OTP where the wire allows it:

    * The caller's own `GenServer.call` timeout governs. A result that
      arrives after the caller gave up is dropped, as a late reply is in OTP.
    * A call the remote side timed out (the adapter's `:timeout`, or the
      proxy's `:request_timeout`, default 60,000 ms) is answered
      `{:error, :timeout}`, so a caller with an `:infinity` timeout is not
      left waiting.
    * A remote target that is not there (`GenServer target unavailable`)
      stops the proxy with `:noproc`, so a `Process.monitor/1` on the proxy
      delivers `DOWN` and a supervisor can restart it.
    * A connection failure stops the proxy with `{:nodedown, url}`. An HTTP
      error status, such as 401 or 404, is answered `{:error, error}` and the
      proxy keeps running.
    * A message the contract does not know stops the proxy with
      `{:function_clause, message}`, which is what an unmatched callback
      clause does to a GenServer.

  What it cannot give: a pid for the remote process, links to it, or any
  DOWN that is not provoked by a call. Those need a subscription stream.
  """
  use GenServer

  @default_request_timeout 60_000
  # Snodo.Client.Transport.timeout_error/1
  @request_timeout -32_001

  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name)

    if name,
      do: GenServer.start_link(__MODULE__, opts, name: name),
      else: GenServer.start_link(__MODULE__, opts)
  end

  @impl true
  def init(opts) do
    {:ok,
     %{
       url: Keyword.fetch!(opts, :url),
       headers: Keyword.get(opts, :headers, []),
       contract: Keyword.fetch!(opts, :contract),
       request_timeout: Keyword.get(opts, :request_timeout, @default_request_timeout),
       client: nil,
       queue: :queue.new(),
       in_flight: nil
     }}
  end

  @impl true
  def handle_call(message, from, state) do
    case state.contract.encode_call(message) do
      {name, args} -> enqueue(state, {from, name, args})
      :nomatch -> {:stop, {:function_clause, message}, state}
    end
  end

  @impl true
  def handle_cast(message, state) do
    case state.contract.encode_cast(message) do
      {name, args} -> enqueue(state, {nil, name, args})
      :nomatch -> {:stop, {:function_clause, message}, state}
    end
  end

  @impl true
  def handle_info({:tool_result, ref, result}, %{in_flight: {ref, from, name}} = state) do
    state = %{state | in_flight: nil}

    case outcome(result, from, name, state) do
      :continue -> dispatch(state)
      {:stop, reason} -> {:stop, reason, state}
    end
  end

  def handle_info(_other, state), do: {:noreply, state}

  defp enqueue(state, request) do
    dispatch(%{state | queue: :queue.in(request, state.queue)})
  end

  # Sends the next queued request when none is in flight.
  defp dispatch(%{in_flight: nil} = state) do
    case :queue.out(state.queue) do
      {{:value, {from, name, args}}, queue} ->
        case ensure_client(%{state | queue: queue}) do
          {:ok, state} ->
            ref = make_ref()
            :ok = run_tool(state, name, args, ref)
            {:noreply, %{state | in_flight: {ref, from, name}}}

          {:stop, _reason, _state} = stop ->
            stop
        end

      {:empty, _queue} ->
        {:noreply, state}
    end
  end

  defp dispatch(state), do: {:noreply, state}

  # The request runs in its own process so the proxy keeps accepting
  # messages; its result comes back as {:tool_result, ref, result}.
  defp run_tool(%{client: client, request_timeout: timeout}, name, args, ref) do
    owner = self()

    {:ok, _pid} =
      Task.start(fn ->
        result = Snodo.Client.call_tool(client, name, args, timeout: timeout)
        send(owner, {:tool_result, ref, result})
      end)

    :ok
  end

  # What a tool result means for the caller (nil for a cast) and the proxy.
  defp outcome({:ok, %{"isError" => true} = result}, from, _name, _state) do
    case error_text(result) do
      "GenServer target unavailable" <> _rest -> {:stop, :noproc}
      "GenServer call timed out" <> _rest -> reply(from, {:error, :timeout})
      text -> reply(from, {:error, text})
    end
  end

  defp outcome({:ok, %{"structuredContent" => json}}, from, name, state) do
    if from, do: reply(from, state.contract.decode_reply(name, json)), else: :continue
  end

  defp outcome({:ok, other}, from, _name, _state),
    do: reply(from, {:error, {:unexpected_result, other}})

  defp outcome(
         {:error, %Snodo.Error{kind: :transport, code: @request_timeout}},
         from,
         _name,
         _state
       ),
       do: reply(from, {:error, :timeout})

  defp outcome(
         {:error, %Snodo.Error{kind: :transport, cause: {:http_status, _status, _body}} = error},
         from,
         _name,
         _state
       ),
       do: reply(from, {:error, error})

  defp outcome({:error, %Snodo.Error{kind: :transport}}, _from, _name, state),
    do: {:stop, {:nodedown, state.url}}

  defp outcome({:error, error}, from, _name, _state), do: reply(from, {:error, error})

  # A cast has no caller to answer.
  defp reply(nil, _value), do: :continue

  defp reply(from, value) do
    GenServer.reply(from, value)
    :continue
  end

  defp ensure_client(%{client: nil} = state) do
    case Snodo.Client.connect({:http, state.url},
           headers: state.headers,
           protocol: "2026-07-28",
           timeout: 15_000
         ) do
      {:ok, client} -> {:ok, %{state | client: client}}
      {:error, _reason} -> {:stop, {:nodedown, state.url}, state}
    end
  end

  defp ensure_client(state), do: {:ok, state}

  defp error_text(%{"content" => [%{"text" => text} | _rest]}), do: text
  defp error_text(_result), do: ""
end
