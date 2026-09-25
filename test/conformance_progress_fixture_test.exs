Code.require_file("../conformance/support/progress.ex", __DIR__)

defmodule SnodoTest.Conformance.ProgressFixtureTest do
  use ExUnit.Case, async: true

  alias Snodo.Server
  alias Snodo.Server.Runtime
  alias Snodo.Transport.Context, as: TransportContext
  alias Snodo.Transport.Stdio

  test "the frozen runner's exact named fixture is discoverable" do
    {:ok, listed} = Server.dispatch(runtime(), request(1, "tools/list", %{}), %TransportContext{})

    assert [%{"name" => "test_tool_with_progress", "description" => description}] =
             listed["result"]["tools"]

    assert is_binary(description)
    assert description != ""
  end

  test "direct callers without a sink get the ordinary computed result" do
    for metadata <- [%{}, %{"progressToken" => "unused-direct-token"}] do
      {:ok, response} =
        Server.dispatch(runtime(), tool(2, metadata), %TransportContext{transport: :direct})

      assert_complete(response, 2)
    end
  end

  test "stdio emits correlated 0, 50, 100 progress before each final result, never without a token" do
    messages =
      serve([
        tool(10, %{"progressToken" => "progress-test-1"}),
        tool(11, %{"progressToken" => 0}),
        tool(12, %{})
      ])

    assert length(messages) == 9

    for {id, token} <- [{10, "progress-test-1"}, {11, 0}] do
      progress = Enum.filter(messages, &(get_in(&1, ["params", "progressToken"]) == token))
      assert Enum.map(progress, & &1["params"]["progress"]) == [0, 50, 100]
      assert Enum.all?(progress, &(&1["method"] == "notifications/progress"))
      assert Enum.all?(progress, &(&1["params"]["total"] == 100))
      assert Enum.all?(progress, &is_binary(&1["params"]["message"]))
      assert Enum.all?(progress, &(not Map.has_key?(&1, "id")))
      final = Enum.find(messages, &(&1["id"] == id))
      assert_complete(final, id)
      final_index = Enum.find_index(messages, &(&1["id"] == id))

      for notification <- progress do
        assert Enum.find_index(messages, &(&1 == notification)) < final_index
      end
    end

    assert_complete(Enum.find(messages, &(&1["id"] == 12)), 12)
    assert Enum.count(messages, &(&1["method"] == "notifications/progress")) == 6
  end

  test "invalid progress tokens fail admission without computation or progress frames" do
    for token <- [nil, false, 0.5, %{}, []] do
      assert [%{"id" => 20, "error" => %{"code" => -32_602}}] =
               serve([tool(20, %{"progressToken" => token})])
    end
  end

  defp assert_complete(response, id) do
    assert response["id"] == id
    assert response["result"]["resultType"] == "complete"

    assert response["result"]["content"] == [
             %{"type" => "text", "text" => "Progress computation completed: 5050"}
           ]
  end

  defp runtime do
    Runtime.new(
      router: Snodo.Router.register_tool(Snodo.Router.new(), SnodoTest.Conformance.Progress.Tool),
      protocols: [Snodo.Protocol.V2026_07_28],
      server_info: %{"name" => "progress-conformance-test", "version" => "1.0.0"}
    )
  end

  defp tool(id, metadata),
    do:
      request(
        id,
        "tools/call",
        %{"name" => "test_tool_with_progress", "arguments" => %{}},
        metadata
      )

  defp request(id, method, params, metadata \\ %{}) do
    %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => method,
      "params" =>
        Map.put(
          params,
          "_meta",
          Map.merge(
            %{
              "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
              "io.modelcontextprotocol/clientCapabilities" => %{}
            },
            metadata
          )
        )
    }
  end

  defp serve(requests) do
    {:ok, input} = StringIO.open(Enum.map_join(requests, "", &(JSON.encode!(&1) <> "\n")))
    {:ok, output} = StringIO.open("")

    try do
      :ok = Stdio.serve(runtime(), input: input, output: output)
      {_input, text} = StringIO.contents(output)
      text |> String.split("\n", trim: true) |> Enum.map(&JSON.decode!/1)
    after
      StringIO.close(input)
      StringIO.close(output)
    end
  end
end
