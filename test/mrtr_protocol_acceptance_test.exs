defmodule Snodo.MRTR.ProtocolAcceptanceTest do
  use ExUnit.Case, async: true

  alias Snodo.Context
  alias Snodo.Error
  alias Snodo.MRTR
  alias Snodo.Protocol.V2026_07_28
  alias Snodo.Result
  alias Snodo.Server
  alias Snodo.Server.Executor
  alias Snodo.Transport.Context, as: TransportContext
  alias Snodo.Transport.Stdio
  alias Snodo.Transport.StreamableHTTP
  alias Snodo.Transport.StreamableHTTP.Request
  alias SnodoTest.MRTR.Choice
  alias SnodoTest.MRTR.Server, as: ChoiceServer

  @targets [
    {"tools/call", %{"name" => "choice", "arguments" => %{}}},
    {"resources/read", %{"uri" => "choice://value"}},
    {"prompts/get", %{"name" => "choice", "arguments" => %{}}}
  ]
  @transports [:direct, :stdio, :http]
  @form_caps %{"elicitation" => %{"form" => %{}}}

  @tag mcp_contract: ["mrtr-elicitation-wire"]
  test "all three feature families complete independent literal retries over every boundary" do
    for transport <- @transports, {method, params} <- @targets do
      initial = dispatch(transport, request(1, method, params))
      assert initial["id"] == 1
      assert initial["result"]["resultType"] == "input_required"
      assert initial["result"]["inputRequests"] == %{"choice" => Choice.request()}
      refute Map.has_key?(initial["result"], "ttlMs")
      refute Map.has_key?(initial["result"], "contents")
      refute Map.has_key?(initial["result"], "messages")
      refute Map.has_key?(initial["result"], "structuredContent")

      # A different ID and a freshly built runtime: no in-memory continuation.
      retry = Map.put(params, "inputResponses", %{"choice" => accepted("chosen")})
      response = dispatch(transport, request(2, method, retry))
      assert response["id"] == 2
      assert response["result"]["resultType"] == "complete"
      refute Map.has_key?(response["result"], "inputRequests")
      assert JSON.encode!(response["result"]) =~ "chosen"
    end
  end

  @tag mcp_contract: ["mrtr-elicitation-wire"]
  test "missing answers request input again and extra IDs do not affect the selected answer" do
    for transport <- @transports, {method, params} <- @targets do
      partial = Map.put(params, "inputResponses", %{"not_our_id" => %{"ignored" => [1, 2]}})

      assert dispatch(transport, request(2, method, partial))["result"]["resultType"] ==
               "input_required"

      responses = %{"not_our_id" => %{"ignored" => true}, "choice" => accepted("known")}
      retry = Map.put(params, "inputResponses", responses)
      assert dispatch(transport, request(3, method, retry))["result"]["resultType"] == "complete"
    end
  end

  @tag mcp_contract: ["mrtr-elicitation-wire", "mrtr-state-integrity"]
  test "partial answers survive fresh runtimes and only the missing input is requested again" do
    params = %{"name" => "multiple_choices", "arguments" => %{}}

    for transport <- @transports do
      first = dispatch(transport, request(20, "tools/call", params))["result"]
      assert Map.keys(first["inputRequests"]) |> Enum.sort() == ["first", "second"]

      partial =
        Map.merge(params, %{
          "requestState" => first["requestState"],
          "inputResponses" => %{"first" => accepted("one")}
        })

      second = dispatch(transport, request(21, "tools/call", partial))["result"]
      assert Map.keys(second["inputRequests"]) == ["second"]
      refute second["requestState"] == first["requestState"]

      retry =
        Map.merge(params, %{
          "requestState" => second["requestState"],
          "inputResponses" => %{"second" => accepted("two")}
        })

      final = dispatch(transport, request(22, "tools/call", retry))["result"]
      assert final["resultType"] == "complete"
      assert final["structuredContent"] == %{"first" => "one", "second" => "two"}

      tampered = Map.put(retry, "requestState", second["requestState"] <> "tampered")
      assert dispatch(transport, request(23, "tools/call", tampered))["error"]["code"] == -32_602
    end
  end

  test "decline and elicitation cancel are ordinary results, not transport cancellation" do
    for transport <- @transports, action <- ["decline", "cancel"], {method, params} <- @targets do
      retry = Map.put(params, "inputResponses", %{"choice" => %{"action" => action}})

      assert %{"id" => 4, "result" => %{"resultType" => "complete"} = result} =
               dispatch(transport, request(4, method, retry))

      assert JSON.encode!(result) =~ action
    end
  end

  test "malformed retry envelopes fail before callbacks and consumed answers preserve protocol errors" do
    for transport <- @transports, {method, params} <- @targets do
      for fields <- [
            %{"requestState" => nil},
            %{"requestState" => %{}},
            %{"inputResponses" => nil},
            %{"inputResponses" => []},
            %{"inputResponses" => %{"choice" => 1}},
            %{"inputResponses" => %{"choice" => %{"action" => "unknown"}}},
            %{"inputResponses" => %{"choice" => accepted(42)}},
            %{"inputResponses" => %{"choice" => %{"result" => accepted("wrapped")}}}
          ] do
        assert %{"error" => %{"code" => -32_602}} =
                 dispatch(transport, request(5, method, Map.merge(params, fields)))
      end
    end
  end

  @tag mcp_contract: ["mrtr-capability-admission"]
  test "capabilities are checked per request, including implicit form and URL-only clients" do
    malformed_caps = %{"elicitation" => %{"unknown" => %{}}}

    assert dispatch(:direct, request(0, "tools/call", %{"name" => "choice"}, malformed_caps))[
             "error"
           ]["code"] == -32_602

    for transport <- @transports, {method, params} <- @targets do
      for caps <- [%{}, %{"elicitation" => %{"url" => %{}}}] do
        assert %{"error" => %{"code" => -32_021, "data" => data}} =
                 dispatch(transport, request(6, method, params, caps))

        assert data == %{"requiredCapabilities" => @form_caps}
      end

      assert dispatch(transport, request(7, method, params, %{"elicitation" => %{}}))["result"][
               "resultType"
             ] ==
               "input_required"
    end

    url_params = %{"name" => "invalid_input", "arguments" => %{"variant" => "url"}}
    assert dispatch(:http, request(8, "tools/call", url_params))["error"]["code"] == -32_021
    caps = %{"elicitation" => %{"url" => %{}}}

    assert dispatch(:http, request(9, "tools/call", url_params, caps))["result"]["resultType"] ==
             "input_required"
  end

  test "invalid generated variants are internal errors while state-only and empty maps are valid" do
    for variant <- ["empty", "state_null", "bad_request", "roots"] do
      params = %{"name" => "invalid_input", "arguments" => %{"variant" => variant}}
      assert dispatch(:direct, request(10, "tools/call", params))["error"]["code"] == -32_603
    end

    for variant <- ["state_only", "empty_requests"] do
      params = %{"name" => "invalid_input", "arguments" => %{"variant" => variant}}

      assert dispatch(:direct, request(11, "tools/call", params, %{}))["result"]["resultType"] ==
               "input_required"
    end
  end

  @tag mcp_contract: ["mrtr-capability-admission"]
  test "dialect result admission rejects unsupported placements and wire escape bypasses" do
    context = context()
    result = Result.input_required(input_requests: %{"choice" => Choice.request()})

    for operation <- [
          :tools_list,
          :resources_list,
          :prompts_list,
          :completion_complete,
          :server_discover
        ] do
      assert {:error, %Error{code: -32_603}} = MRTR.validate_result(operation, result, context)
      wire = Result.wire(Map.put(result.value, "resultType", "input_required"))
      assert {:error, %Error{code: -32_603}} = MRTR.validate_result(operation, wire, context)
    end

    wire = Result.wire(Map.put(result.value, "resultType", "input_required"))

    assert {:error, %Error{code: -32_021}} =
             MRTR.validate_result({:tools_call, "choice"}, wire, %{
               context
               | client_capabilities: %{}
             })

    assert %{"error" => %{"code" => -32_600}} =
             dispatch(:direct, request(12, "elicitation/create", Choice.request()["params"]))
  end

  test "an input-required result releases its execution slot and leaves no cancellation target" do
    {:ok, executor} = start_supervised({Executor, max_concurrency: 1, max_queue: 0})
    raw = request(13, "tools/call", %{"name" => "choice"})
    work = fn _cancellation -> dispatch(:direct, raw) end
    assert {:ok, ref} = Executor.submit(executor, {:peer, 13}, work)
    assert_receive {:mcp_execution, ^executor, ^ref, {:peer, 13}, {:completed, response}}, 1_000
    assert response["result"]["resultType"] == "input_required"
    assert Executor.stats(executor).running == 0
    assert {:error, :not_found} = Executor.cancel(executor, {:peer, 13})
  end

  defp accepted(label), do: %{"action" => "accept", "content" => %{"label" => label}}

  defp context do
    %Context{
      protocol: V2026_07_28,
      protocol_version: "2026-07-28",
      transport: %TransportContext{transport: :direct},
      client_capabilities: @form_caps
    }
  end

  defp request(id, method, params, caps \\ @form_caps) do
    %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => method,
      "params" =>
        Map.put(params, "_meta", %{
          "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
          "io.modelcontextprotocol/clientCapabilities" => caps
        })
    }
  end

  defp dispatch(:direct, raw) do
    {:ok, response} =
      Server.dispatch(ChoiceServer.runtime(), raw, %TransportContext{transport: :direct})

    response
  end

  defp dispatch(:stdio, raw) do
    {:ok, input} = StringIO.open(JSON.encode!(raw) <> "\n")
    {:ok, output} = StringIO.open("")

    try do
      :ok = Stdio.serve(ChoiceServer.runtime(), input: input, output: output)
      {_input, text} = StringIO.contents(output)
      JSON.decode!(String.trim(text))
    after
      StringIO.close(input)
      StringIO.close(output)
    end
  end

  defp dispatch(:http, raw) do
    response =
      StreamableHTTP.handle(ChoiceServer.runtime(), %Request{
        method: "POST",
        path: "/mcp",
        body: JSON.encode!(raw),
        headers: [
          {"content-type", "application/json"},
          {"accept", "application/json, text/event-stream"},
          {"mcp-protocol-version", "2026-07-28"},
          {"mcp-method", raw["method"]},
          {"mcp-name", raw["params"]["name"] || raw["params"]["uri"]}
        ]
      })

    decoded = JSON.decode!(response.body)
    expected_status = if Map.has_key?(decoded, "error"), do: 400, else: 200
    assert response.status == expected_status
    assert {"content-type", "application/json"} in response.headers
    decoded
  end
end
