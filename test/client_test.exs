defmodule Snodo.ClientTest do
  use ExUnit.Case, async: true

  alias Snodo.Client
  alias Snodo.Client.Input
  alias Snodo.Client.Page
  alias Snodo.Client.Session
  alias Snodo.Error
  alias Snodo.Protocol.V2025_06_18
  alias Snodo.Protocol.V2025_11_25
  alias Snodo.Protocol.V2026_07_28
  alias SnodoTest.MRTR.Choice
  alias SnodoTest.MRTR.Sample
  alias SnodoTest.MRTR.Server, as: ChoiceServer
  alias SnodoTest.MRTR.UrlTool
  alias SnodoTest.TestAuthorization.Policy
  alias SnodoTest.TestFixtures
  alias SnodoTest.TestPrompts.PackageAnalysis
  alias SnodoTest.TestResources.PackageTemplate
  alias SnodoTest.TestResources.StaticText
  alias SnodoTest.TestTools.Echo
  alias SnodoTest.TestTools.Ticks

  @form_caps %{"elicitation" => %{"form" => %{}}}
  @roots %{"roots" => [%{"uri" => "file:///work", "name" => "Work"}, %{"uri" => "file:///tmp"}]}

  defmodule CannedTransport do
    @moduledoc false
    # Answers each request with the next `{:canned_response, response}` in the
    # owner's mailbox, or a canned result, and reports every call to the
    # owner. `{:canned_response, response, headers}` also hands `headers` to
    # the request's `:on_response_headers`, as the HTTP transport does.
    @behaviour Snodo.Client.Transport

    @impl true
    def connect(owner, _opts) do
      send(owner, :canned_connected)
      {:ok, owner}
    end

    @impl true
    def request(owner, message, opts) do
      send(owner, {:canned_request, message, opts})

      receive do
        {:canned_response, response} ->
          {:ok, response}

        {:canned_response, response, headers} ->
          opts[:on_response_headers].(headers)
          {:ok, response}
      after
        0 -> {:ok, %{"jsonrpc" => "2.0", "id" => message["id"], "result" => %{"canned" => true}}}
      end
    end

    @impl true
    def notify(owner, message, opts) do
      send(owner, {:canned_notification, message, opts})
      :ok
    end

    @impl true
    def delete_session(owner, opts) do
      send(owner, {:canned_delete, opts})
      :ok
    end

    @impl true
    def close(owner) do
      send(owner, :canned_closed)
      :ok
    end
  end

  defmodule RequestOnlyTransport do
    @moduledoc false
    # A transport without notify/3 cannot send notifications/initialized.
    @behaviour Snodo.Client.Transport

    @impl true
    def connect(owner, _opts), do: {:ok, owner}

    @impl true
    def request(_owner, _message, _opts), do: flunk_request()

    @impl true
    def close(_owner), do: :ok

    defp flunk_request, do: raise("no request should be sent")
  end

  defp client(opts \\ [], client_opts \\ []) do
    {:ok, client} = opts |> TestFixtures.runtime() |> Client.direct(client_opts)
    client
  end

  # A canned client pinned to 2026-07-28, so no handshake precedes the test.
  defp canned_client(opts \\ []) do
    {:ok, client} = Client.connect({CannedTransport, self()}, [protocol: "2026-07-28"] ++ opts)
    assert_receive :canned_connected, 1_000
    client
  end

  @legacy_fixture [
    tools: [Echo, SnodoTest.TestTools.ContextEcho],
    resources: [StaticText],
    prompts: [PackageAnalysis],
    protocols: [V2025_11_25, V2025_06_18]
  ]

  describe "direct/2" do
    test "selects the highest allowed protocol the runtime enables" do
      runtime = TestFixtures.runtime(protocols: [V2025_11_25, V2026_07_28])

      assert {:ok, %Client{protocol: "2026-07-28", dialect: V2026_07_28, session: nil}} =
               Client.direct(runtime)

      assert {:ok, %Client{protocol: "2025-11-25", session: %Session{}}} =
               Client.direct(runtime, protocol: ["2025-11-25", "2025-06-18"])

      assert {:ok, %Client{protocol: "2026-07-28"}} =
               Client.direct(runtime, protocol: ["2025-11-25", "2026-07-28"])
    end

    test "negotiates an initialize-era version with a runtime that enables only those" do
      runtime = TestFixtures.runtime(@legacy_fixture)

      assert {:ok, %Client{protocol: "2025-11-25", dialect: V2025_11_25} = client} =
               Client.direct(runtime, client_info: %{"name" => "legacy-app", "version" => "3"})

      assert %Session{
               version: "2025-11-25",
               id: nil,
               server_info: %{"name" => "snodo-spike"},
               server_capabilities: %{"tools" => %{}, "prompts" => %{}, "resources" => %{}}
             } = client.session

      assert {:ok, tools} = Client.list_tools(client)
      assert Enum.map(tools, & &1["name"]) |> Enum.sort() == ["context_echo", "echo"]

      assert {:ok, %{"content" => [%{"text" => "legacy"}], "isError" => false} = result} =
               Client.call_tool(client, "echo", %{"text" => "legacy"})

      refute Map.has_key?(result, "resultType")

      # The initialize-era dialects carry no request metadata.
      assert {:ok, %{"structuredContent" => context}} =
               Client.call_tool(client, "context_echo")

      assert context["protocolVersion"] == "2025-11-25"
      assert context["metadata"] == %{}

      assert {:ok, %{"contents" => [%{"text" => "# Static resource\n"}]}} =
               Client.read_resource(client, "test://static/readme")

      assert {:ok, %{"messages" => [_first | _rest]}} =
               Client.get_prompt(client, "package_analysis", %{"name" => "plug"})

      assert {:ok, %{}} = Client.ping(client)
      assert :ok = Client.close(client)
    end

    test "a pinned version the runtime does not enable, or the client does not speak, is refused" do
      runtime = TestFixtures.runtime(protocols: [V2026_07_28, V2025_11_25])

      assert {:ok, %Client{protocol: "2025-11-25", session: %Session{version: "2025-11-25"}}} =
               Client.direct(runtime, protocol: "2025-11-25")

      assert {:error,
              %Error{
                code: -32_602,
                data: %{"requested" => ["2025-06-18"], "enabled" => ["2026-07-28", "2025-11-25"]}
              }} = Client.direct(runtime, protocol: "2025-06-18")

      assert {:error, %Error{code: -32_602, data: %{"requested" => "2099-01-01"}}} =
               Client.direct(runtime, protocol: "2099-01-01")

      assert {:error, %Error{code: -32_602, data: %{"requested" => "2024-11-05"} = data}} =
               Client.direct(runtime, protocol: ["2026-07-28", "2024-11-05"])

      assert data["supported"] == ["2026-07-28", "2025-11-25", "2025-06-18"]

      for invalid <- [[], :latest, ["2026-07-28", 1]] do
        assert_raise ArgumentError, ~r/:protocol must be/, fn ->
          Client.direct(runtime, protocol: invalid)
        end
      end
    end

    test "the negotiated version refuses methods its catalog does not define" do
      {:ok, client} = Client.direct(TestFixtures.runtime(@legacy_fixture))

      for method <- ["server/discover", "tasks/get", "logging/setLevel"] do
        assert {:error,
                %Error{
                  code: -32_601,
                  kind: :protocol,
                  data: %{"method" => ^method, "protocolVersion" => "2025-11-25"}
                }} = Client.request(client, method)
      end

      assert {:error, %Error{code: -32_601}} = Client.discover(client)

      # The initialize-era catalogs have no subscriptions/listen either.
      assert {:error, %Error{code: -32_601, data: %{"method" => "subscriptions/listen"}}} =
               Client.listen(client, %{"toolsListChanged" => true})

      # A stateless connection sends what the catalog does not list, since
      # extensions add methods; the server answers.
      assert {:error, %Error{code: -32_601}} = Client.request(client(), "tasks/get")
      assert {:error, %Error{code: -32_601}} = Client.ping(client())
    end

    test "the server receives and accepts the client's clientInfo" do
      info = %{"name" => "my-app", "version" => "2.1.0"}
      {:ok, client} = Client.direct(TestFixtures.runtime(), client_info: info)

      assert {:ok, %{"structuredContent" => %{"metadata" => metadata}}} =
               Client.call_tool(client, "context_echo")

      assert metadata["io.modelcontextprotocol/clientInfo"] == info
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

  describe "progress" do
    test "a progress function receives each notification, in order, before the result" do
      client = client(tools: [Ticks])
      test = self()

      assert {:ok, %{"content" => [%{"text" => "ticked 3"}]}} =
               Client.call_tool(client, "ticks", %{"count" => 3},
                 progress: &send(test, {:tick, &1})
               )

      assert [
               %{"progress" => 1, "total" => 3, "message" => "tick 1", "progressToken" => token},
               %{"progress" => 2, "progressToken" => token},
               %{"progress" => 3, "progressToken" => token}
             ] = drain(:tick)

      assert is_integer(token)
    end

    test "a pid receives {:snodo_progress, params}" do
      assert {:ok, _result} =
               Client.call_tool(client(tools: [Ticks]), "ticks", %{"count" => 2},
                 progress: self()
               )

      assert [%{"progress" => 1}, %{"progress" => 2}] = drain(:snodo_progress)
    end

    test "without :progress no token is sent and nothing is delivered" do
      assert {:ok, %{"structuredContent" => context}} =
               Client.call_tool(client(), "context_echo")

      refute Map.has_key?(context["metadata"], "progressToken")
      assert {:ok, _result} = Client.call_tool(client(tools: [Ticks]), "ticks", %{"count" => 2})
      refute_received {:snodo_progress, _params}
    end

    test ":progress refuses a second progressToken and values it cannot deliver to" do
      client = client(tools: [Ticks])

      assert_raise ArgumentError, ~r/progressToken/, fn ->
        Client.call_tool(client, "ticks", %{"count" => 1},
          progress: self(),
          meta: %{"progressToken" => "mine"}
        )
      end

      assert_raise ArgumentError, ~r/:progress must be/, fn ->
        Client.call_tool(client, "ticks", %{"count" => 1}, progress: :nobody)
      end

      assert_raise ArgumentError, ~r/:max_total_timeout must be/, fn ->
        Client.call_tool(client, "ticks", %{"count" => 1}, progress: self(), max_total_timeout: 0)
      end
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

    test "list functions request at most :max_pages pages" do
      three_pages = [pagination: [page_size: 2]]
      assert {:ok, tools} = Client.list_tools(client(three_pages, max_pages: 3))
      assert length(tools) == 6

      assert {:error, %Error{code: -32_000, kind: :transport, cause: cause}} =
               Client.list_tools(client(three_pages, max_pages: 2))

      assert cause == %{kind: :tools, max_pages: 2}
    end

    test ":max_pages must be a positive integer" do
      assert %Client{max_pages: 1_000} = client()

      assert_raise ArgumentError, ~r/:max_pages must be a positive integer/, fn ->
        Client.direct(TestFixtures.runtime(), max_pages: 0)
      end
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

  describe "input handlers" do
    test "form and URL handlers answer tool, resource, and prompt calls" do
      test = self()

      handlers = %{
        form: fn params ->
          send(test, {:form, params})
          {:ok, accepted("auto")}
        end,
        url: fn params ->
          send(test, {:url, params})
          {:ok, %{"action" => "accept"}}
        end
      }

      {:ok, client} = Client.direct(ChoiceServer.runtime(), input_handlers: handlers)

      assert {:ok, %{"structuredContent" => %{"label" => "auto"}}} =
               Client.call_tool(client, "choice")

      assert_receive {:form, %{"mode" => "form", "message" => "Choose a label"} = params}, 1_000
      assert params["requestedSchema"] == Choice.request()["params"]["requestedSchema"]

      assert {:ok, %{"contents" => [%{"text" => "auto"}]}} =
               Client.read_resource(client, "choice://value")

      assert {:ok, %{"messages" => [%{"content" => %{"text" => "auto"}}]}} =
               Client.get_prompt(client, "choice")

      assert {:ok, %{"structuredContent" => %{"action" => "accept"}}} =
               Client.call_tool(client, "consent")

      assert_receive {:url, %{"mode" => "url", "message" => "Review the terms", "url" => url}},
                     1_000

      assert url == "https://example.test/consent"
    end

    test "sampling and roots handlers answer tool, resource, and prompt calls" do
      test = self()

      handlers = %{
        sampling: fn params ->
          send(test, {:sampling, params})
          {:ok, sampled("summary of #{params["maxTokens"]}")}
        end,
        roots: fn params ->
          send(test, {:roots, params})
          {:ok, @roots}
        end
      }

      {:ok, client} = Client.direct(ChoiceServer.runtime(), input_handlers: handlers)
      summary = %{"summary" => "summary of 64", "model" => "test-model"}

      assert {:ok, %{"structuredContent" => ^summary}} = Client.call_tool(client, "sample")

      assert_receive {:sampling, %{"messages" => [message], "maxTokens" => 64} = params}, 1_000

      assert message == %{
               "role" => "user",
               "content" => %{"type" => "text", "text" => "Summarize the label"}
             }

      refute Map.has_key?(params, "tools")

      assert {:ok, %{"contents" => [%{"text" => text}]}} =
               Client.read_resource(client, "sample://value")

      assert JSON.decode!(text) == summary

      assert {:ok, %{"messages" => [%{"content" => %{"text" => text}}]}} =
               Client.get_prompt(client, "sample")

      assert JSON.decode!(text) == summary

      assert {:ok, %{"structuredContent" => %{"uris" => ["file:///work", "file:///tmp"]}}} =
               Client.call_tool(client, "roots")

      assert_receive {:roots, params}, 1_000
      assert params == %{}
    end

    test "one round can mix a form, a sampling request, and a roots request" do
      test = self()

      handlers = %{
        form: fn _params ->
          send(test, {:asked, :form})
          {:ok, accepted("mixed")}
        end,
        sampling: fn _params ->
          send(test, {:asked, :sampling})
          {:ok, sampled("mixed")}
        end,
        roots: fn _params ->
          send(test, {:asked, :roots})
          {:ok, @roots}
        end
      }

      {:ok, client} = Client.direct(ChoiceServer.runtime(), input_handlers: handlers)

      assert {:ok, %{"structuredContent" => answers}} = Client.call_tool(client, "mixed")

      assert answers == %{
               "choice" => accepted("mixed"),
               "summary" => sampled("mixed"),
               "client_roots" => @roots
             }

      # Handlers run in ID order: "choice", "client_roots", "summary".
      assert drain(:asked) == [:form, :roots, :sampling]

      # A round with one kind unhandled runs no handler at all.
      {:ok, client} =
        Client.direct(ChoiceServer.runtime(),
          input_handlers: Map.delete(handlers, :roots),
          client_capabilities: %{"roots" => %{}}
        )

      assert {:error,
              %Error{
                code: -32_602,
                data: %{"inputRequest" => "client_roots"},
                cause: {:no_input_handler, :roots, %{"inputRequests" => requests}}
              }} = Client.call_tool(client, "mixed")

      assert requests |> Map.keys() |> Enum.sort() == ["choice", "client_roots", "summary"]
      assert drain(:asked) == []
    end

    test "a sampling or roots result that is invalid for its kind is a -32603 error" do
      runtime = ChoiceServer.runtime()

      invalid = [
        {"sample", :sampling, "summary",
         %{"role" => "assistant", "content" => %{"type" => "text"}, "model" => "m"}},
        {"sample", :sampling, "summary", Map.delete(sampled("x"), "model")},
        {"sample", :sampling, "summary", %{"action" => "accept"}},
        {"roots", :roots, "client_roots", %{"roots" => [%{"uri" => "https://example.test/"}]}},
        {"roots", :roots, "client_roots", %{"roots" => %{}}},
        {"roots", :roots, "client_roots", %{"action" => "accept"}}
      ]

      for {tool, kind, id, response} <- invalid do
        {:ok, client} =
          Client.direct(runtime, input_handlers: %{kind => fn _params -> {:ok, response} end})

        assert {:error,
                %Error{
                  code: -32_603,
                  kind: :execution,
                  cause: {:input_handler, ^id, {:invalid_response, ^response}, last}
                }} = Client.call_tool(client, tool)

        assert %{"inputRequests" => %{^id => _request}} = last
      end

      # An empty roots list is a complete answer.
      {:ok, client} =
        Client.direct(runtime,
          input_handlers: %{roots: fn _params -> {:ok, %{"roots" => []}} end}
        )

      assert {:ok, %{"structuredContent" => %{"uris" => []}}} = Client.call_tool(client, "roots")
    end

    test "a server asks for sampling and roots only when the handlers declare them" do
      form = fn _params -> {:ok, accepted("x")} end
      sampling = fn params -> {:ok, sampled(Enum.join(Map.keys(params), " "))} end

      {:ok, client} = Client.direct(ChoiceServer.runtime(), input_handlers: %{form: form})

      assert {:error, %Error{code: -32_021, data: %{"requiredCapabilities" => required}}} =
               Client.call_tool(client, "sample")

      assert required == %{"sampling" => %{}}

      assert {:error, %Error{code: -32_021, data: %{"requiredCapabilities" => required}}} =
               Client.call_tool(client, "roots")

      assert required == %{"roots" => %{}}

      # The handler declares sampling alone; its settings are declared by hand.
      {:ok, client} = Client.direct(ChoiceServer.runtime(), input_handlers: %{sampling: sampling})

      assert {:error, %Error{code: -32_021, data: %{"requiredCapabilities" => required}}} =
               Client.call_tool(client, "sample", %{"tools" => true})

      assert required == %{"sampling" => %{"tools" => %{}}}

      {:ok, client} =
        Client.direct(ChoiceServer.runtime(),
          input_handlers: %{sampling: sampling},
          client_capabilities: %{"sampling" => %{"tools" => %{}}}
        )

      assert {:ok, %{"structuredContent" => %{"summary" => keys}}} =
               Client.call_tool(client, "sample", %{"tools" => true})

      assert keys == "maxTokens messages toolChoice tools"
    end

    test "a roots request may leave params out; the handler still gets a map" do
      test = self()

      roots = fn params ->
        send(test, {:roots, params})
        {:ok, @roots}
      end

      client = canned_client(input_handlers: %{roots: roots})

      canned(%{"inputRequests" => %{"r" => %{"method" => "roots/list"}}})
      assert {:ok, %{"canned" => true}} = Client.discover(client)
      assert_receive {:roots, params}, 1_000
      assert params == %{}

      assert_receive {:canned_request, %{"params" => first}, _opts}, 1_000
      refute Map.has_key?(first, "inputResponses")
      assert_receive {:canned_request, %{"params" => retry}, _opts}, 1_000
      assert retry["inputResponses"] == %{"r" => @roots}

      meta = %{"_meta" => %{"trace" => "t1"}}
      canned(%{"inputRequests" => %{"r" => %{"method" => "roots/list", "params" => meta}}})
      assert {:ok, %{"canned" => true}} = Client.discover(client)
      assert_receive {:roots, ^meta}, 1_000
    end

    test "each round sends the responses and the request state unchanged" do
      test = self()

      form = fn _params ->
        send(test, :asked)
        {:ok, accepted("x")}
      end

      {:ok, client} = Client.direct(ChoiceServer.runtime(), input_handlers: %{form: form})

      # One request per round; the second round only completes if the first
      # answer came back in the sealed state.
      assert {:ok, %{"structuredContent" => %{"first" => "x", "second" => "x"}}} =
               Client.call_tool(client, "sequential_choices")

      assert count(:asked) == 2

      # Both requests in one round.
      assert {:ok, %{"structuredContent" => %{"first" => "x", "second" => "x"}}} =
               Client.call_tool(client, "multiple_choices")

      assert count(:asked) == 2
    end

    test "the round limit stops the loop and hands back the last result" do
      test = self()

      form = fn _params ->
        send(test, :asked)
        {:ok, accepted("x")}
      end

      {:ok, client} =
        Client.direct(ChoiceServer.runtime(), input_handlers: %{form: form}, max_input_rounds: 1)

      assert {:error,
              %Error{
                code: -32_000,
                kind: :transport,
                data: %{"maxInputRounds" => 1},
                cause: {:max_input_rounds, last}
              }} = Client.call_tool(client, "sequential_choices")

      assert %{"inputRequests" => %{"second" => _request}, "requestState" => state} = last
      assert count(:asked) == 1

      # The caller can finish the flow by hand from the last result.
      assert {:ok, %{"structuredContent" => %{"first" => "x", "second" => "y"}}} =
               Client.call_tool(client, "sequential_choices", %{},
                 input_responses: %{"second" => accepted("y")},
                 request_state: state
               )

      assert count(:asked) == 0

      # A per-call limit overrides the client's, and a server that asks again
      # on every call is stopped at the limit.
      url = fn _params ->
        send(test, :asked)
        {:ok, %{"action" => "accept"}}
      end

      {:ok, client} = Client.direct(ChoiceServer.runtime(), input_handlers: %{url: url})

      assert {:error, %Error{data: %{"maxInputRounds" => 2}}} =
               Client.call_tool(client, "invalid_input", %{"variant" => "url"},
                 max_input_rounds: 2
               )

      assert count(:asked) == 2
    end

    test "the declared capabilities follow the handlers" do
      form = fn _params -> {:ok, accepted("x")} end
      url = fn _params -> {:ok, %{"action" => "accept"}} end

      assert declared(input_handlers: %{form: form}) == %{"elicitation" => %{"form" => %{}}}

      assert declared(input_handlers: %{form: form, url: url}) ==
               %{"elicitation" => %{"form" => %{}, "url" => %{}}}

      # An explicit map is kept; an empty elicitation entry still means form.
      assert declared(
               input_handlers: %{url: url},
               client_capabilities: %{"elicitation" => %{}, "experimental" => %{"x" => %{}}}
             ) ==
               %{"elicitation" => %{"form" => %{}, "url" => %{}}, "experimental" => %{"x" => %{}}}

      assert declared(input_handlers: %{form: form}, client_capabilities: %{"elicitation" => %{}}) ==
               %{"elicitation" => %{"form" => %{}}}

      sampling = fn _params -> {:ok, sampled("x")} end
      roots = fn _params -> {:ok, @roots} end

      assert declared(input_handlers: %{sampling: sampling}) == %{"sampling" => %{}}
      assert declared(input_handlers: %{roots: roots}) == %{"roots" => %{"listChanged" => false}}

      assert declared(input_handlers: %{form: form, sampling: sampling, roots: roots}) ==
               %{
                 "elicitation" => %{"form" => %{}},
                 "sampling" => %{},
                 "roots" => %{"listChanged" => false}
               }

      # Sampling settings and a roots listChanged are declared by hand and kept.
      assert declared(
               input_handlers: %{sampling: sampling, roots: roots},
               client_capabilities: %{
                 "sampling" => %{"tools" => %{}},
                 "roots" => %{"listChanged" => true}
               }
             ) == %{"sampling" => %{"tools" => %{}}, "roots" => %{"listChanged" => true}}

      # Only a handler declares sampling or roots.
      assert declared(input_handlers: %{form: form, url: url}) ==
               %{"elicitation" => %{"form" => %{}, "url" => %{}}}

      assert_raise ArgumentError, ~r/declares "roots" as true/, fn ->
        Client.direct(TestFixtures.runtime(),
          input_handlers: %{roots: roots},
          client_capabilities: %{"roots" => true}
        )
      end

      # Without handlers the declared capabilities go out as given.
      assert declared([]) == %{}
      assert declared(client_capabilities: %{"elicitation" => %{}}) == %{"elicitation" => %{}}

      assert {:ok, %Client{client_capabilities: %{"elicitation" => true}}} =
               Client.direct(TestFixtures.runtime(),
                 client_capabilities: %{"elicitation" => true}
               )

      # A handler cannot merge its entry into a value that is not a map.
      assert_raise ArgumentError, ~r/declares "elicitation" as true/, fn ->
        Client.direct(TestFixtures.runtime(),
          input_handlers: %{form: form},
          client_capabilities: %{"elicitation" => true}
        )
      end
    end

    test "answer_input: false hands the input_required result to the caller" do
      form = fn _params -> flunk("the handler was called") end
      {:ok, client} = Client.direct(ChoiceServer.runtime(), input_handlers: %{form: form})

      assert {:input_required, %{"inputRequests" => %{"choice" => _request}}} =
               Client.call_tool(client, "choice", %{}, answer_input: false)
    end

    test "a request kind with no handler is a -32602 error" do
      form = fn _params -> {:ok, accepted("x")} end

      # Declaring the URL capability by hand lets the server ask for it.
      {:ok, client} =
        Client.direct(ChoiceServer.runtime(),
          input_handlers: %{form: form},
          client_capabilities: %{"elicitation" => %{"url" => %{}}}
        )

      assert {:error,
              %Error{
                code: -32_602,
                kind: :protocol,
                data: %{"inputRequest" => "consent"},
                cause: {:no_input_handler, :url, %{"inputRequests" => %{"consent" => _}}}
              }} = Client.call_tool(client, "consent")

      client = canned_client(input_handlers: %{form: form})

      canned(%{"inputRequests" => %{"r" => %{"method" => "roots/list"}}})

      assert {:error, %Error{code: -32_602, cause: {:no_input_handler, :roots, _}}} =
               Client.discover(client)

      canned(%{"inputRequests" => %{"r" => Sample.request()}})

      assert {:error, %Error{code: -32_602, cause: {:no_input_handler, :sampling, _}}} =
               Client.discover(client)

      canned(%{"inputRequests" => %{"r" => %{"method" => "logging/setLevel", "params" => %{}}}})

      assert {:error, %Error{code: -32_602, cause: {:no_input_handler, "logging/setLevel", _}}} =
               Client.discover(client)

      canned(%{"inputRequests" => %{"r" => %{"params" => %{}}}})

      assert {:error, %Error{code: -32_602, cause: {:no_input_handler, nil, _}}} =
               Client.discover(client)
    end

    test "no handler runs unless every request in the round has one" do
      form = fn _params -> flunk("the form handler was called") end
      client = canned_client(input_handlers: %{form: form})

      requests = %{
        "1" => Choice.request(),
        "2" => UrlTool.request()
      }

      canned(%{"inputRequests" => requests, "requestState" => "s1"})

      assert {:error,
              %Error{
                code: -32_602,
                data: %{"inputRequest" => "2"},
                cause: {:no_input_handler, :url, %{"inputRequests" => ^requests}}
              }} = Client.discover(client)

      # The one request was sent and nothing was retried.
      assert_receive {:canned_request, _message, _opts}
      refute_receive {:canned_request, _message, _opts}, 100
    end

    test "handlers run in the sort order of the request IDs" do
      test = self()

      form = fn %{"message" => message} ->
        send(test, {:asked, message})
        {:ok, accepted("x")}
      end

      client = canned_client(input_handlers: %{form: form})

      requests =
        Map.new(~w(2 10 1), fn id ->
          {id, put_in(Choice.request(), ["params", "message"], "request #{id}")}
        end)

      canned(%{"inputRequests" => requests})
      assert {:ok, %{"canned" => true}} = Client.discover(client)

      assert_receive {:asked, "request 1"}
      assert_receive {:asked, "request 10"}
      assert_receive {:asked, "request 2"}
    end

    test "a malformed input request is a -32000 error and no handler runs" do
      handlers =
        Map.new([:form, :url, :sampling, :roots], fn kind ->
          {kind, fn _params -> flunk("the #{kind} handler was called") end}
        end)

      client = canned_client(input_handlers: handlers)

      form_params = Choice.request()["params"]
      url_params = UrlTool.request()["params"]
      sampling_params = Sample.request()["params"]

      malformed = [
        "junk",
        %{"method" => "elicitation/create", "params" => "junk"},
        %{"method" => "elicitation/create", "params" => nil},
        %{"method" => "elicitation/create", "params" => 7},
        %{"method" => "elicitation/create"},
        %{"method" => "elicitation/create", "params" => Map.delete(form_params, "message")},
        %{
          "method" => "elicitation/create",
          "params" => Map.delete(form_params, "requestedSchema")
        },
        %{"method" => "elicitation/create", "params" => Map.delete(url_params, "url")},
        %{"method" => "elicitation/create", "params" => Map.delete(url_params, "message")},
        %{"method" => "sampling/createMessage"},
        %{"method" => "sampling/createMessage", "params" => []},
        %{
          "method" => "sampling/createMessage",
          "params" => Map.delete(sampling_params, "messages")
        },
        %{
          "method" => "sampling/createMessage",
          "params" => Map.delete(sampling_params, "maxTokens")
        },
        %{"method" => "roots/list", "params" => "junk"},
        %{"method" => "roots/list", "params" => nil}
      ]

      for request <- malformed do
        requests = %{"r" => request}
        canned(%{"inputRequests" => requests})

        assert {:error,
                %Error{code: -32_000, kind: :transport, cause: %{"inputRequests" => ^requests}}} =
                 Client.discover(client)
      end
    end

    test "a handler failure is a -32603 error and an exception propagates" do
      runtime = ChoiceServer.runtime()

      for {handler, reason} <- [
            {fn _params -> {:error, :closed} end, :closed},
            {fn _params -> :garbage end, {:invalid_return, :garbage}},
            {fn _params -> {:ok, %{"action" => "later"}} end,
             {:invalid_response, %{"action" => "later"}}}
          ] do
        {:ok, client} = Client.direct(runtime, input_handlers: %{form: handler})

        assert {:error,
                %Error{
                  code: -32_603,
                  kind: :execution,
                  cause:
                    {:input_handler, "choice", ^reason, %{"inputRequests" => %{"choice" => _}}}
                }} =
                 Client.call_tool(client, "choice")
      end

      {:ok, client} =
        Client.direct(runtime, input_handlers: %{form: fn _params -> raise "boom" end})

      assert_raise RuntimeError, "boom", fn -> Client.call_tool(client, "choice") end
    end

    test "a state-only result is sent again with its state; nothing to answer is an error" do
      form = fn _params -> {:ok, accepted("x")} end
      client = canned_client(input_handlers: %{form: form})

      canned(%{"requestState" => "s1"})

      assert {:ok, %{"canned" => true}} =
               Client.request(client, "server/discover", %{}, progress: self())

      assert_receive {:canned_request, %{"params" => first}, first_opts}, 1_000
      refute Map.has_key?(first, "requestState")
      assert_receive {:canned_request, %{"params" => second}, second_opts}, 1_000
      assert second["requestState"] == "s1"
      refute Map.has_key?(second, "inputResponses")

      assert is_function(first_opts[:on_progress], 1) and
               is_function(second_opts[:on_progress], 1)

      canned(%{"inputRequests" => %{}})
      assert {:error, %Error{code: -32_000, kind: :transport}} = Client.discover(client)

      {:ok, client} =
        Client.direct(ChoiceServer.runtime(), input_handlers: %{form: form}, max_input_rounds: 1)

      assert {:error,
              %Error{cause: {:max_input_rounds, %{"requestState" => "unused-opaque-marker"}}}} =
               Client.call_tool(client, "invalid_input", %{"variant" => "state_only"})

      assert {:error, %Error{code: -32_000, kind: :transport}} =
               Client.call_tool(client, "invalid_input", %{"variant" => "empty_requests"})
    end

    test "options are validated" do
      runtime = TestFixtures.runtime()

      for {opts, message} <- [
            {[input_handlers: [form: fn _params -> :ok end]], ~r/:input_handlers must be a map/},
            {[input_handlers: %{logging: fn _params -> :ok end}],
             ~r/unknown input handler kind :logging/},
            {[input_handlers: %{form: fn -> :ok end}],
             ~r/:input_handlers :form must be a function of one argument/},
            {[max_input_rounds: 0], ~r/:max_input_rounds must be a positive integer/}
          ] do
        assert_raise ArgumentError, message, fn -> Client.direct(runtime, opts) end
      end

      client = client()
      assert %Client{max_input_rounds: 10, input_handlers: %{}} = client

      assert_raise ArgumentError, ~r/:answer_input must be a boolean/, fn ->
        Client.call_tool(client, "echo", %{"text" => "x"}, answer_input: :no)
      end

      assert_raise ArgumentError, ~r/:max_input_rounds must be a positive integer/, fn ->
        Client.call_tool(client, "echo", %{"text" => "x"}, max_input_rounds: -1)
      end
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
      client = canned_client(timeout: 1_234)

      assert {:ok, %{"canned" => true}} = Client.call_tool(client, "anything", %{"a" => 1})
      assert_receive {:canned_request, message, opts}, 1_000
      assert message["params"]["_meta"]["io.modelcontextprotocol/protocolVersion"] == "2026-07-28"
      assert opts[:dialect] == V2026_07_28
      assert opts[:timeout] == 1_234

      assert {:ok, _result} = Client.discover(client)
      assert_receive {:canned_request, _message, [dialect: V2026_07_28, timeout: 1_234]}, 1_000

      assert :ok = Client.close(client)
      assert_receive :canned_closed, 1_000
    end

    test "every request carries clientInfo, snodo's own unless :client_info is given" do
      client = canned_client()
      assert {:ok, _result} = Client.discover(client)
      assert_receive {:canned_request, message, _opts}, 1_000
      version = to_string(Application.spec(:snodo, :vsn))

      assert message["params"]["_meta"]["io.modelcontextprotocol/clientInfo"] ==
               %{"name" => "snodo", "version" => version}

      info = %{"name" => "my-app", "version" => "2.1.0", "title" => "My App"}
      client = canned_client(client_info: info)
      assert {:ok, _result} = Client.call_tool(client, "anything")
      assert_receive {:canned_request, message, _opts}, 1_000
      assert message["params"]["_meta"]["io.modelcontextprotocol/clientInfo"] == info
    end

    test ":client_info must name the client and its version" do
      for invalid <- [
            %{"name" => "x"},
            %{"name" => "", "version" => "1"},
            %{name: "x", version: "1"},
            "x"
          ] do
        assert_raise ArgumentError, ~r/:client_info must/, fn ->
          Client.connect({CannedTransport, self()}, client_info: invalid, protocol: "2026-07-28")
        end
      end
    end

    test "a response that is neither a result nor an error object is a transport error" do
      client = canned_client()
      send(self(), {:canned_response, %{"jsonrpc" => "2.0", "id" => 1, "error" => "nope"}})

      assert {:error, %Error{code: -32_000, kind: :transport}} = Client.discover(client)
    end

    test "a response with both result and error is a transport error" do
      client = canned_client()

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

      assert_raise ArgumentError, ~r/:probe_timeout must be/, fn ->
        Client.connect({CannedTransport, self()}, probe_timeout: -1)
      end
    end
  end

  describe "version negotiation" do
    @initialized %{
      "protocolVersion" => "2025-11-25",
      "capabilities" => %{"tools" => %{}},
      "serverInfo" => %{"name" => "canned", "version" => "1"},
      "instructions" => "canned instructions"
    }

    defp reply(result, headers \\ nil) do
      response = %{"jsonrpc" => "2.0", "id" => 0, "result" => result}
      if headers, do: send(self(), {:canned_response, response, headers})
      unless headers, do: send(self(), {:canned_response, response})
    end

    defp reply_error(code, message) do
      send(
        self(),
        {:canned_response,
         %{"jsonrpc" => "2.0", "id" => 0, "error" => %{"code" => code, "message" => message}}}
      )
    end

    test "a modern answer to the probe settles the highest version in common" do
      reply(%{"supportedVersions" => ["2026-07-28", "2025-11-25"]})

      assert {:ok, %Client{protocol: "2026-07-28", session: nil}} =
               Client.connect({CannedTransport, self()}, probe_timeout: 1_234)

      assert_receive :canned_connected, 1_000
      assert_receive {:canned_request, %{"method" => "server/discover"} = probe, opts}, 1_000
      assert probe["params"]["_meta"]["io.modelcontextprotocol/protocolVersion"] == "2026-07-28"
      assert opts[:timeout] == 1_234
      refute_received {:canned_request, _message, _opts}
      refute_received :canned_closed

      # The server lists only versions the client does not allow.
      reply(%{"supportedVersions" => ["2024-11-05"]})

      assert {:error,
              %Error{
                code: -32_602,
                data: %{
                  "requested" => ["2026-07-28", "2025-06-18"],
                  "supported" => ["2024-11-05"]
                }
              }} =
               Client.connect({CannedTransport, self()}, protocol: ["2026-07-28", "2025-06-18"])

      assert_receive :canned_closed, 1_000

      # A modern server that lists an allowed initialize-era version only is
      # initialized on the same connection.
      reply(%{"supportedVersions" => ["2025-11-25"]})
      reply(@initialized)

      assert {:ok, %Client{protocol: "2025-11-25", session: %Session{}}} =
               Client.connect({CannedTransport, self()}, protocol: ["2026-07-28", "2025-11-25"])

      assert_receive :canned_connected, 1_000
      assert_receive {:canned_request, %{"method" => "server/discover"}, _opts}, 1_000
      assert_receive {:canned_request, %{"method" => "initialize"}, _opts}, 1_000
      refute_received :canned_closed
    end

    test "any other answer to the probe reopens the transport and falls back to initialize" do
      for answer <- [
            fn -> reply_error(-32_601, "Method not found") end,
            fn -> reply_error(-32_000, "Bad Request: Server not initialized") end,
            fn -> reply(%{"canned" => true}) end,
            fn ->
              send(
                self(),
                {:canned_response, %{"jsonrpc" => "2.0", "id" => 0, "result" => "not an object"}}
              )
            end
          ] do
        answer.()
        reply(@initialized, [{"content-type", "application/json"}, {"mcp-session-id", "s-1"}])

        assert {:ok, %Client{protocol: "2025-11-25", dialect: V2025_11_25} = client} =
                 Client.connect({CannedTransport, self()},
                   client_capabilities: %{"experimental" => %{}},
                   client_info: %{"name" => "app", "version" => "9"}
                 )

        assert client.session == %Session{
                 version: "2025-11-25",
                 id: "s-1",
                 server_info: %{"name" => "canned", "version" => "1"},
                 server_capabilities: %{"tools" => %{}},
                 instructions: "canned instructions"
               }

        assert_receive :canned_connected, 1_000
        assert_receive {:canned_request, %{"method" => "server/discover"}, _opts}, 1_000
        assert_receive :canned_closed, 1_000
        assert_receive :canned_connected, 1_000
        assert_receive {:canned_request, %{"method" => "initialize"} = initialize, opts}, 1_000

        assert initialize["params"] == %{
                 "protocolVersion" => "2025-11-25",
                 "capabilities" => %{"experimental" => %{}},
                 "clientInfo" => %{"name" => "app", "version" => "9"}
               }

        refute Keyword.has_key?(opts, :headers)
        assert is_function(opts[:on_response_headers], 1)

        assert_receive {:canned_notification, %{"method" => "notifications/initialized"} = note,
                        note_opts},
                       1_000

        refute Map.has_key?(note, "id")
        assert note["params"] == %{}
        assert note_opts[:dialect] == V2025_11_25

        assert note_opts[:headers] == [
                 {"mcp-protocol-version", "2025-11-25"},
                 {"mcp-session-id", "s-1"}
               ]

        # Later requests carry the session headers, no metadata, and the
        # responder for the server's own requests.
        assert {:ok, %{"canned" => true}} = Client.request(client, "tools/list")
        assert_receive {:canned_request, %{"method" => "tools/list"} = listing, opts}, 1_000
        refute Map.has_key?(listing["params"], "_meta")
        assert opts[:headers] == note_opts[:headers]
        assert is_function(opts[:on_server_request], 1)

        assert :ok = Client.close(client)
        assert_receive {:canned_delete, delete_opts}, 1_000
        assert delete_opts[:headers] == note_opts[:headers]
        assert_receive :canned_closed, 1_000
      end
    end

    test "a pin from one era sends no probe" do
      client = canned_client()
      refute_received {:canned_request, _message, _opts}

      reply(@initialized)

      assert {:ok, %Client{session: %Session{id: nil}}} =
               Client.connect({CannedTransport, self()}, protocol: "2025-11-25")

      assert_receive :canned_connected, 1_000
      assert_receive {:canned_request, %{"method" => "initialize"}, _opts}, 1_000
      refute_received :canned_closed
      assert :ok = Client.close(client)
      refute_received {:canned_delete, _opts}
    end

    test "a negotiated version the client does not allow ends the connection" do
      reply(Map.put(@initialized, "protocolVersion", "2025-06-18"))

      assert {:error,
              %Error{
                code: -32_602,
                data: %{"negotiated" => "2025-06-18", "requested" => ["2025-11-25"]}
              }} = Client.connect({CannedTransport, self()}, protocol: "2025-11-25")

      assert_receive :canned_closed, 1_000
      refute_received {:canned_notification, _message, _opts}

      # The server may pick a lower version the client allows.
      reply(Map.put(@initialized, "protocolVersion", "2025-06-18"))

      assert {:ok, %Client{protocol: "2025-06-18", dialect: V2025_06_18}} =
               Client.connect({CannedTransport, self()}, protocol: ["2025-11-25", "2025-06-18"])

      assert_receive {:canned_request, %{"method" => "initialize"} = initialize, _opts}, 1_000
      assert initialize["params"]["protocolVersion"] == "2025-11-25"
    end

    test "an error or an unusable result from initialize ends the connection" do
      reply_error(-32_602, "initialize requires protocolVersion")

      assert {:error, %Error{code: -32_602, kind: :protocol}} =
               Client.connect({CannedTransport, self()}, protocol: "2025-11-25")

      assert_receive :canned_closed, 1_000

      reply(%{"serverInfo" => %{}})

      assert {:error, %Error{code: -32_000, kind: :transport}} =
               Client.connect({CannedTransport, self()}, protocol: "2025-06-18")

      assert_receive :canned_closed, 1_000
    end

    test "a transport without notify/3 cannot open an initialize-era connection" do
      assert {:error, %Error{code: -32_602, message: message}} =
               Client.connect({RequestOnlyTransport, self()}, protocol: "2025-11-25")

      assert message =~ "no notify/3"
    end
  end

  describe "Input.answer_request/2" do
    test "answers the server's own requests through the installed handlers" do
      handlers = %{form: fn %{"message" => message} -> {:ok, accepted(message)} end}

      form = %{
        "jsonrpc" => "2.0",
        "id" => "srv-1",
        "method" => "elicitation/create",
        "params" => %{"message" => "label", "requestedSchema" => %{"type" => "object"}}
      }

      assert Input.answer_request(handlers, form) ==
               %{"jsonrpc" => "2.0", "id" => "srv-1", "result" => accepted("label")}

      assert Input.answer_request(%{}, %{"jsonrpc" => "2.0", "id" => 7, "method" => "ping"}) ==
               %{"jsonrpc" => "2.0", "id" => 7, "result" => %{}}

      # No handler for the kind, or no kind for the method.
      url = put_in(form, ["params"], %{"mode" => "url", "message" => "m", "url" => "https://x"})

      for request <- [url, %{form | "method" => "roots/list"}] do
        assert %{"error" => %{"code" => -32_601}} = Input.answer_request(handlers, request)
      end

      assert %{"error" => %{"code" => -32_601}} = Input.answer_request(%{}, form)

      # Params without the kind's keys.
      for params <- [nil, "junk", %{"message" => "only"}] do
        assert %{"id" => "srv-1", "error" => %{"code" => -32_602}} =
                 Input.answer_request(handlers, Map.put(form, "params", params))
      end

      # A handler that fails, or returns something that is not a response.
      for handler <- [
            fn _params -> {:error, :closed} end,
            fn _params -> :garbage end,
            fn _params -> {:ok, %{"action" => "later"}} end
          ] do
        assert %{"error" => %{"code" => -32_603}} =
                 Input.answer_request(%{form: handler}, form)
      end

      assert_raise RuntimeError, "boom", fn ->
        Input.answer_request(%{form: fn _params -> raise "boom" end}, form)
      end
    end
  end

  test "request/4 refuses subscriptions/listen before dispatch" do
    assert_raise ArgumentError, ~r/open it with Snodo.Client.listen\/3/, fn ->
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

  defp sampled(text) do
    %{
      "role" => "assistant",
      "content" => %{"type" => "text", "text" => text},
      "model" => "test-model",
      "stopReason" => "endTurn"
    }
  end

  defp declared(opts) do
    {:ok, client} = Client.direct(TestFixtures.runtime(), opts)

    {:ok, %{"structuredContent" => %{"clientCapabilities" => capabilities}}} =
      Client.call_tool(client, "context_echo")

    capabilities
  end

  # An input_required result for CannedTransport to answer the next request with.
  defp canned(result) do
    result = Map.put(result, "resultType", "input_required")
    send(self(), {:canned_response, %{"jsonrpc" => "2.0", "id" => 0, "result" => result}})
  end

  defp count(tag) do
    receive do
      ^tag -> 1 + count(tag)
    after
      0 -> 0
    end
  end

  defp drain(tag) do
    receive do
      {^tag, params} -> [params | drain(tag)]
    after
      0 -> []
    end
  end
end
