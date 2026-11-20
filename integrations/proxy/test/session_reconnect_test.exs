defmodule Snodo.Proxy.SessionReconnectTest do
  use ExUnit.Case, async: true

  alias Snodo.Client
  alias Snodo.Client.Subscription
  alias Snodo.Error
  alias Snodo.Protocol.V2025_11_25
  alias Snodo.Proxy
  alias Snodo.Proxy.Manager
  alias Snodo.Transport.Context
  alias Snodo.Transport.StreamableHTTP.RequestGate
  alias Snodo.Transport.StreamableHTTP.Response
  alias Snodo.Transport.StreamableHTTP.Server, as: HTTPServer

  defmodule Backend do
    use Snodo.Server, name: "session-backend", version: "1.0.0"

    tool "echo" do
      argument("value", :string, required: true)

      @impl true
      def call(%{"value" => value}, %{auth: %{owner: owner}}) do
        send(owner, {:echo, value})
        {:ok, value}
      end
    end

    tool "obsolete" do
      @impl true
      def call(_arguments, _context), do: {:ok, "obsolete"}
    end

    resource "note", uri: "test://note" do
      @impl true
      def read(_params, _context), do: {:ok, "note"}
    end

    prompt "review" do
      @impl true
      def render(_arguments, _context), do: {:ok, "review"}
    end
  end

  defmodule Gate do
    @behaviour RequestGate

    @impl true
    def init(opts, _listener), do: {Keyword.fetch!(opts, :mode), Keyword.fetch!(opts, :owner)}

    @impl true
    def check(request, {mode, owner}) do
      generation = Agent.get(mode, & &1)
      session = Context.get_header(request.headers, "mcp-session-id")
      admit(generation, session, owner)
    end

    defp admit(:reject, nil, _owner), do: {:response, %Response{status: 503}}

    defp admit(:replacement, nil, owner) do
      send(owner, {:reinitialize, self()})

      receive do
        :allow_initialize -> {:ok, %{principal: :replacement, owner: owner}}
      end
    end

    # The native server binds sessions to the auth value. Changing generations
    # makes the old session return 404, while new sessions use the new principal.
    defp admit(generation, session, owner) do
      send(owner, {:backend_request, generation, session})
      {:ok, %{principal: generation, owner: owner}}
    end
  end

  defmodule CatalogPolicy do
    @behaviour Snodo.Authorization

    @impl true
    def authorize(:discovery, %{name: name}, %{auth: %{principal: :replacement}}, _opts)
        when name != "echo",
        do: {:error, Error.authorization(-32_003, "Unavailable in the replacement catalog")}

    def authorize(_phase, _component, _context, _opts), do: :ok
  end

  setup do
    mode = start_supervised!({Agent, fn -> :initial end})
    runtime = Backend.runtime(protocols: [V2025_11_25], authorization: CatalogPolicy)

    server =
      start_supervised!(
        {HTTPServer,
         runtime: runtime,
         port: 0,
         sessions: true,
         request_gate: {Gate, mode: mode, owner: self()}}
      )

    proxy =
      start_supervised!(
        {Proxy,
         backends: [
           [
             id: "remote",
             target: {:http, HTTPServer.url(server)},
             client_options: [protocol: "2025-11-25", timeout: 5_000]
           ]
         ]}
      )

    {:ok, client} = Client.direct(Proxy.runtime(proxy))
    %{client: client, mode: mode, proxy: proxy}
  end

  test "session loss reconnects, refreshes the catalog, and never replays the call", context do
    %{client: client, mode: mode, proxy: proxy} = context

    assert {:ok, [%{"name" => "remote.echo"}, %{"name" => "remote.obsolete"}]} =
             Client.list_tools(client)

    assert {:ok, [%{"name" => "remote.note"}]} = Client.list_resources(client)
    assert {:ok, [%{"name" => "remote.review"}]} = Client.list_prompts(client)
    old_session = backend_session(proxy)
    assert is_binary(old_session)
    assert {:ok, subscription} = Client.listen(client, %{"toolsListChanged" => true})

    :ok = Agent.update(mode, fn _mode -> :replacement end)
    assert_session_lost(client)
    assert_receive {:backend_request, :replacement, ^old_session}, 500
    assert_tools_changed(subscription)

    assert_receive {:reinitialize, gate}, 5_000

    assert %{status: :down, error: %Error{cause: :session_not_found}} =
             Proxy.health(proxy)["remote"]

    assert_unavailable(client)

    send(gate, :allow_initialize)
    assert_tools_changed(subscription)
    assert %{status: :up, error: nil} = Proxy.health(proxy)["remote"]
    assert is_binary(backend_session(proxy))
    assert backend_session(proxy) != old_session

    assert {:ok, [%{"name" => "remote.echo"}]} = Client.list_tools(client)
    assert {:ok, []} = Client.list_resources(client)
    assert {:ok, []} = Client.list_prompts(client)

    assert {:ok, %{"content" => [%{"text" => "next"}]}} =
             Client.call_tool(client, "remote.echo", %{"value" => "next"})

    assert_received {:echo, "next"}
    refute_received {:echo, "failed"}
    refute_received {:backend_request, :replacement, ^old_session}
  end

  test "an explicit catalog refresh detects session loss and reconnects", context do
    %{client: client, mode: mode, proxy: proxy} = context
    old_session = backend_session(proxy)
    assert {:ok, subscription} = Client.listen(client, %{"toolsListChanged" => true})

    :ok = Agent.update(mode, fn _mode -> :replacement end)

    assert {:error, %Error{kind: :transport, cause: :session_not_found}} =
             Proxy.refresh_backend(proxy, "remote")

    assert_tools_changed(subscription)
    assert_receive {:reinitialize, gate}, 5_000
    assert_unavailable(client)

    send(gate, :allow_initialize)
    assert_tools_changed(subscription)
    assert %{status: :up, error: nil} = Proxy.health(proxy)["remote"]
    assert backend_session(proxy) != old_session
    assert {:ok, [%{"name" => "remote.echo"}]} = Client.list_tools(client)
  end

  test "a failed replacement handshake keeps the backend down and reports the error", context do
    %{client: client, mode: mode, proxy: proxy} = context
    :ok = Agent.update(mode, fn _mode -> :reject end)
    assert_session_lost(client)

    await_health(proxy, fn
      %{status: :down, error: %Error{kind: :transport, cause: {:http_status, 503, _body}}} ->
        true

      _other ->
        false
    end)

    assert_unavailable(client)
    refute_received {:echo, "failed"}
  end

  defp assert_session_lost(client) do
    assert {:error, %Error{code: -32_000, message: "The HTTP session was lost"}} =
             Client.call_tool(client, "remote.echo", %{"value" => "failed"})
  end

  defp assert_tools_changed(subscription) do
    assert {:notification, "notifications/tools/list_changed", _params} =
             Subscription.next(subscription, 5_000)
  end

  defp assert_unavailable(client) do
    assert {:ok, []} = Client.list_tools(client)

    assert {:error, %Error{code: -32_602, message: "Unknown tool: remote.echo"}} =
             Client.call_tool(client, "remote.echo", %{"value" => "while down"})
  end

  defp backend_session(proxy), do: Manager.catalog(proxy).tools["remote.echo"].client.session.id

  defp await_health(proxy, ready?) do
    deadline = System.monotonic_time(:millisecond) + 5_000
    await_health(proxy, ready?, deadline)
  end

  defp await_health(proxy, ready?, deadline) do
    health = Proxy.health(proxy)["remote"]

    unless ready?.(health) do
      assert System.monotonic_time(:millisecond) < deadline, "Last health: #{inspect(health)}"

      receive do
      after
        10 -> await_health(proxy, ready?, deadline)
      end
    end
  end
end
