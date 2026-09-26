defmodule Snodo.Transport.StreamableHTTP.AdapterAcceptanceTest do
  use ExUnit.Case, async: true

  alias Snodo.Transport.StreamableHTTP
  alias Snodo.Transport.StreamableHTTP.Request
  alias Snodo.Transport.StreamableHTTP.Response
  alias Snodo.Transport.StreamableHTTP.StreamResponse
  alias SnodoTest.TestCompletions.PackagePrompt
  alias SnodoTest.TestExtensions.HTTPPolicy
  alias SnodoTest.TestFixtures
  alias SnodoTest.TestPrompts.PackageAnalysis
  alias SnodoTest.TestResources.StaticText
  alias SnodoTest.TestSubscriptionHub
  alias SnodoTest.TestSubscriptionSource
  alias SnodoTest.TestTools.Echo
  alias SnodoTest.TestTools.Structured

  @protocol "2026-07-28"

  @tag mcp_contract: ["subscriptions-http-adapter"]
  test "returns a long-lived SSE descriptor only for subscriptions/listen" do
    {:ok, hub} = start_supervised({TestSubscriptionHub, owner: self()})

    runtime =
      TestFixtures.runtime(
        capabilities: %{"tools" => %{"listChanged" => true}},
        subscription_source: {TestSubscriptionSource, hub}
      )

    raw =
      TestFixtures.request("adapter-sub", "subscriptions/listen", %{
        "notifications" => %{"toolsListChanged" => true}
      })

    response = StreamableHTTP.handle(runtime, request(raw))
    assert %StreamResponse{status: 200, subscription: subscription} = response

    assert {"content-type", "text/event-stream"} in response.headers
    assert {"x-accel-buffering", "no"} in response.headers
    assert_receive {:subscription_opened, "adapter-sub", %{"toolsListChanged" => true}}

    assert :ok = Snodo.Subscription.close(subscription, :disconnected)
    assert_receive {:subscription_closed, "adapter-sub", :disconnected}
  end

  describe "Host and Origin admission" do
    setup do
      raw = TestFixtures.request("host", "server/discover")
      %{raw: raw, runtime: TestFixtures.runtime()}
    end

    defp status(runtime, raw, extra_headers, opts) do
      StreamableHTTP.handle(runtime, request(raw, headers: extra_headers ++ headers(raw)), opts).status
    end

    test "any Host is admitted unless :allowed_hosts is set", %{raw: raw, runtime: runtime} do
      assert status(runtime, raw, [{"Host", "evil.example.com"}], []) == 200
    end

    test ":allowed_hosts refuses other hosts and a missing Host", %{raw: raw, runtime: runtime} do
      opts = [allowed_hosts: ["localhost", "127.0.0.1", "::1"]]

      assert status(runtime, raw, [{"Host", "localhost:4000"}], opts) == 200
      assert status(runtime, raw, [{"Host", "127.0.0.1"}], opts) == 200
      assert status(runtime, raw, [{"Host", "[::1]:4000"}], opts) == 200
      assert status(runtime, raw, [{"Host", "LOCALHOST:4000"}], opts) == 200
      assert status(runtime, raw, [{"Host", "evil.example.com"}], opts) == 403
      assert status(runtime, raw, [{"Host", "localhost.evil.example.com:4000"}], opts) == 403
      assert status(runtime, raw, [], opts) == 403
    end

    test "an Origin with userinfo is refused", %{raw: raw, runtime: runtime} do
      assert status(runtime, raw, [{"Origin", "http://localhost:4000"}], []) == 200
      assert status(runtime, raw, [{"Origin", "http://user@localhost:4000"}], []) == 403
    end

    test "an allowlist entry with a port pins it", %{raw: raw, runtime: runtime} do
      opts = [allowed_origin_hosts: ["localhost:3000", "127.0.0.1"]]

      assert status(runtime, raw, [{"Origin", "http://localhost:3000"}], opts) == 200
      assert status(runtime, raw, [{"Origin", "http://localhost:4000"}], opts) == 403
      assert status(runtime, raw, [{"Origin", "http://127.0.0.1:9999"}], opts) == 200
    end
  end

  @tag mcp_contract: ["streamable-http-admission"]
  test "accepts a response object with 202 and no body" do
    raw = %{"jsonrpc" => "2.0", "id" => 9, "result" => %{}}

    request = %Request{
      method: "POST",
      path: "/mcp",
      headers: [
        {"Content-Type", "application/json"},
        {"Accept", "application/json, text/event-stream"},
        {"MCP-Protocol-Version", @protocol}
      ],
      body: JSON.encode!(raw),
      peer: {{127, 0, 0, 1}, 50_000},
      connection_ref: make_ref()
    }

    assert %Response{status: 202, body: ""} =
             StreamableHTTP.handle(TestFixtures.runtime(tools: [Echo]), request)
  end

  test "serves final-era discovery over a sessionless JSON response" do
    runtime = TestFixtures.runtime()
    raw = TestFixtures.request("discover-http", "server/discover")

    request =
      request(raw,
        headers: [{"Mcp-Session-Id", "ignored-by-final-era"} | headers(raw)]
      )

    response = StreamableHTTP.handle(runtime, request)

    assert response.status == 200
    assert {"content-type", "application/json"} in response.headers

    refute Enum.any?(response.headers, fn {name, _value} ->
             String.downcase(name) == "mcp-session-id"
           end)

    assert %{
             "id" => "discover-http",
             "result" => %{
               "supportedVersions" => [@protocol],
               "capabilities" => %{"tools" => %{}}
             }
           } = JSON.decode!(response.body)
  end

  test "enforces protocol, method, and name mirrors with correlated errors" do
    runtime = TestFixtures.runtime()

    raw =
      TestFixtures.request(41, "tools/call", %{
        "name" => "echo",
        "arguments" => %{"text" => "accepted"}
      })

    cases = [
      {delete_header(headers(raw), "mcp-protocol-version"), "missing protocol"},
      {replace_header(headers(raw), "mcp-protocol-version", "1900-01-01"), "version mismatch"},
      {delete_header(headers(raw), "mcp-method"), "missing method"},
      {replace_header(headers(raw), "mcp-method", "tools/list"), "method mismatch"},
      {delete_header(headers(raw), "mcp-name"), "missing name"},
      {replace_header(headers(raw), "mcp-name", "another-tool"), "name mismatch"}
    ]

    Enum.each(cases, fn {request_headers, label} ->
      response = StreamableHTTP.handle(runtime, request(raw, headers: request_headers))
      assert response.status == 400, label

      assert %{"id" => 41, "error" => %{"code" => -32_020}} =
               JSON.decode!(response.body),
             label
    end)

    whitespace_headers = replace_header(headers(raw), "mcp-name", "  echo\t")
    response = StreamableHTTP.handle(runtime, request(raw, headers: whitespace_headers))
    assert response.status == 200

    assert get_in(JSON.decode!(response.body), ["result", "content", Access.at(0), "text"]) ==
             "accepted"

    encoded_headers = replace_header(headers(raw), "mcp-name", "=?base64?ZWNobw==?=")
    response = StreamableHTTP.handle(runtime, request(raw, headers: encoded_headers))
    assert response.status == 200
  end

  test "resources/read mirrors the URI through Mcp-Name and dispatches the same runtime" do
    runtime = TestFixtures.runtime(resources: [StaticText])

    raw =
      TestFixtures.request("resource-http", "resources/read", %{
        "uri" => "test://static/readme"
      })

    missing_name = delete_header(headers(raw), "mcp-name")
    response = StreamableHTTP.handle(runtime, request(raw, headers: missing_name))
    assert response.status == 400

    assert %{"id" => "resource-http", "error" => %{"code" => -32_020}} =
             JSON.decode!(response.body)

    wrong_name = replace_header(headers(raw), "mcp-name", "test://static/other")
    response = StreamableHTTP.handle(runtime, request(raw, headers: wrong_name))
    assert response.status == 400

    encoded_uri = "=?base64?#{Base.encode64("test://static/readme")}?="
    encoded_headers = replace_header(headers(raw), "mcp-name", encoded_uri)
    response = StreamableHTTP.handle(runtime, request(raw, headers: encoded_headers))
    assert response.status == 200

    assert get_in(JSON.decode!(response.body), ["result", "contents", Access.at(0), "text"]) ==
             "# Static resource\n"
  end

  @tag mcp_contract: ["prompts-routing-wire", "streamable-http-admission"]
  test "prompts/get mirrors its name and shares the prompt runtime" do
    runtime = TestFixtures.runtime(prompts: [PackageAnalysis])

    raw =
      TestFixtures.request("prompt-http", "prompts/get", %{
        "name" => "package_analysis",
        "arguments" => %{"name" => "ecto"}
      })

    missing_name = delete_header(headers(raw), "mcp-name")
    response = StreamableHTTP.handle(runtime, request(raw, headers: missing_name))
    assert response.status == 400

    assert %{"id" => "prompt-http", "error" => %{"code" => -32_020}} =
             JSON.decode!(response.body)

    response = StreamableHTTP.handle(runtime, request(raw))
    assert response.status == 200

    assert %{
             "result" => %{
               "resultType" => "complete",
               "description" => "Analysis workflow for ecto",
               "messages" => [%{"role" => "user"}, %{"role" => "assistant"}]
             }
           } = JSON.decode!(response.body)
  end

  @tag mcp_contract: ["completion-routing-wire", "streamable-http-admission"]
  test "completion/complete uses protocol and method headers without an Mcp-Name mirror" do
    runtime = TestFixtures.runtime(tools: [], prompts: [PackagePrompt])

    raw =
      TestFixtures.request("completion-http", "completion/complete", %{
        "ref" => %{"type" => "ref/prompt", "name" => "package_search"},
        "argument" => %{"name" => "name", "value" => "ec"}
      })

    response = StreamableHTTP.handle(runtime, request(raw))
    assert response.status == 200

    assert %{
             "result" => %{
               "resultType" => "complete",
               "completion" => %{
                 "values" => ["ecto", "ecto_sql"],
                 "total" => 2,
                 "hasMore" => false
               }
             }
           } = JSON.decode!(response.body)

    missing_method = delete_header(headers(raw), "mcp-method")
    rejected = StreamableHTTP.handle(runtime, request(raw, headers: missing_method))
    assert rejected.status == 400
    assert %{"error" => %{"code" => -32_020}} = JSON.decode!(rejected.body)
  end

  @tag mcp_contract: ["list-pagination-wire", "streamable-http-admission"]
  test "advances opaque list cursors over native HTTP without transport state" do
    runtime =
      TestFixtures.runtime(
        tools: [Echo, Structured],
        tools_cache: [ttl_ms: 47, scope: "private"],
        pagination: [page_size: 1]
      )

    first_raw = TestFixtures.request("http-page-one", "tools/list")
    first_response = StreamableHTTP.handle(runtime, request(first_raw))

    assert first_response.status == 200
    first = JSON.decode!(first_response.body)
    assert get_in(first, ["result", "tools", Access.at(0), "name"]) == "echo"
    assert get_in(first, ["result", "ttlMs"]) == 47
    cursor = get_in(first, ["result", "nextCursor"])
    assert is_binary(cursor)

    second_raw =
      TestFixtures.request("http-page-two", "tools/list", %{"cursor" => cursor})

    second_response = StreamableHTTP.handle(runtime, request(second_raw))

    assert second_response.status == 200
    second = JSON.decode!(second_response.body)
    assert get_in(second, ["result", "tools", Access.at(0), "name"]) == "structured"
    refute Map.has_key?(second["result"], "nextCursor")
  end

  test "keeps missing metadata, header mismatch, and unsupported version distinct" do
    runtime = TestFixtures.runtime()
    raw = TestFixtures.request(7, "server/discover")
    protocol_key = Snodo.Protocol.V2026_07_28.protocol_version_key()

    missing_metadata = put_in(raw, ["params", "_meta"], %{})

    missing_response =
      StreamableHTTP.handle(runtime, request(missing_metadata, headers: headers(raw)))

    assert missing_response.status == 400
    assert %{"id" => 7, "error" => %{"code" => -32_602}} = JSON.decode!(missing_response.body)

    unsupported = put_in(raw, ["params", "_meta", protocol_key], "2099-12-31")

    unsupported_headers =
      unsupported
      |> headers()
      |> replace_header("mcp-protocol-version", "2099-12-31")

    unsupported_response =
      StreamableHTTP.handle(runtime, request(unsupported, headers: unsupported_headers))

    assert unsupported_response.status == 400

    assert %{
             "id" => 7,
             "error" => %{
               "code" => -32_022,
               "data" => %{
                 "requested" => "2099-12-31",
                 "supported" => [@protocol]
               }
             }
           } = JSON.decode!(unsupported_response.body)
  end

  test "an advertised exact extension route owns its HTTP routing policy" do
    runtime =
      TestFixtures.runtime(
        extensions: [HTTPPolicy],
        capabilities: extension_capabilities(HTTPPolicy)
      )

    raw = extension_request("http-policy", HTTPPolicy.id(), %{"taskId" => "task-123"})

    missing_name =
      StreamableHTTP.handle(runtime, request(raw, headers: base_headers(raw["method"])))

    assert missing_name.status == 400

    assert %{"id" => "http-policy", "error" => %{"code" => -32_020}} =
             JSON.decode!(missing_name.body)

    wrong_name =
      StreamableHTTP.handle(
        runtime,
        request(raw, headers: [{"Mcp-Name", "another-task"} | base_headers(raw["method"])])
      )

    assert wrong_name.status == 400
    assert %{"error" => %{"code" => -32_020}} = JSON.decode!(wrong_name.body)

    accepted =
      StreamableHTTP.handle(
        runtime,
        request(raw, headers: [{"Mcp-Name", "task-123"} | base_headers(raw["method"])])
      )

    assert accepted.status == 200
    assert %{"result" => %{"value" => _value}} = JSON.decode!(accepted.body)
  end

  test "an installed but unadvertised extension route cannot affect HTTP admission" do
    runtime = TestFixtures.runtime(extensions: [HTTPPolicy])
    raw = extension_request("installed-only-policy", HTTPPolicy.id(), %{"taskId" => "task-123"})

    assert {:ok, _prepared} =
             StreamableHTTP.prepare(runtime, request(raw, headers: base_headers(raw["method"])))

    response = StreamableHTTP.handle(runtime, request(raw, headers: base_headers(raw["method"])))
    assert response.status == 404
    assert %{"error" => %{"code" => -32_601}} = JSON.decode!(response.body)
  end

  test "extension transport policy failures become safe internal errors" do
    runtime =
      TestFixtures.runtime(
        extensions: [HTTPPolicy],
        capabilities: extension_capabilities(HTTPPolicy)
      )

    for mode <- ["raise", "invalid"] do
      raw =
        extension_request("policy-#{mode}", HTTPPolicy.id(), %{
          "taskId" => "task-123",
          "policyMode" => mode
        })

      response =
        StreamableHTTP.handle(runtime, request(raw, headers: base_headers(raw["method"])))

      assert response.status == 500
      assert %{"error" => %{"code" => -32_603}} = JSON.decode!(response.body)
      refute response.body =~ "private"
      refute response.body =~ "implementation detail"
    end
  end

  test "applies endpoint security and HTTP status semantics" do
    runtime = TestFixtures.runtime()
    raw = TestFixtures.request(9, "server/discover")

    rejected_origin =
      raw
      |> headers()
      |> replace_header("origin", "http://evil.example.com")

    response = StreamableHTTP.handle(runtime, request(raw, headers: rejected_origin))
    assert response.status == 403
    assert %{"id" => nil} = JSON.decode!(response.body)

    allowed_origin = [{"Origin", "http://127.0.0.1:3001"} | headers(raw)]
    assert StreamableHTTP.handle(runtime, request(raw, headers: allowed_origin)).status == 200

    for method <- ["GET", "DELETE"] do
      response = StreamableHTTP.handle(runtime, request(raw, method: method, headers: []))
      assert response.status == 405
      assert {"allow", "POST"} in response.headers
    end

    unknown = TestFixtures.request(10, "vendor/missing")
    response = StreamableHTTP.handle(runtime, request(unknown))
    assert response.status == 404
    assert %{"id" => 10, "error" => %{"code" => -32_601}} = JSON.decode!(response.body)
  end

  test "rejects malformed JSON, batches, and unsupported media negotiation" do
    runtime = TestFixtures.runtime()

    malformed = %Request{
      method: "POST",
      path: "/mcp",
      headers: base_headers("tools/list"),
      body: "{not-json"
    }

    response = StreamableHTTP.handle(runtime, malformed)
    assert response.status == 400
    assert %{"id" => nil, "error" => %{"code" => -32_700}} = JSON.decode!(response.body)

    batch = %{malformed | body: JSON.encode!([TestFixtures.request(1, "tools/list")])}
    response = StreamableHTTP.handle(runtime, batch)
    assert response.status == 400
    assert %{"error" => %{"code" => -32_600}} = JSON.decode!(response.body)

    raw = TestFixtures.request(1, "tools/list")
    wrong_content_type = replace_header(headers(raw), "content-type", "text/plain")
    assert StreamableHTTP.handle(runtime, request(raw, headers: wrong_content_type)).status == 415

    wrong_accept = replace_header(headers(raw), "accept", "application/json")
    assert StreamableHTTP.handle(runtime, request(raw, headers: wrong_accept)).status == 406
  end

  defp request(raw, opts \\ []) do
    %Request{
      method: Keyword.get(opts, :method, "POST"),
      path: Keyword.get(opts, :path, "/mcp"),
      headers: Keyword.get(opts, :headers, headers(raw)),
      body: JSON.encode!(raw),
      peer: {{127, 0, 0, 1}, 50_000},
      connection_ref: make_ref()
    }
  end

  defp extension_request(id, method, params) do
    TestFixtures.request(id, method, params)
    |> put_in(
      ["params", "_meta", Snodo.Protocol.V2026_07_28.client_capabilities_key()],
      %{"extensions" => %{HTTPPolicy.id() => %{}}}
    )
  end

  defp extension_capabilities(extension) do
    %{
      "tools" => %{},
      "extensions" => %{extension.id() => %{}}
    }
  end

  defp headers(raw) do
    method = raw["method"]
    params = Map.get(raw, "params", %{})

    base_headers(method) ++
      case method do
        "tools/call" -> [{"Mcp-Name", params["name"]}]
        "prompts/get" -> [{"Mcp-Name", params["name"]}]
        "resources/read" -> [{"Mcp-Name", params["uri"]}]
        _other -> []
      end
  end

  defp base_headers(method) do
    [
      {"Content-Type", "application/json; charset=utf-8"},
      {"Accept", "application/json, text/event-stream"},
      {"MCP-Protocol-Version", @protocol},
      {"Mcp-Method", method}
    ]
  end

  defp delete_header(headers, name) do
    wanted = String.downcase(name)
    Enum.reject(headers, fn {key, _value} -> String.downcase(key) == wanted end)
  end

  defp replace_header(headers, name, value) do
    [{name, value} | delete_header(headers, name)]
  end
end
