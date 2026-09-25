defmodule Examples.PlugBandit.Echo do
  @moduledoc false
  use Snodo.Tool, name: "echo"

  input_schema(%{
    "type" => "object",
    "properties" => %{"text" => %{"type" => "string"}},
    "required" => ["text"]
  })

  @impl true
  def call(%{"text" => text}, context) do
    {:ok, Snodo.Result.structured(%{"text" => text, "principal" => context.auth.principal})}
  end
end

defmodule Examples.PlugBandit.Server do
  @moduledoc false
  use Snodo.Server, name: "plug-bandit-example", version: "0.1.0"
  tool(Examples.PlugBandit.Echo)
end

defmodule Examples.PlugBandit.Endpoint do
  @moduledoc false
  @behaviour Plug

  @impl true
  def init(opts) do
    {token, opts} = Keyword.pop!(opts, :token)
    {token, Snodo.Transport.Plug.init(opts)}
  end

  @impl true
  def call(conn, {token, transport}) do
    # This is an ephemeral example credential, not an OAuth implementation.
    # Identity is assigned only after verification; no client identity is trusted.
    case Plug.Conn.get_req_header(conn, "authorization") do
      ["Bearer " <> supplied] ->
        if Plug.Crypto.secure_compare(supplied, token) do
          conn
          |> Plug.Conn.assign(:mcp_auth, %{principal: "example-reader"})
          |> Snodo.Transport.Plug.call(transport)
        else
          reject(conn)
        end

      _missing ->
        reject(conn)
    end
  end

  defp reject(conn), do: conn |> Plug.Conn.send_resp(401, "") |> Plug.Conn.halt()
end

defmodule Examples.PlugBandit.Runner do
  @moduledoc false
  alias Snodo.Subscription.Hub

  def run(mode) do
    token = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)

    {:ok, supervisor} =
      Supervisor.start_link(
        [
          {Snodo.Server.Executor,
           name: Examples.PlugBandit.Executor, max_concurrency: 2, max_queue: 4},
          {Hub, name: Examples.PlugBandit.Hub, max_buffer: 4}
        ],
        strategy: :one_for_one
      )

    try do
      runtime =
        Examples.PlugBandit.Server.runtime(
          capabilities: %{"tools" => %{"listChanged" => true}},
          subscription_source: Hub.source(Examples.PlugBandit.Hub)
        )

      {:ok, listener} =
        Supervisor.start_child(
          supervisor,
          {Bandit,
           plug:
             {Examples.PlugBandit.Endpoint,
              runtime: runtime, executor: Examples.PlugBandit.Executor, token: token},
           ip: {127, 0, 0, 1},
           port: 0,
           startup_log: false}
        )

      {:ok, {_ip, port}} = ThousandIsland.listener_info(listener)
      check_tool(port, token)
      check_subscription(port, token)
      %{subscriptions: 0} = Hub.stats(Examples.PlugBandit.Hub)

      case mode do
        :check ->
          IO.puts("21_plug_bandit: ok")

        :walkthrough ->
          IO.puts(
            "Authenticated tool and finite SSE subscription passed on local Bandit; source and listener cleaned up."
          )
      end
    after
      Supervisor.stop(supervisor)
    end
  end

  defp check_tool(port, token) do
    body =
      request(1, "tools/call", %{
        "name" => "echo",
        "arguments" => %{"text" => "hello from Bandit"}
      })

    socket = connect(port, token, body)
    [headers, json] = socket |> read_all() |> String.split("\r\n\r\n", parts: 2)
    true = String.starts_with?(headers, "HTTP/1.1 200")

    %{
      "result" => %{
        "structuredContent" => %{"principal" => "example-reader", "text" => "hello from Bandit"}
      }
    } = JSON.decode!(json)
  end

  defp check_subscription(port, token) do
    body = request(2, "subscriptions/listen", %{"notifications" => %{"toolsListChanged" => true}})
    socket = connect(port, token, body)
    first = read_until(socket, "notifications/subscriptions/acknowledged")
    true = String.contains?(first, "content-type: text/event-stream")
    {:ok, %{matched: 1}} = Hub.notify_tools_list_changed(Examples.PlugBandit.Hub)
    update = read_until(socket, "notifications/tools/list_changed")
    true = String.contains?(update, "io.modelcontextprotocol/subscriptionId")
    :ok = Hub.complete(Examples.PlugBandit.Hub)
    final = read_all(socket)
    true = String.contains?(final, "\"resultType\":\"complete\"")
    true = String.contains?(final, "\"id\":2")
  end

  defp request(id, method, params) do
    %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => method,
      "params" =>
        Map.put(params, "_meta", %{
          "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
          "io.modelcontextprotocol/clientCapabilities" => %{}
        })
    }
  end

  defp connect(port, token, body) do
    {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false], 2_000)
    json = JSON.encode!(body)
    name = if body["params"]["name"], do: ["Mcp-Name: ", body["params"]["name"], "\r\n"], else: []

    :ok =
      :gen_tcp.send(socket, [
        "POST /mcp HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n",
        "Content-Type: application/json\r\nAccept: application/json, text/event-stream\r\n",
        "Authorization: Bearer ",
        token,
        "\r\nMcp-Protocol-Version: 2026-07-28\r\nMcp-Method: ",
        body["method"],
        "\r\n",
        name,
        "Content-Length: ",
        to_string(byte_size(json)),
        "\r\n\r\n",
        json
      ])

    socket
  end

  defp read_all(socket, acc \\ "") do
    case :gen_tcp.recv(socket, 0, 2_000) do
      {:ok, chunk} -> read_all(socket, acc <> chunk)
      {:error, :closed} -> acc
      {:error, reason} -> raise "example HTTP read failed: #{inspect(reason)}"
    end
  end

  defp read_until(socket, expected, acc \\ "") do
    if String.contains?(acc, expected) do
      acc
    else
      {:ok, chunk} = :gen_tcp.recv(socket, 0, 2_000)
      read_until(socket, expected, acc <> chunk)
    end
  end
end

case System.argv() do
  ["--check"] -> Examples.PlugBandit.Runner.run(:check)
  [] -> Examples.PlugBandit.Runner.run(:walkthrough)
  _arguments -> raise "usage: mix run ../../examples/21_plug_bandit.exs [--check]"
end
