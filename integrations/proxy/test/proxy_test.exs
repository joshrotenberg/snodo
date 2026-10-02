defmodule Snodo.ProxyTest do
  use ExUnit.Case, async: false

  @moduletag timeout: 30_000

  alias Snodo.Client
  alias Snodo.Client.Stdio
  alias Snodo.Client.Subscription
  alias Snodo.Error
  alias Snodo.Proxy
  alias Snodo.Proxy.Manager
  alias Snodo.Subscription.Event
  alias Snodo.Subscription.Hub
  alias Snodo.Transport.StreamableHTTP.Server, as: HTTPServer

  defmodule BackendA do
    use Snodo.Server, name: "backend-a", version: "1.0.0"

    tool "echo" do
      argument("value", :string, required: true)

      @impl true
      def call(%{"value" => value}, _context), do: {:ok, "a:#{value}"}
    end

    tool "progress" do
      @impl true
      def call(_arguments, context) do
        :ok = Snodo.Progress.report(context, 50, total: 100)
        {:ok, "done"}
      end
    end

    tool "continuation" do
      @impl true
      def call(_arguments, %{request_state: "resume"}), do: {:ok, "resumed"}

      def call(_arguments, _context),
        do: {:ok, Snodo.Result.input_required(request_state: "resume")}
    end

    resource "note", uri: "test://a/note" do
      @impl true
      def read(_params, _context), do: {:ok, "a note"}
    end

    resource "item", uri_template: "test://a/items/{name}" do
      @impl true
      def read(%{"name" => name}, _context), do: {:ok, "item #{name}"}
    end

    prompt "review" do
      @impl true
      def render(_arguments, _context), do: {:ok, "review a"}
    end
  end

  defmodule BackendB do
    use Snodo.Server, name: "backend-b", version: "1.0.0"

    tool "echo" do
      argument("value", :string, required: true)

      @impl true
      def call(%{"value" => value}, _context), do: {:ok, "b:#{value}"}
    end
  end

  defmodule BackendLinks do
    use Snodo.Server, name: "backend-links", version: "1.0.0"

    resource "note", uri: "test://links/note" do
      @impl true
      def read(_params, _context), do: {:ok, "linked note"}
    end

    tool "link" do
      @impl true
      def call(_arguments, _context) do
        {:ok,
         Snodo.Result.content(%{
           "type" => "resource_link",
           "uri" => "test://links/note",
           "name" => "note"
         })}
      end
    end

    prompt "link" do
      @impl true
      def render(_arguments, _context) do
        {:ok,
         Snodo.Result.prompt_get(
           Snodo.Prompt.message(
             :assistant,
             Snodo.Prompt.resource_link("test://links/note", "note")
           )
         )}
      end
    end
  end

  defmodule BackendRenamed do
    use Snodo.Server, name: "backend-renamed", version: "1.0.0"

    resource "private", uri: "test://a/note" do
      @impl true
      def read(_params, _context), do: {:ok, "private"}
    end
  end

  defmodule RefuseB do
    @behaviour Snodo.Authorization

    @impl true
    def authorize(_phase, %{name: "b.echo"}, _context, _options),
      do: {:error, Error.authorization(-32_003, "Blocked")}

    def authorize(_phase, _component, _context, _options), do: :ok
  end

  defmodule RefuseNote do
    @behaviour Snodo.Authorization

    @impl true
    def authorize(_phase, %{name: "a.note"}, _context, _options),
      do: {:error, Error.authorization(-32_003, "Blocked")}

    def authorize(_phase, _component, _context, _options), do: :ok
  end

  defmodule RefusePrivate do
    @behaviour Snodo.Authorization

    @impl true
    def authorize(_phase, %{name: "a.private"}, _context, _options),
      do: {:error, Error.authorization(-32_003, "Blocked")}

    def authorize(_phase, _component, _context, _options), do: :ok
  end

  defmodule RefuseResourceSubscription do
    @behaviour Snodo.Subscription.Source

    @impl true
    def open(filter, context, hub) do
      filter = Map.update(filter, "resourceSubscriptions", [], fn _uris -> [] end)
      Hub.open(filter, context, hub)
    end

    @impl true
    def next(handle, hub), do: Hub.next(handle, hub)

    @impl true
    def close(handle, reason, hub), do: Hub.close(handle, reason, hub)
  end

  test "merges prefixed catalogs and routes calls, reads, and prompts" do
    proxy =
      start_supervised!({Proxy, backends: [[id: "a", target: {:direct, BackendA.runtime()}]]})

    {:ok, client} = Client.direct(Proxy.runtime(proxy))

    assert {:ok, tools} = Client.list_tools(client)
    assert Enum.map(tools, & &1["name"]) == ["a.continuation", "a.echo", "a.progress"]

    assert {:ok, [%{"name" => "a.note", "uri" => "mcp-proxy://a/test://a/note"}]} =
             Client.list_resources(client)

    assert {:ok, [%{"name" => "a.item", "uriTemplate" => "mcp-proxy://a/test://a/items/{name}"}]} =
             Client.list_resource_templates(client)

    assert {:ok, [%{"name" => "a.review"}]} = Client.list_prompts(client)

    assert {:ok, %{"content" => [%{"text" => "a:hi"}]}} =
             Client.call_tool(client, "a.echo", %{"value" => "hi"})

    assert {:ok,
            %{
              "contents" => [%{"text" => "a note", "uri" => "mcp-proxy://a/test://a/note"}]
            }} =
             Client.read_resource(client, "mcp-proxy://a/test://a/note")

    assert {:ok, %{"contents" => [%{"text" => "item book"}]}} =
             Client.read_resource(client, "mcp-proxy://a/test://a/items/book")

    assert {:ok, %{"messages" => [%{"content" => %{"text" => "review a"}}]}} =
             Client.get_prompt(client, "a.review")
  end

  test "adds and removes backends without name ambiguity" do
    proxy =
      start_supervised!({Proxy, backends: [[id: "a", target: {:direct, BackendA.runtime()}]]})

    {:ok, client} = Client.direct(Proxy.runtime(proxy))

    assert :ok = Proxy.add_backend(proxy, id: "b", target: {:direct, BackendB.runtime()})
    assert {:ok, tools} = Client.list_tools(client)

    assert Enum.map(tools, & &1["name"]) ==
             ["a.continuation", "a.echo", "a.progress", "b.echo"]

    assert {:ok, %{"content" => [%{"text" => "b:hi"}]}} =
             Client.call_tool(client, "b.echo", %{"value" => "hi"})

    assert {:error, {:tools, {:collision, "a.echo"}}} =
             Proxy.add_backend(proxy,
               id: "collision",
               prefix: "a.",
               target: {:direct, BackendB.runtime()}
             )

    assert :ok = Proxy.remove_backend(proxy, "b")
    assert {:ok, tools} = Client.list_tools(client)
    assert Enum.map(tools, & &1["name"]) == ["a.continuation", "a.echo", "a.progress"]
    assert {:error, %Error{code: -32_602}} = Client.call_tool(client, "b.echo")
  end

  test "the merged catalog uses the configured authorization policy" do
    proxy =
      start_supervised!(
        {Proxy,
         backends: [
           [id: "a", target: {:direct, BackendA.runtime()}],
           [id: "b", target: {:direct, BackendB.runtime()}]
         ]}
      )

    {:ok, client} = Client.direct(Proxy.runtime(proxy, authorization: RefuseB))
    assert {:ok, tools} = Client.list_tools(client)
    assert Enum.map(tools, & &1["name"]) == ["a.continuation", "a.echo", "a.progress"]
    assert {:error, %Error{code: -32_003}} = Client.call_tool(client, "b.echo")
  end

  test "tool and prompt resource links use the public URI" do
    proxy =
      start_supervised!(
        {Proxy, backends: [[id: "links", target: {:direct, BackendLinks.runtime()}]]}
      )

    {:ok, client} = Client.direct(Proxy.runtime(proxy))
    uri = "mcp-proxy://links/test://links/note"

    assert {:ok, %{"content" => [%{"type" => "resource_link", "uri" => ^uri}]}} =
             Client.call_tool(client, "links.link")

    assert {:ok, %{"messages" => [%{"content" => %{"uri" => ^uri}}]}} =
             Client.get_prompt(client, "links.link")

    assert {:ok, %{"contents" => [%{"text" => "linked note", "uri" => ^uri}]}} =
             Client.read_resource(client, uri)
  end

  test "forwards backend progress and input-required continuations" do
    proxy =
      start_supervised!({Proxy, backends: [[id: "a", target: {:direct, BackendA.runtime()}]]})

    {:ok, client} = Client.direct(Proxy.runtime(proxy))

    assert {:ok, %{"content" => [%{"text" => "done"}]}} =
             Client.call_tool(client, "a.progress", %{}, progress: self())

    assert_receive {:snodo_progress, %{"progress" => 50, "total" => 100}}, 1_000

    assert {:input_required, %{"requestState" => "resume"}} =
             Client.call_tool(client, "a.continuation")

    assert {:ok, %{"content" => [%{"text" => "resumed"}]}} =
             Client.call_tool(client, "a.continuation", %{}, request_state: "resume")
  end

  test "backend list changes and resource updates reach proxy listeners" do
    hub = start_supervised!(Hub)

    backend =
      BackendA.runtime(
        capabilities: %{
          "tools" => %{"listChanged" => true},
          "prompts" => %{"listChanged" => true},
          "resources" => %{"listChanged" => true, "subscribe" => true}
        },
        subscription_source: Hub.source(hub)
      )

    proxy = start_supervised!({Proxy, backends: [[id: "a", target: {:direct, backend}]]})
    {:ok, client} = Client.direct(Proxy.runtime(proxy))

    {:ok, subscription} =
      Client.listen(client, %{
        "toolsListChanged" => true,
        "resourceSubscriptions" => ["mcp-proxy://a/test://a/note"]
      })

    assert {:ok, _report} = Hub.publish(hub, Event.tools_list_changed())

    assert {:notification, "notifications/tools/list_changed", _params} =
             Subscription.next(subscription, 1_000)

    assert {:ok, _report} = Hub.publish(hub, Event.resource_updated("test://a/note"))

    assert {:notification, "notifications/resources/updated",
            %{"uri" => "mcp-proxy://a/test://a/note"}} =
             Subscription.next(subscription, 1_000)
  end

  test "subscription admission excludes resources denied by the policy" do
    proxy =
      start_supervised!({Proxy, backends: [[id: "a", target: {:direct, BackendA.runtime()}]]})

    {:ok, client} = Client.direct(Proxy.runtime(proxy, authorization: RefuseNote))
    uri = "mcp-proxy://a/test://a/note"

    assert {:ok, subscription} =
             Client.listen(client, %{"resourceSubscriptions" => [uri]})

    assert subscription.accepted["resourceSubscriptions"] == []
    assert {:error, %Error{code: -32_003}} = Client.read_resource(client, uri)
  end

  test "template instances are not acknowledged as resource subscriptions" do
    proxy =
      start_supervised!({Proxy, backends: [[id: "a", target: {:direct, BackendA.runtime()}]]})

    {:ok, client} = Client.direct(Proxy.runtime(proxy))

    assert {:ok, subscription} =
             Client.listen(client, %{
               "resourceSubscriptions" => ["mcp-proxy://a/test://a/items/book"]
             })

    assert subscription.accepted["resourceSubscriptions"] == []
  end

  test "frontend subscription admission follows the upstream accepted filter" do
    hub = start_supervised!(Hub)

    backend =
      BackendA.runtime(
        capabilities: %{"resources" => %{"subscribe" => true}},
        subscription_source: {RefuseResourceSubscription, hub}
      )

    proxy = start_supervised!({Proxy, backends: [[id: "a", target: {:direct, backend}]]})
    {:ok, client} = Client.direct(Proxy.runtime(proxy))

    assert {:ok, subscription} =
             Client.listen(client, %{
               "resourceSubscriptions" => ["mcp-proxy://a/test://a/note"]
             })

    assert subscription.accepted["resourceSubscriptions"] == []
  end

  test "resource updates are reauthorized after a backend is replaced" do
    old_hub = start_supervised!({Hub, name: :old_backend_hub}, id: :old_backend_hub)
    new_hub = start_supervised!({Hub, name: :new_backend_hub}, id: :new_backend_hub)

    old_backend =
      BackendA.runtime(
        capabilities: %{"resources" => %{"subscribe" => true}},
        subscription_source: Hub.source(old_hub)
      )

    new_backend =
      BackendRenamed.runtime(
        capabilities: %{"resources" => %{"subscribe" => true}},
        subscription_source: Hub.source(new_hub)
      )

    proxy =
      start_supervised!({Proxy, backends: [[id: "a", target: {:direct, old_backend}]]})

    {:ok, client} = Client.direct(Proxy.runtime(proxy, authorization: RefusePrivate))
    uri = "mcp-proxy://a/test://a/note"

    assert {:ok, subscription} = Client.listen(client, %{"resourceSubscriptions" => [uri]})
    assert subscription.accepted["resourceSubscriptions"] == [uri]

    assert :ok = Proxy.remove_backend(proxy, "a")
    assert :ok = Proxy.add_backend(proxy, id: "a", target: {:direct, new_backend})

    hub = Snodo.Proxy.Supervisor.child(proxy, Hub)
    assert {:ok, _report} = Hub.publish(hub, Event.resource_updated(uri))
    assert {:error, :timeout} = Subscription.next(subscription, 200)
  end

  test "catalog reads remain available while the manager is busy" do
    proxy =
      start_supervised!({Proxy, backends: [[id: "a", target: {:direct, BackendA.runtime()}]]})

    {:ok, client} = Client.direct(Proxy.runtime(proxy))
    manager = Snodo.Proxy.Supervisor.child(proxy, Manager)
    :ok = :sys.suspend(manager)

    try do
      assert {:ok, tools} = Client.list_tools(client)
      assert Enum.any?(tools, &(&1["name"] == "a.echo"))
    after
      :ok = :sys.resume(manager)
    end
  end

  test "a manager restart closes old backend workers and restores the runtime" do
    proxy =
      start_supervised!({Proxy, backends: [[id: "a", target: {:direct, BackendA.runtime()}]]})

    {:ok, client} = Client.direct(Proxy.runtime(proxy))
    old_manager = Snodo.Proxy.Supervisor.child(proxy, Manager)
    old_backend = Manager.catalog(proxy).tools["a.echo"].backend_pid
    monitor = Process.monitor(old_manager)
    Process.exit(old_manager, :kill)

    assert_receive {:DOWN, ^monitor, :process, ^old_manager, :killed}, 1_000
    new_manager = await_restarted_manager(proxy, old_manager, 2_000)
    assert Process.alive?(new_manager)

    refute Process.alive?(old_backend)
    assert {:ok, tools} = Client.list_tools(client)
    assert Enum.any?(tools, &(&1["name"] == "a.echo"))
  end

  test "public health omits backend IDs and errors" do
    proxy =
      start_supervised!({Proxy, backends: [[id: "a", target: {:direct, BackendA.runtime()}]]})

    {:ok, client} =
      Client.direct(Proxy.runtime(proxy),
        client_capabilities: %{"extensions" => %{Snodo.Proxy.Extension.id() => %{}}}
      )

    assert {:ok, %{"status" => "up"} = health} = Client.request(client, "proxy/health", %{})
    refute Map.has_key?(health, "backends")
  end

  test "HTTP backends can be served through the proxy HTTP endpoint" do
    backend_server = start_supervised!({HTTPServer, runtime: BackendB.runtime(), port: 0})

    proxy =
      start_supervised!(
        {Proxy, backends: [[id: "remote", target: {:http, HTTPServer.url(backend_server)}]]}
      )

    proxy_server =
      start_supervised!({HTTPServer, id: :proxy_http, runtime: Proxy.runtime(proxy), port: 0})

    {:ok, client} = Client.connect({:http, HTTPServer.url(proxy_server)})
    assert {:ok, [%{"name" => "remote.echo"}]} = Client.list_tools(client)

    assert {:ok, %{"content" => [%{"text" => "b:hi"}]}} =
             Client.call_tool(client, "remote.echo", %{"value" => "hi"})
  end

  test "a stdio backend participates in the merged catalog" do
    elixir = System.find_executable("elixir")
    snodo_ebin = Path.expand("../../snodo/ebin", Mix.Project.compile_path())
    fixture = Path.expand("../fixtures/stdio_backend.exs", __DIR__)

    proxy =
      start_supervised!(
        {Proxy, backends: [[id: "stdio", target: {:stdio, elixir, ["-pa", snodo_ebin, fixture]}]]}
      )

    {:ok, client} = Client.direct(Proxy.runtime(proxy))
    assert {:ok, tools} = Client.list_tools(client)
    assert Enum.any?(tools, &(&1["name"] == "stdio.echo"))

    assert {:ok, %{"content" => [%{"text" => "hi"}]}} =
             Client.call_tool(client, "stdio.echo", %{"text" => "hi"})
  end

  test "a closed stdio connection is replaced after its health probe fails" do
    elixir = System.find_executable("elixir")
    snodo_ebin = Path.expand("../../snodo/ebin", Mix.Project.compile_path())
    fixture = Path.expand("../fixtures/stdio_backend.exs", __DIR__)

    proxy =
      start_supervised!(
        {Proxy,
         health_interval_ms: 50,
         backends: [[id: "stdio", target: {:stdio, elixir, ["-pa", snodo_ebin, fixture]}]]}
      )

    old_entry = Manager.catalog(proxy).tools["stdio.echo"]
    {Stdio, transport_pid} = old_entry.client.transport
    old_backend = old_entry.backend_pid
    monitor = Process.monitor(old_backend)
    Process.exit(transport_pid, :kill)

    assert_receive {:DOWN, ^monitor, :process, ^old_backend, _reason}, 2_000
    new_backend = await_replaced_backend(proxy, "stdio.echo", old_backend, 3_000)
    assert Process.alive?(new_backend)

    {:ok, client} = Client.direct(Proxy.runtime(proxy))

    assert {:ok, %{"content" => [%{"text" => "reconnected"}]}} =
             Client.call_tool(client, "stdio.echo", %{"text" => "reconnected"})
  end

  test "a failed backend refresh marks health degraded" do
    backend_server = start_supervised!({HTTPServer, runtime: BackendB.runtime(), port: 0})

    proxy =
      start_supervised!(
        {Proxy, backends: [[id: "remote", target: {:http, HTTPServer.url(backend_server)}]]}
      )

    assert %{status: :up, error: nil} = Proxy.health(proxy)["remote"]

    :ok = stop_supervised(HTTPServer)
    assert {:error, %Error{}} = Proxy.refresh_backend(proxy, "remote")
    assert %{status: :degraded, error: %Error{}} = Proxy.health(proxy)["remote"]
  end

  defp await_restarted_manager(proxy, old_manager, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    await_restarted_manager_until(proxy, old_manager, deadline)
  end

  defp await_restarted_manager_until(proxy, old_manager, deadline) do
    manager = Registry.lookup(Snodo.Proxy.Registry, {proxy, :manager})
    catalog = Registry.lookup(Snodo.Proxy.Registry, {proxy, :catalog})

    case {manager, catalog} do
      {[{pid, _value}], [{catalog_owner, %{tools: %{"a.echo" => _entry}}}]}
      when pid != old_manager and pid == catalog_owner ->
        pid

      _not_ready ->
        if System.monotonic_time(:millisecond) >= deadline do
          flunk("proxy manager did not rebuild its catalog")
        else
          receive do
          after
            10 -> await_restarted_manager_until(proxy, old_manager, deadline)
          end
        end
    end
  end

  defp await_replaced_backend(proxy, tool, old_backend, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    await_replaced_backend_until(proxy, tool, old_backend, deadline)
  end

  defp await_replaced_backend_until(proxy, tool, old_backend, deadline) do
    entry = Manager.catalog(proxy).tools[tool]

    case entry do
      %{backend_pid: pid} when pid != old_backend ->
        pid

      _not_ready ->
        if System.monotonic_time(:millisecond) >= deadline do
          flunk("backend did not reconnect")
        else
          receive do
          after
            10 -> await_replaced_backend_until(proxy, tool, old_backend, deadline)
          end
        end
    end
  end
end
