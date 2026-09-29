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
  alias SnodoTest.TestTools.Ticks

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

      assert declared([]) == %{}
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
                cause: {:no_input_handler, :url}
              }} = Client.call_tool(client, "consent")

      {:ok, client} = Client.connect({CannedTransport, self()}, input_handlers: %{form: form})

      canned(%{"inputRequests" => %{"r" => %{"method" => "roots/list"}}})

      assert {:error, %Error{code: -32_602, cause: {:no_input_handler, "roots/list"}}} =
               Client.discover(client)

      canned(%{"inputRequests" => %{"r" => %{"params" => %{}}}})

      assert {:error, %Error{code: -32_602, cause: {:no_input_handler, nil}}} =
               Client.discover(client)
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
                  cause: {:input_handler, "choice", ^reason}
                }} =
                 Client.call_tool(client, "choice")
      end

      {:ok, client} =
        Client.direct(runtime, input_handlers: %{form: fn _params -> raise "boom" end})

      assert_raise RuntimeError, "boom", fn -> Client.call_tool(client, "choice") end
    end

    test "a state-only result is sent again with its state; nothing to answer is an error" do
      form = fn _params -> {:ok, accepted("x")} end
      {:ok, client} = Client.connect({CannedTransport, self()}, input_handlers: %{form: form})

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
            {[input_handlers: %{sampling: fn _params -> :ok end}],
             ~r/unknown input handler kind :sampling/},
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

    test "every request carries clientInfo, snodo's own unless :client_info is given" do
      {:ok, client} = Client.connect({CannedTransport, self()})
      assert {:ok, _result} = Client.discover(client)
      assert_receive {:canned_request, message, _opts}
      version = to_string(Application.spec(:snodo, :vsn))

      assert message["params"]["_meta"]["io.modelcontextprotocol/clientInfo"] ==
               %{"name" => "snodo", "version" => version}

      info = %{"name" => "my-app", "version" => "2.1.0", "title" => "My App"}
      {:ok, client} = Client.connect({CannedTransport, self()}, client_info: info)
      assert {:ok, _result} = Client.call_tool(client, "anything")
      assert_receive {:canned_request, message, _opts}
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
          Client.connect({CannedTransport, self()}, client_info: invalid)
        end
      end
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
