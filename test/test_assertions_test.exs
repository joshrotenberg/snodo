defmodule Snodo.TestAssertionsTest do
  use ExUnit.Case, async: true

  import Snodo.Test.Assertions

  alias ExUnit.AssertionError
  alias Snodo.Client
  alias Snodo.Error
  alias SnodoTest.MRTR.Choice
  alias SnodoTest.MRTR.Server, as: ChoiceServer
  alias SnodoTest.TestAuthorization.Policy

  defmodule Server do
    use Snodo.Server, name: "assertions-test", version: "1.0.0"

    alias Snodo.Result

    tool "greet", description: "Create a greeting" do
      argument("name", :string, required: true)

      @impl true
      def call(%{"name" => name}, context) do
        {:ok, Result.text("Hello, #{name}! (#{inspect(context.auth)})")}
      end
    end

    tool "divide" do
      argument("by", :integer, required: true)

      @impl true
      def call(%{"by" => 0}, _context), do: {:ok, Result.error("Division by zero")}
      def call(%{"by" => by}, _context), do: {:ok, Result.structured(%{"value" => div(12, by)})}
    end

    tool "reject" do
      @impl true
      def call(_arguments, _context) do
        {:error, Error.invalid_params("Nothing to reject", %{"field" => "name"})}
      end
    end

    resource "notes", uri: "index://notes" do
      @impl true
      def read(_params, _context), do: {:ok, "notes"}
    end

    resource "note", uri_template: "notes://{id}" do
      @impl true
      def read(%{"id" => id}, _context), do: {:ok, "note #{id}"}
    end

    prompt "review" do
      @impl true
      def render(_arguments, _context), do: {:ok, "Review it."}
    end
  end

  @refused Policy.refusal_code()
  @form_answer %{"action" => "accept", "content" => %{"label" => "canned"}}

  defp runtime, do: Server.runtime()

  defp policy_runtime do
    allowed = %{"reader" => MapSet.new([{:tool, "greet"}])}
    Server.runtime(authorization: {Policy, %{owner: nil, allowed: allowed}})
  end

  # Hides a literal from the type checker, which would flag an invalid argument.
  defp opaque(value), do: value |> :erlang.term_to_binary() |> :erlang.binary_to_term()

  defp failure(fun) do
    error = assert_raise AssertionError, fun
    error.message
  end

  describe "client!/2 and client_as/3" do
    test "builds a direct client, and runs requests as a principal" do
      client = client!(runtime())
      assert %Client{protocol: "2026-07-28"} = client

      reader = client_as(runtime(), %{"principal" => "reader"})
      result = assert_tool_ok(Client.call_tool(reader, "greet", %{"name" => "Ada"}))
      assert [%{"text" => text}] = result["content"]
      assert text =~ ~s(%{"principal" => "reader"})
    end

    test "fails with the runtime's error when it refuses a direct client" do
      message = failure(fn -> client!(runtime(), protocol: "2025-06-18") end)

      assert message =~ "Expected a direct client for the runtime, got an error"
      assert message =~ "code: -32602"
      assert message =~ ~s(message: "Protocol version is not enabled")
    end

    test ":answers answers input requests inside the call" do
      client = client!(ChoiceServer.runtime(), answers: %{form: @form_answer})

      result = assert_tool_ok(Client.call_tool(client, "choice"))
      assert result["structuredContent"] == %{"label" => "canned"}

      test = self()

      answer = fn params ->
        send(test, {:asked, params["message"]})
        %{"action" => "accept", "content" => %{"label" => "computed"}}
      end

      client = client!(ChoiceServer.runtime(), answers: [form: answer])
      result = assert_tool_ok(Client.call_tool(client, "choice"))
      assert result["structuredContent"] == %{"label" => "computed"}
      assert_receive {:asked, "Choose a label"}, 1_000
    end

    test ":answers rejects an unknown kind or a bad answer" do
      assert_raise ArgumentError, ~r/:answers takes a kind/, fn ->
        client!(runtime(), answers: %{email: %{}})
      end

      assert_raise ArgumentError, ~r/:answers takes a kind/, fn ->
        client!(runtime(), answers: %{form: "yes"})
      end

      assert_raise ArgumentError, ~r/:answers must be a map/, fn ->
        client!(runtime(), answers: "yes")
      end
    end
  end

  describe "assert_tool_ok/1" do
    test "returns the result from a client or a dispatch" do
      client = client!(runtime())

      assert %{"structuredContent" => %{"value" => 4}} =
               assert_tool_ok(Client.call_tool(client, "divide", %{"by" => 3}))

      dispatched =
        Snodo.Test.dispatch(runtime(),
          protocol: "2026-07-28",
          method: "tools/call",
          params: %{"name" => "divide", "arguments" => %{"by" => 4}}
        )

      assert %{"structuredContent" => %{"value" => 3}} = assert_tool_ok(dispatched)

      {:ok, response} = dispatched
      assert %{"structuredContent" => %{"value" => 3}} = assert_tool_ok(response)
    end

    test "fails with the isError content" do
      client = client!(runtime())

      message =
        failure(fn -> assert_tool_ok(Client.call_tool(client, "divide", %{"by" => 0})) end)

      assert message == """
             Expected a successful tool result, got isError: true
             content:
                 Division by zero\
             """
    end

    test "fails with the protocol error" do
      client = client!(runtime())
      message = failure(fn -> assert_tool_ok(Client.call_tool(client, "reject")) end)

      assert message == """
             Expected a successful tool result, got an error response
             code: -32602
             message: "Nothing to reject"
             data: %{"field" => "name"}\
             """

      message = failure(fn -> assert_tool_ok(Client.call_tool(client, "missing")) end)
      assert message =~ "code: -32602"
      assert message =~ "missing"
    end

    test "fails with the input requests of an input_required result" do
      client = client!(ChoiceServer.runtime(), client_capabilities: %{"elicitation" => %{}})
      message = failure(fn -> assert_tool_ok(Client.call_tool(client, "choice")) end)

      assert message =~ "Expected a successful tool result, got input_required\ninputRequests:"
      assert message =~ ~s(  "choice": form elicitation %{)
      assert message =~ "Choose a label"
    end

    test "fails for a value that is not a response, and for a stream" do
      assert failure(fn -> assert_tool_ok(opaque(:nope)) end) ==
               "Expected a successful tool result, got a value that is not a response\n" <>
                 "value: :nope"

      assert failure(fn -> assert_tool_ok(opaque({:stream, make_ref()})) end) ==
               "Expected a successful tool result, got a subscriptions/listen stream"
    end
  end

  describe "assert_tool_error/2" do
    test "returns an isError result, optionally matching its text" do
      response = Client.call_tool(client!(runtime()), "divide", %{"by" => 0})

      assert %{"isError" => true} = assert_tool_error(response)
      assert %{"isError" => true} = assert_tool_error(response, "by zero")
      assert %{"isError" => true} = assert_tool_error(response, ~r/^Division/)
    end

    test "fails when the text does not match" do
      response = Client.call_tool(client!(runtime()), "divide", %{"by" => 0})

      assert failure(fn -> assert_tool_error(response, "overflow") end) == """
             Expected the isError content to match "overflow"
             content:
                 Division by zero\
             """
    end

    test "fails for a successful result or an error response" do
      client = client!(runtime())

      message =
        failure(fn -> assert_tool_error(Client.call_tool(client, "divide", %{"by" => 1})) end)

      assert message =~ "Expected a tool result with isError: true, got a successful result\n"
      assert message =~ ~s("value" => 12)

      message = failure(fn -> assert_tool_error(Client.call_tool(client, "reject")) end)
      assert message =~ "Expected a tool result with isError: true, got an error response\n"
      assert message =~ ~s(message: "Nothing to reject")
    end
  end

  describe "assert_input_required/2 and answer_input/2" do
    setup do
      client = client!(ChoiceServer.runtime(), client_capabilities: %{"elicitation" => %{}})
      %{client: client}
    end

    test "returns the result, and answers it on the next call", %{client: client} do
      result = assert_input_required(Client.call_tool(client, "choice"), :form)
      assert result["inputRequests"]["choice"] == Choice.request()

      opts = answer_input(result, form: @form_answer)
      assert opts == [input_responses: %{"choice" => @form_answer}]

      response = Client.call_tool(client, "choice", %{}, opts)
      assert assert_tool_ok(response)["structuredContent"] == %{"label" => "canned"}

      # An ID key wins over a kind key, and a function receives the params.
      opts =
        answer_input({:input_required, result}, %{
          :form => %{"action" => "decline"},
          "choice" => fn %{"message" => message} ->
            %{"action" => "accept", "content" => %{"label" => message}}
          end
        })

      assert [input_responses: %{"choice" => %{"content" => %{"label" => "Choose a label"}}}] =
               opts

      opts = answer_input(result, %{"choice" => %{"action" => "decline"}})
      assert opts == [input_responses: %{"choice" => %{"action" => "decline"}}]
    end

    test "answer_input/2 carries the request state" do
      result = %{
        "resultType" => "input_required",
        "inputRequests" => %{"choice" => Choice.request()},
        "requestState" => "opaque"
      }

      assert answer_input(result, form: @form_answer) == [
               input_responses: %{"choice" => @form_answer},
               request_state: "opaque"
             ]

      assert answer_input(%{"requestState" => "only"}, []) == [
               input_responses: %{},
               request_state: "only"
             ]
    end

    test "answer_input/2 fails for an input request without an answer", %{client: client} do
      result = assert_input_required(Client.call_tool(client, "choice"))
      message = failure(fn -> answer_input(result, url: %{"action" => "accept"}) end)

      assert message =~ ~s(No answer for input request "choice", a form elicitation\nrequest: )
      assert message =~ "elicitation/create"
    end

    test "fails when no input request is of the kind", %{client: client} do
      message =
        failure(fn -> assert_input_required(Client.call_tool(client, "choice"), :sampling) end)

      assert message =~ "Expected an input_required result with a sampling request\n"
      assert message =~ ~s("choice": form elicitation)
    end

    test "fails for a complete result or an error response" do
      client = client!(runtime())

      message =
        failure(fn -> assert_input_required(Client.call_tool(client, "divide", %{"by" => 2})) end)

      assert message =~ "Expected an input_required result, got a complete result\nresult: "

      message = failure(fn -> assert_input_required(Client.call_tool(client, "reject")) end)
      assert message =~ "Expected an input_required result, got an error response\ncode: -32602"
    end
  end

  describe "assert_refused/2" do
    test "returns the error, optionally checking its code" do
      reader = client_as(policy_runtime(), %{"principal" => "reader"})
      response = Client.call_tool(reader, "divide", %{"by" => 2})

      assert %Error{code: @refused, message: "Application policy refused tool:divide"} =
               assert_refused(response)

      assert %Error{data: %{"component" => "tool:divide"}} = assert_refused(response, @refused)

      dispatched =
        Snodo.Test.dispatch(policy_runtime(),
          protocol: "2026-07-28",
          method: "tools/call",
          params: %{"name" => "divide", "arguments" => %{"by" => 2}}
        )

      assert %Error{code: @refused} = assert_refused(dispatched, @refused)
    end

    test "fails with the actual error when the code differs" do
      response = Client.call_tool(client!(runtime()), "reject")

      assert failure(fn -> assert_refused(response, @refused) end) == """
             Expected an error response with code -32003, got code -32602
             code: -32602
             message: "Nothing to reject"
             data: %{"field" => "name"}\
             """
    end

    test "fails for a result or an input_required result" do
      message =
        failure(fn ->
          assert_refused(Client.call_tool(client!(runtime()), "divide", %{"by" => 0}))
        end)

      assert message =~ "Expected an error response, got a result\nresult: "
      assert message =~ ~s("isError" => true)

      client = client!(ChoiceServer.runtime(), client_capabilities: %{"elicitation" => %{}})
      message = failure(fn -> assert_refused(Client.call_tool(client, "choice")) end)
      assert message =~ "Expected an error response, got input_required\n"
    end
  end

  describe "assert_listed/2 and refute_listed/2" do
    test "find entries by name, URI, or URI template in every list shape" do
      client = client!(runtime())

      assert %{"name" => "greet"} = assert_listed(Client.list_tools(client), "greet")
      assert %{"name" => "notes"} = assert_listed(Client.list_resources(client), "index://notes")

      assert %{"name" => "note"} =
               assert_listed(Client.list_resource_templates(client), "notes://{id}")

      assert %{"name" => "review"} = assert_listed(Client.list_prompts(client), "review")

      {:ok, page} = Client.list_page(client, :tools)
      assert %{"name" => "divide"} = assert_listed(page, "divide")
      assert %{"name" => "divide"} = assert_listed(Client.request(client, "tools/list"), "divide")

      dispatched = Snodo.Test.dispatch(runtime(), protocol: "2026-07-28", method: "prompts/list")
      assert %{"name" => "review"} = assert_listed(dispatched, "review")

      assert [%{"name" => "greet"}] = refute_listed([%{"name" => "greet"}], "divide")
    end

    test "show what a principal may discover" do
      reader = client_as(policy_runtime(), %{"principal" => "reader"})

      assert %{"name" => "greet"} = assert_listed(Client.list_tools(reader), "greet")
      assert [%{"name" => "greet"}] = refute_listed(Client.list_tools(reader), "divide")
    end

    test "fail with the listed names" do
      reader = client_as(policy_runtime(), %{"principal" => "reader"})

      assert failure(fn -> assert_listed(Client.list_tools(reader), "divide") end) ==
               ~s(Expected a list including "divide"\nlisted: ["greet"])

      assert failure(fn -> refute_listed(Client.list_tools(reader), "greet") end) ==
               ~s(Expected a list without "greet"\nlisted: ["greet"])
    end

    test "fail for an error response or a result that is not a list" do
      client = client!(runtime())
      message = failure(fn -> assert_listed(Client.request(client, "nope/list"), "x") end)
      assert message =~ ~s(Expected a list including "x", got an error response\ncode: -32601)

      message = failure(fn -> assert_listed(Client.discover(client), "x") end)
      assert message =~ ~s(Expected a list including "x", got a result that is not a list\n)
    end
  end
end
