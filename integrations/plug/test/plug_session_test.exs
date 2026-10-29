defmodule Snodo.Transport.PlugSessionTest do
  use ExUnit.Case, async: true

  alias Snodo.Client
  alias Snodo.Protocol.{V2025_06_18, V2025_11_25, V2026_07_28}
  alias Snodo.Server.Executor
  alias Snodo.Session.Manager
  alias Snodo.Subscription.Hub

  defmodule Ask do
    @moduledoc false
    use Snodo.Tool, name: "ask"

    @impl true
    def call(_arguments, context) do
      request =
        Snodo.Elicitation.form("Name?", %{
          "type" => "object",
          "properties" => %{"name" => %{"type" => "string"}},
          "required" => ["name"]
        })

      case Snodo.Elicitation.response(context, "name", request) do
        :missing ->
          {:ok, Snodo.Result.input_required(input_requests: %{"name" => request})}

        {:ok, %{"content" => %{"name" => name}}} ->
          {:ok, Snodo.Result.text("Hello, #{name}")}
      end
    end
  end

  setup do
    hub = start_supervised!(Hub)
    executor = :"plug_session_executor_#{System.unique_integer([:positive])}"
    manager = :"plug_session_manager_#{System.unique_integer([:positive])}"
    start_supervised!({Executor, name: executor})
    start_supervised!({Manager, name: manager})

    runtime =
      Snodo.Server.Runtime.new(
        router: Snodo.Router.register_tool(Snodo.Router.new(), Ask),
        protocols: [V2026_07_28, V2025_11_25, V2025_06_18],
        server_info: %{"name" => "plug-sessions", "version" => "0.1.0"},
        capabilities: %{"tools" => %{"listChanged" => true}},
        subscription_source: Hub.source(hub)
      )

    listener =
      start_supervised!(
        {Bandit,
         plug:
           {Snodo.Transport.Plug,
            runtime: runtime, executor: executor, sessions: manager, subscription_keepalive_ms: 50},
         ip: {127, 0, 0, 1},
         port: 0,
         startup_log: false}
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(listener)
    %{hub: hub, port: port, url: "http://127.0.0.1:#{port}/mcp", manager: manager}
  end

  test "Snodo.Client answers an elicitation over the Plug", %{url: url} do
    form = fn _params -> {:ok, %{"action" => "accept", "content" => %{"name" => "Ada"}}} end

    {:ok, client} =
      Client.connect({:http, url}, protocol: "2025-11-25", input_handlers: %{form: form})

    assert {:ok, %{"content" => [%{"text" => "Hello, Ada"}]}} =
             Client.call_tool(client, "ask", %{})

    Client.close(client)
  end

  test "the standalone stream carries list changes, one per session, until DELETE", %{
    hub: hub,
    port: port,
    manager: manager
  } do
    {200, headers, _body} = request(port, "POST", initialize_headers(), initialize())
    id = header(headers, "mcp-session-id")
    assert Manager.count(manager) == 1

    stream = open_stream(port, id)
    assert {409, _headers, _body} = request(port, "GET", stream_headers(id), "")

    {:ok, _report} = Hub.notify_tools_list_changed(hub)
    assert recv_until(stream, "notifications/tools/list_changed", "") =~ "event: message"

    assert {200, _headers, _body} = request(port, "DELETE", session_headers(id), "")
    assert {404, _headers, _body} = request(port, "DELETE", session_headers(id), "")
    assert Manager.count(manager) == 0
    :gen_tcp.close(stream)
  end

  defp initialize do
    JSON.encode!(%{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "initialize",
      "params" => %{
        "protocolVersion" => "2025-11-25",
        "capabilities" => %{},
        "clientInfo" => %{"name" => "plug-session-test", "version" => "1"}
      }
    })
  end

  defp initialize_headers,
    do: [{"content-type", "application/json"}, {"accept", "application/json, text/event-stream"}]

  defp session_headers(id),
    do: [{"mcp-protocol-version", "2025-11-25"}, {"mcp-session-id", id}]

  defp stream_headers(id), do: [{"accept", "text/event-stream"} | session_headers(id)]

  defp open_stream(port, id) do
    {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false])
    :ok = :gen_tcp.send(socket, encoded("GET", stream_headers(id), ""))
    assert recv_until(socket, "\r\n\r\n", "") =~ "HTTP/1.1 200"
    socket
  end

  defp request(port, method, headers, body) do
    {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false])
    :ok = :gen_tcp.send(socket, encoded(method, headers, body))
    response = recv_all(socket, "")
    [head, body] = :binary.split(response, "\r\n\r\n")
    [status_line | lines] = String.split(head, "\r\n")
    [_version, status | _reason] = String.split(status_line, " ")

    headers =
      Enum.map(lines, fn line ->
        [name, value] = :binary.split(line, ":")
        {String.downcase(name), String.trim(value)}
      end)

    {String.to_integer(status), headers, body}
  end

  defp header(headers, name),
    do: Enum.find_value(headers, fn {key, value} -> key == name && value end)

  defp encoded(method, headers, body) do
    headers = [
      {"host", "127.0.0.1"},
      {"content-length", Integer.to_string(byte_size(body))},
      {"connection", "close"} | headers
    ]

    lines = Enum.map(headers, fn {name, value} -> [name, ": ", value, "\r\n"] end)
    [method, " /mcp HTTP/1.1\r\n", lines, "\r\n", body]
  end

  defp recv_all(socket, acc) do
    case :gen_tcp.recv(socket, 0, 2_000) do
      {:ok, chunk} -> recv_all(socket, acc <> chunk)
      {:error, :closed} -> acc
    end
  end

  defp recv_until(socket, pattern, acc) do
    if String.contains?(acc, pattern) do
      acc
    else
      case :gen_tcp.recv(socket, 0, 2_000) do
        {:ok, chunk} -> recv_until(socket, pattern, acc <> chunk)
        {:error, reason} -> flunk("socket closed before #{inspect(pattern)}: #{inspect(reason)}")
      end
    end
  end
end
