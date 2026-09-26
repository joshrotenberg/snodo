defmodule Snodo.ClientTest do
  use ExUnit.Case, async: true

  alias Snodo.Client
  alias Snodo.Client.Page
  alias Snodo.Error
  alias Snodo.Protocol.V2025_11_25
  alias Snodo.Protocol.V2026_07_28
  alias SnodoTest.MRTR.Choice
  alias SnodoTest.MRTR.Server, as: ChoiceServer
  alias SnodoTest.TestAuthorization.Policy
  alias SnodoTest.TestFixtures
  alias SnodoTest.TestPrompts.PackageAnalysis
  alias SnodoTest.TestResources.PackageTemplate
  alias SnodoTest.TestResources.StaticText
  alias SnodoTest.TestTools.Echo

  @form_caps %{"elicitation" => %{"form" => %{}}}

  defmodule CannedTransport do
    @moduledoc false
    @behaviour Snodo.Client.Transport

    @impl true
    def connect(owner, _opts), do: {:ok, owner}

    @impl true
    def request(owner, message, opts) do
      send(owner, {:canned_request, message, opts})

      receive do
        {:canned_response, response} -> {:ok, response}
      after
        0 -> {:ok, %{"jsonrpc" => "2.0", "id" => message["id"], "result" => %{"canned" => true}}}
      end
    end

    @impl true
    def close(owner) do
      send(owner, :canned_closed)
      :ok
    end
  end

  defp client(opts \\ [], client_opts \\ []) do
    {:ok, client} = opts |> TestFixtures.runtime() |> Client.direct(client_opts)
    client
  end

  describe "direct/2" do
    test "selects the first stateless-era protocol the runtime enables" do
      runtime = TestFixtures.runtime(protocols: [V2025_11_25, V2026_07_28])

      assert {:ok, %Client{protocol: "2026-07-28", dialect: V2026_07_28}} =
               Client.direct(runtime)
    end

    test "refuses a runtime with no stateless-era protocol" do
      runtime = TestFixtures.runtime(protocols: [V2025_11_25])

      assert {:error, %Error{code: -32_602, data: %{"enabled" => ["2025-11-25"]}}} =
               Client.direct(runtime)
    end

    test "refuses an initialize-era protocol and a version the runtime does not enable" do
      runtime = TestFixtures.runtime(protocols: [V2026_07_28, V2025_11_25])

      assert {:error, %Error{code: -32_602, data: %{"requested" => "2025-11-25"}}} =
               Client.direct(runtime, protocol: "2025-11-25")

      assert {:error, %Error{code: -32_602, data: %{"requested" => "2099-01-01"}}} =
               Client.direct(runtime, protocol: "2099-01-01")
    end

    test "rejects capabilities that are not a map" do
      assert_raise ArgumentError, ~r/:client_capabilities must be a map/, fn ->
        Client.direct(TestFixtures.runtime(), client_capabilities: [:elicitation])
      end
    end
  end

  test "discover returns the discovery result without the JSON-RPC wrapper" do
    assert {:ok, result} = Client.discover(client())
    assert result["resultType"] == "complete"
    assert result["supportedVersions"] == ["2026-07-28"]
    refute Map.has_key?(result, "jsonrpc")
  end

  describe "tools" do
    test "list_tools returns the definitions and call_tool returns the result object" do
      client = client()

      assert {:ok, tools} = Client.list_tools(client)

      assert Enum.map(tools, & &1["name"]) |> Enum.sort() ==
               ~w(complex_schema context_echo echo failing raising structured)

      assert Enum.find(tools, &(&1["name"] == "echo"))["inputSchema"] == Echo.input_schema()

      assert {:ok, result} = Client.call_tool(client, "echo", %{"text" => "hello"})
      assert result["content"] == [%{"type" => "text", "text" => "hello"}]
      assert result["isError"] == false
    end

    test "a tool that reports its own failure is a successful response" do
      assert {:ok, %{"isError" => true, "content" => [%{"text" => "Actionable domain failure"}]}} =
               Client.call_tool(client(), "failing")
    end

    test "JSON-RPC errors decode into Snodo.Error with the server's code and message" do
      assert {:error, %Error{code: -32_602, kind: :protocol}} =
               Client.call_tool(client(), "no_such_tool")

      assert {:error, %Error{code: -32_603, kind: :execution, message: message}} =
               Client.call_tool(client(), "raising")

      refute message =~ "secret implementation detail"
    end

    test "capabilities and extra metadata reach the handler context" do
      client = client([], client_capabilities: @form_caps)

      assert {:ok, %{"structuredContent" => context}} =
               Client.call_tool(client, "context_echo", %{}, meta: %{"progressToken" => "p-1"})

      assert context["protocolVersion"] == "2026-07-28"
      assert context["clientCapabilities"] == @form_caps
      assert context["metadata"]["progressToken"] == "p-1"
    end
  end

  describe "pagination" do
    test "list functions follow every cursor and list_page returns one page" do
      client = client(pagination: [page_size: 2])

      assert {:ok, tools} = Client.list_tools(client)
      assert length(tools) == 6

      assert {:ok, %Page{items: first, next_cursor: cursor}} = Client.list_page(client, :tools)
      assert length(first) == 2
      assert is_binary(cursor)

      assert {:ok, %Page{items: second}} = Client.list_page(client, :tools, cursor)
      assert first ++ second == Enum.take(tools, 4)
    end

    test "an invalid cursor is a protocol error" do
      assert {:error, %Error{code: -32_602}} = Client.list_page(client(), :tools, "mcp1.bogus")
    end
  end

  describe "resources and prompts" do
    test "lists and reads resources, templates, and prompts" do
      client =
        client(resources: [StaticText, PackageTemplate], prompts: [PackageAnalysis])

      assert {:ok, [%{"uri" => "test://static/readme"}]} = Client.list_resources(client)

      assert {:ok, [%{"uriTemplate" => "test://packages/{name}"}]} =
               Client.list_resource_templates(client)

      assert {:ok, [%{"name" => "package_analysis"}]} = Client.list_prompts(client)

      assert {:ok, %{"contents" => [%{"text" => "# Static resource\n"}]}} =
               Client.read_resource(client, "test://static/readme")

      assert {:ok, %{"contents" => [%{"uri" => "test://packages/plug"}]}} =
               Client.read_resource(client, "test://packages/plug")

      assert {:ok, %{"messages" => [_first | _rest]}} =
               Client.get_prompt(client, "package_analysis", %{"name" => "plug"})
    end

    test "an unknown resource URI is an invalid-params error" do
      client = client(resources: [StaticText])

      assert {:error, %Error{code: -32_602, kind: :protocol}} =
               Client.read_resource(client, "test://missing")
    end
  end

  describe "multi round-trip requests" do
    test "input_required results retry with input_responses" do
      {:ok, client} = Client.direct(ChoiceServer.runtime(), client_capabilities: @form_caps)

      assert {:input_required, %{"inputRequests" => %{"choice" => request}}} =
               Client.call_tool(client, "choice")

      assert request == Choice.request()

      assert {:ok, %{"structuredContent" => %{"label" => "chosen"}}} =
               Client.call_tool(client, "choice", %{},
                 input_responses: %{"choice" => accepted("chosen")}
               )

      assert {:input_required, _result} = Client.read_resource(client, "choice://value")
      assert {:input_required, _result} = Client.get_prompt(client, "choice")
    end

    test "request_state carries partial answers between retries" do
      {:ok, client} = Client.direct(ChoiceServer.runtime(), client_capabilities: @form_caps)

      assert {:input_required, first} = Client.call_tool(client, "multiple_choices")
      assert Map.keys(first["inputRequests"]) |> Enum.sort() == ["first", "second"]

      assert {:input_required, second} =
               Client.call_tool(client, "multiple_choices", %{},
                 request_state: first["requestState"],
                 input_responses: %{"first" => accepted("one")}
               )

      assert Map.keys(second["inputRequests"]) == ["second"]

      assert {:ok, %{"resultType" => "complete"}} =
               Client.call_tool(client, "multiple_choices", %{},
                 request_state: second["requestState"],
                 input_responses: %{"second" => accepted("two")}
               )
    end

    test "a client without the elicitation capability gets the capability error" do
      {:ok, client} = Client.direct(ChoiceServer.runtime())
      assert {:error, %Error{code: -32_021}} = Client.call_tool(client, "choice")
    end
  end

  test "auth reaches authorization policies as context.auth" do
    policy = {Policy, %{owner: self(), allowed: %{"ada" => MapSet.new([{:tool, "echo"}])}}}
    runtime = TestFixtures.runtime(tools: [Echo], authorization: policy)

    {:ok, ada} = Client.direct(runtime, auth: %{"principal" => "ada"})
    {:ok, anonymous} = Client.direct(runtime)

    assert {:ok, [%{"name" => "echo"}]} = Client.list_tools(ada)
    assert {:ok, []} = Client.list_tools(anonymous)

    assert {:ok, _result} = Client.call_tool(ada, "echo", %{"text" => "hi"})

    assert {:error, %Error{code: code, kind: :protocol}} =
             Client.call_tool(anonymous, "echo", %{"text" => "hi"})

    assert code == Policy.refusal_code()
  end

  describe "custom transports" do
    test "connect/2 accepts any Snodo.Client.Transport and passes the dialect and timeout" do
      {:ok, client} = Client.connect({CannedTransport, self()}, timeout: 1_234)

      assert {:ok, %{"canned" => true}} = Client.call_tool(client, "anything", %{"a" => 1})
      assert_receive {:canned_request, message, opts}
      assert message["params"]["_meta"]["io.modelcontextprotocol/protocolVersion"] == "2026-07-28"
      assert opts[:dialect] == V2026_07_28
      assert opts[:timeout] == 1_234

      assert {:ok, _result} = Client.discover(client)
      assert_receive {:canned_request, _message, [dialect: V2026_07_28, timeout: 1_234]}

      assert :ok = Client.close(client)
      assert_receive :canned_closed
    end

    test "a response that is neither a result nor an error object is a transport error" do
      {:ok, client} = Client.connect({CannedTransport, self()})
      send(self(), {:canned_response, %{"jsonrpc" => "2.0", "id" => 1, "error" => "nope"}})

      assert {:error, %Error{code: -32_000, kind: :transport}} = Client.discover(client)
    end

    test "a response with both result and error is a transport error" do
      {:ok, client} = Client.connect({CannedTransport, self()})

      send(
        self(),
        {:canned_response,
         %{
           "jsonrpc" => "2.0",
           "id" => 1,
           "result" => %{},
           "error" => %{"code" => 1, "message" => "x"}
         }}
      )

      assert {:error, %Error{code: -32_000, kind: :transport}} = Client.discover(client)
    end

    test "rejects a target that is not a transport" do
      assert_raise ArgumentError, ~r/got a tuple starting with :stdio/, fn ->
        Client.connect({:stdio, "elixir"})
      end
    end

    test "rejects an invalid timeout" do
      assert_raise ArgumentError, ~r/:timeout must be/, fn ->
        Client.connect({CannedTransport, self()}, timeout: 0)
      end
    end
  end

  test "request/4 refuses subscriptions/listen before dispatch" do
    assert_raise ArgumentError, ~r/cannot stream subscriptions\/listen/, fn ->
      Client.request(client(), "subscriptions/listen", %{})
    end
  end

  test "each request takes a fresh ID, so an immutable client can be reused" do
    client = client()

    results =
      1..20
      |> Task.async_stream(fn n -> Client.call_tool(client, "echo", %{"text" => "#{n}"}) end)
      |> Enum.map(fn {:ok, {:ok, result}} -> hd(result["content"])["text"] end)

    assert results == Enum.map(1..20, &Integer.to_string/1)
  end

  defp accepted(label), do: %{"action" => "accept", "content" => %{"label" => label}}
end
