defmodule Snodo.OTP.Proxy do
  @moduledoc """
  A local GenServer that stands in for a GenServer behind an MCP endpoint.
  Application code keeps `GenServer.call/3` and `GenServer.cast/2`; each
  becomes a `tools/call` chosen by the contract.

  Failure semantics follow OTP where the wire allows it:

    * The caller's own `GenServer.call` timeout governs. The proxy answers
      when the tool result arrives; a late result after the caller gave up
      is dropped, as a late reply is in OTP.
    * A remote target that is not there (`GenServer target unavailable`)
      stops the proxy with `:noproc`, so a `Process.monitor/1` on the proxy
      delivers `DOWN` and a supervisor can restart it.
    * A transport failure stops the proxy with `{:nodedown, url}`.
    * A message the contract does not know stops the proxy with
      `{:function_clause, message}`, which is what an unmatched callback
      clause does to a GenServer.

  What it cannot give: a pid for the remote process, links to it, or any
  DOWN that is not provoked by a call. Those need a subscription stream
  (see the assessment).
  """
  use GenServer

  @tool_timeout 60_000

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
       client: nil,
       pending: %{}
     }}
  end

  @impl true
  def handle_call(message, from, state) do
    case state.contract.encode_call(message) do
      {name, args} -> start_call(state, from, name, args)
      :nomatch -> {:stop, {:function_clause, message}, state}
    end
  end

  @impl true
  def handle_cast(message, state) do
    case state.contract.encode_cast(message) do
      {name, args} -> start_cast(state, name, args)
      :nomatch -> {:stop, {:function_clause, message}, state}
    end
  end

  defp start_call(state, from, name, args) do
    case ensure_client(state) do
      {:ok, state} ->
        ref = make_ref()
        :ok = run_tool(state.client, name, args, {self(), ref})
        {:noreply, put_in(state.pending[ref], {from, name})}

      {:stop, _reason, _state} = stop ->
        stop
    end
  end

  defp start_cast(state, name, args) do
    case ensure_client(state) do
      {:ok, state} ->
        :ok = run_tool(state.client, name, args, nil)
        {:noreply, state}

      {:stop, _reason, _state} = stop ->
        stop
    end
  end

  # The call runs in its own process so the proxy keeps serving; a call's
  # result comes back as {:tool_result, ref, result}, a cast's is dropped.
  defp run_tool(client, name, args, reply_to) do
    {:ok, _pid} =
      Task.start(fn ->
        result = Snodo.Client.call_tool(client, name, args, timeout: @tool_timeout)

        case reply_to do
          {owner, ref} -> send(owner, {:tool_result, ref, result})
          nil -> :ok
        end
      end)

    :ok
  end

  @impl true
  def handle_info({:tool_result, ref, result}, state) do
    {{from, name}, pending} = Map.pop(state.pending, ref)
    state = %{state | pending: pending}

    case result do
      {:ok, %{"isError" => true} = tool_error} ->
        tool_error(state, from, error_text(tool_error))

      {:ok, %{"structuredContent" => json}} ->
        GenServer.reply(from, state.contract.decode_reply(name, json))
        {:noreply, state}

      {:ok, other} ->
        GenServer.reply(from, {:error, {:unexpected_result, other}})
        {:noreply, state}

      {:error, %Snodo.Error{kind: :transport}} ->
        {:stop, {:nodedown, state.url}, state}

      {:error, error} ->
        GenServer.reply(from, {:error, error})
        {:noreply, state}
    end
  end

  def handle_info(_other, state), do: {:noreply, state}

  # A missing remote target stops the proxy as a dead local one would. The
  # adapter's own timeout gets no reply: the caller's call timeout governs.
  defp tool_error(state, _from, "GenServer target unavailable" <> _rest),
    do: {:stop, :noproc, state}

  defp tool_error(state, _from, "GenServer call timed out" <> _rest), do: {:noreply, state}

  defp tool_error(state, from, text) do
    GenServer.reply(from, {:error, text})
    {:noreply, state}
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
