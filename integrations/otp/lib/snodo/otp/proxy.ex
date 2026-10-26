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

    * The caller's own `GenServer.call` timeout decides how long the caller
      waits, and a result that arrives after the caller gave up is dropped,
      as a late reply is in OTP. The request itself is not cancelled: it
      holds the single in-flight slot until the remote side answers or
      `:request_timeout` expires, so later requests wait behind it.
    * A call the remote side timed out (the adapter's `:timeout`, or the
      proxy's `:request_timeout`, default 60,000 ms) is answered
      `{:error, :timeout}`, so a caller with an `:infinity` timeout is not
      left waiting.
    * A call to a remote target that is not there (`GenServer target
      unavailable`) stops the proxy with `:noproc`, so a `Process.monitor/1`
      on the proxy delivers `DOWN` and a supervisor can restart it. A cast
      to it is dropped, as a cast to a dead name is in OTP. With
      `on_unavailable: :error` the call is answered `{:error, :noproc}`
      instead and the proxy keeps running.
    * At most `:max_queue` requests (default 1,000) wait behind the one in
      flight. A call beyond that is answered `{:error, :queue_full}` and a
      cast is dropped.
    * A request whose process crashes, for example on arguments JSON cannot
      encode, is answered `{:error, {:request_failed, reason}}`, and later
      requests still run.
    * A reply `decode_reply/2` does not match is answered
      `{:error, {:decode_failed, name, json}}`. `encode_call/1` and
      `encode_cast/1` run on the caller's message in the proxy, as a
      GenServer callback does, so a raise there stops the proxy.
    * A connection failure stops the proxy with `{:nodedown, url}`. An HTTP
      error status, such as 401 or 404, is answered `{:error, error}` and the
      proxy keeps running.
    * A message the contract does not know stops the proxy with
      `{:function_clause, message}`, which is what an unmatched callback
      clause does to a GenServer.

  Options: `:url` and `:contract` (required), `:name`, `:headers`,
  `:request_timeout`, `:max_queue`, `:on_unavailable` (`:stop`, the default,
  or `:error`), and `:connect`, a keyword list merged over the
  defaults passed to `Snodo.Client.connect/2` (`protocol: "2026-07-28"`,
  `timeout: 15_000`), for example `connect: [token_provider: provider]`.

  What it cannot give: a pid for the remote process, links to it, or any
  DOWN that is not provoked by a call. Those need a subscription stream.
  """
  use GenServer

  @default_request_timeout 60_000
  @default_max_queue 1_000
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
       connect: Keyword.get(opts, :connect, []),
       contract: Keyword.fetch!(opts, :contract),
       request_timeout: Keyword.get(opts, :request_timeout, @default_request_timeout),
       max_queue: Keyword.get(opts, :max_queue, @default_max_queue),
       on_unavailable: Keyword.get(opts, :on_unavailable, :stop),
       client: nil,
       queue: :queue.new(),
       queued: 0,
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
  def handle_info({:tool_result, ref, result}, %{in_flight: {ref, monitor, from, name}} = state) do
    Process.demonitor(monitor, [:flush])
    finish(%{state | in_flight: nil}, result, from, name)
  end

  # The request process died without a result, for example because the
  # client raised on arguments it could not encode.
  def handle_info(
        {:DOWN, monitor, :process, _pid, reason},
        %{in_flight: {_ref, monitor, from, name}} = state
      ) do
    finish(%{state | in_flight: nil}, {:failed, reason}, from, name)
  end

  def handle_info(_other, state), do: {:noreply, state}

  defp finish(state, result, from, name) do
    case outcome(result, from, name, state) do
      :continue -> dispatch(state)
      {:stop, reason} -> {:stop, reason, state}
    end
  end

  # The request being sent does not count against the limit.
  defp enqueue(%{queued: queued, max_queue: max} = state, {from, _name, _args})
       when queued >= max and state.in_flight != nil do
    reply(from, {:error, :queue_full})
    {:noreply, state}
  end

  defp enqueue(state, request) do
    dispatch(%{state | queue: :queue.in(request, state.queue), queued: state.queued + 1})
  end

  # Sends the next queued request when none is in flight.
  defp dispatch(%{in_flight: nil} = state) do
    case :queue.out(state.queue) do
      {{:value, {from, name, args}}, queue} ->
        case ensure_client(%{state | queue: queue, queued: state.queued - 1}) do
          {:ok, state} ->
            ref = make_ref()
            monitor = run_tool(state, name, args, ref)
            {:noreply, %{state | in_flight: {ref, monitor, from, name}}}

          {:stop, _reason, _state} = stop ->
            stop
        end

      {:empty, _queue} ->
        {:noreply, state}
    end
  end

  defp dispatch(state), do: {:noreply, state}

  # The request runs in its own monitored process so the proxy keeps
  # accepting messages; its result comes back as {:tool_result, ref, result},
  # and a crash comes back as :DOWN.
  defp run_tool(%{client: client, request_timeout: timeout}, name, args, ref) do
    owner = self()

    {_pid, monitor} =
      spawn_monitor(fn ->
        result = Snodo.Client.call_tool(client, name, args, timeout: timeout)
        send(owner, {:tool_result, ref, result})
      end)

    monitor
  end

  # What a tool result means for the caller (nil for a cast) and the proxy.
  defp outcome({:failed, reason}, from, _name, _state),
    do: reply(from, {:error, {:request_failed, reason}})

  # A cast to a target that is not running is dropped, as in OTP.
  defp outcome({:ok, %{"isError" => true} = result}, from, _name, state) do
    case error_text(result) do
      "GenServer target unavailable" <> _rest when is_nil(from) ->
        :continue

      "GenServer target unavailable" <> _rest when state.on_unavailable == :error ->
        reply(from, {:error, :noproc})

      "GenServer target unavailable" <> _rest ->
        {:stop, :noproc}

      "GenServer call timed out" <> _rest ->
        reply(from, {:error, :timeout})

      text ->
        reply(from, {:error, text})
    end
  end

  defp outcome({:ok, %{"structuredContent" => _json}}, nil, _name, _state), do: :continue

  defp outcome({:ok, %{"structuredContent" => json}}, from, name, state),
    do: reply(from, decode(state.contract, name, json))

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

  # A reply the contract cannot decode fails only its own call.
  defp decode(contract, name, json) do
    contract.decode_reply(name, json)
  rescue
    _exception -> {:error, {:decode_failed, name, json}}
  end

  # A cast has no caller to answer.
  defp reply(nil, _value), do: :continue

  defp reply(from, value) do
    GenServer.reply(from, value)
    :continue
  end

  defp ensure_client(%{client: nil} = state) do
    options =
      Keyword.merge(
        [headers: state.headers, protocol: "2026-07-28", timeout: 15_000],
        state.connect
      )

    case Snodo.Client.connect({:http, state.url}, options) do
      {:ok, client} -> {:ok, %{state | client: client}}
      {:error, _reason} -> {:stop, {:nodedown, state.url}, state}
    end
  end

  defp ensure_client(state), do: {:ok, state}

  defp error_text(%{"content" => [%{"text" => text} | _rest]}), do: text
  defp error_text(_result), do: ""
end
