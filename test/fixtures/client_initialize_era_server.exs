# A hand-written initialize-era stdio server for Snodo.Client tests. It speaks
# literal 2025-11-25 or 2025-06-18 messages and nothing newer, the way a server
# built on an older SDK does. Run it as
#   elixir test/fixtures/client_initialize_era_server.exs [--discover MODE] [--serve VERSION]
#
# What the tests rely on:
#
#   * A request that arrives before `initialize` is answered according to
#     --discover: a -32601 error (`error`, the default), a result with nothing
#     in it (`garbage`), or nothing at all (`silent`). Whatever the answer,
#     this process then refuses `initialize`, as an older server may once it
#     has processed a request under its own lifecycle rules. Only a new
#     process can be initialized, which makes the client's respawn observable.
#   * `initialize` answers with the proposed version when it is 2025-11-25 or
#     2025-06-18, or with --serve when given, and issues no session id.
#   * Tools: `echo` returns its text; `requests_seen` returns how many
#     requests this process has handled, itself included; `ask` sends
#     `elicitation/create` to the client and returns the answer as text;
#     `ping_me` sends `ping` and returns "pong".

defmodule InitializeEraFixture do
  @moduledoc false

  @versions ["2025-11-25", "2025-06-18"]

  def main(args) do
    loop(%{
      discover: option(args, "--discover", "error"),
      serve: option(args, "--serve", nil),
      phase: :new,
      version: nil,
      requests: 0,
      next_id: 1
    })
  end

  defp option(args, name, default) do
    case Enum.drop_while(args, &(&1 != name)) do
      [^name, value | _rest] -> value
      _absent -> default
    end
  end

  defp loop(state) do
    case read() do
      :eof -> :ok
      message -> state |> handle(message) |> loop()
    end
  end

  defp read do
    case IO.binread(:stdio, :line) do
      :eof -> :eof
      {:error, _reason} -> :eof
      line -> JSON.decode!(String.trim(line))
    end
  end

  # A client whose probe timed out closes the pipe before this process
  # answers it; the answer then has nowhere to go.
  defp write(message) do
    IO.binwrite(:stdio, JSON.encode!(message) <> "\n")
  catch
    :error, :terminated -> System.halt(0)
  end

  defp result(id, result), do: write(%{"jsonrpc" => "2.0", "id" => id, "result" => result})

  defp error(id, code, message),
    do:
      write(%{"jsonrpc" => "2.0", "id" => id, "error" => %{"code" => code, "message" => message}})

  defp text(id, text, error? \\ false),
    do: result(id, %{"content" => [%{"type" => "text", "text" => text}], "isError" => error?})

  # A request before initialize taints this process.
  defp handle(%{phase: :new} = state, %{"id" => id, "method" => method})
       when method != "initialize" do
    case state.discover do
      "error" -> error(id, -32_601, "Method not found: #{method}")
      "garbage" -> result(id, %{})
      "silent" -> :ok
    end

    %{state | phase: :tainted, requests: state.requests + 1}
  end

  defp handle(%{phase: :tainted} = state, %{"id" => id}) do
    error(id, -32_600, "This process already handled a request; it cannot be initialized")
    %{state | requests: state.requests + 1}
  end

  defp handle(state, %{"id" => id, "method" => "initialize", "params" => params}) do
    proposed = params["protocolVersion"]
    version = state.serve || if(proposed in @versions, do: proposed, else: "2025-11-25")

    result(id, %{
      "protocolVersion" => version,
      "capabilities" => %{"tools" => %{}},
      "serverInfo" => %{"name" => "initialize-era-fixture", "version" => "1"},
      "instructions" => "A hand-written #{version} server."
    })

    %{state | phase: :initializing, version: version, requests: state.requests + 1}
  end

  defp handle(state, %{"method" => "notifications/initialized"}), do: %{state | phase: :ready}

  defp handle(state, %{"id" => id, "method" => "ping"}) do
    result(id, %{})
    %{state | requests: state.requests + 1}
  end

  defp handle(state, %{"id" => id, "method" => "tools/list"}) do
    tools =
      for name <- ["echo", "requests_seen", "ask", "ping_me"] do
        %{"name" => name, "inputSchema" => %{"type" => "object"}}
      end

    result(id, %{"tools" => tools})
    %{state | requests: state.requests + 1}
  end

  defp handle(state, %{
         "id" => id,
         "method" => "tools/call",
         "params" => %{"name" => name} = params
       }) do
    state = %{state | requests: state.requests + 1}
    call(state, id, name, Map.get(params, "arguments", %{}))
  end

  defp handle(state, %{"id" => id, "method" => method}) do
    error(id, -32_601, "Method not found: #{method}")
    %{state | requests: state.requests + 1}
  end

  # Notifications and stray responses.
  defp handle(state, _message), do: state

  defp call(state, id, "echo", %{"text" => text}) do
    text(id, text)
    state
  end

  defp call(state, id, "requests_seen", _arguments) do
    text(id, Integer.to_string(state.requests))
    state
  end

  defp call(state, id, "ask", _arguments) do
    params = %{
      "message" => "Your name?",
      "requestedSchema" => %{
        "type" => "object",
        "properties" => %{"name" => %{"type" => "string"}},
        "required" => ["name"]
      }
    }

    # 2025-11-25 names the mode; 2025-06-18 has only the form.
    params = if state.version == "2025-11-25", do: Map.put(params, "mode", "form"), else: params

    {state, answer} = ask(state, "elicitation/create", params)

    case answer do
      %{"result" => %{"action" => "accept", "content" => %{"name" => name}}} ->
        text(id, "hello #{name}")

      %{"result" => %{"action" => action}} ->
        text(id, action)

      %{"error" => %{"code" => code, "message" => message}} ->
        text(id, "elicitation failed: #{code} #{message}", true)
    end

    state
  end

  defp call(state, id, "ping_me", _arguments) do
    {state, answer} = ask(state, "ping", %{})

    case answer do
      %{"result" => %{}} -> text(id, "pong")
      %{"error" => %{"code" => code}} -> text(id, "ping failed: #{code}", true)
    end

    state
  end

  defp call(state, id, name, _arguments) do
    error(id, -32_602, "Unknown tool: #{name}")
    state
  end

  # Sends a request to the client and reads until its response arrives,
  # handling whatever else comes in the meantime.
  defp ask(state, method, params) do
    request_id = "srv-#{state.next_id}"
    write(%{"jsonrpc" => "2.0", "id" => request_id, "method" => method, "params" => params})
    await(%{state | next_id: state.next_id + 1}, request_id)
  end

  defp await(state, request_id) do
    case read() do
      :eof ->
        System.halt(0)

      %{"id" => ^request_id} = answer when not is_map_key(answer, "method") ->
        {state, answer}

      message ->
        await(handle(state, message), request_id)
    end
  end
end

InitializeEraFixture.main(System.argv())
