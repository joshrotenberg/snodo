defmodule MCP.AuthorizationAcceptanceTest do
  use ExUnit.Case, async: true

  alias MCP.Authorization
  alias MCP.Protocol.V2025_06_18
  alias MCP.Protocol.V2025_11_25
  alias MCP.Protocol.V2026_07_28
  alias MCP.Server
  alias MCP.Test, as: MCPTest
  alias MCP.Transport.Context, as: TransportContext
  alias MCP.Transport.Stdio
  alias MCP.Transport.StreamableHTTP
  alias MCP.Transport.StreamableHTTP.Request
  alias MCPEx.TestAuthorization.DenyAll
  alias MCPEx.TestAuthorization.InvalidDecision
  alias MCPEx.TestAuthorization.NotAPolicy
  alias MCPEx.TestAuthorization.Policy
  alias MCPEx.TestAuthorization.ProbePrompt
  alias MCPEx.TestAuthorization.ProbeResource
  alias MCPEx.TestAuthorization.ProbeTemplate
  alias MCPEx.TestAuthorization.ProbeTool
  alias MCPEx.TestAuthorization.Raising
  alias MCPEx.TestFixtures
  alias MCPEx.TestPrompts.PackageAnalysis
  alias MCPEx.TestResources.StaticText
  alias MCPEx.TestTools.Echo

  @protocol "2026-07-28"
  @refused Policy.refusal_code()

  defp runtime(allowed, extra \\ []) do
    defaults = [
      tools: [Echo, ProbeTool],
      prompts: [PackageAnalysis, ProbePrompt],
      resources: [ProbeResource, ProbeTemplate, StaticText],
      authorization: {Policy, %{owner: self(), allowed: Map.new(allowed, &granted/1)}}
    ]

    TestFixtures.runtime(Keyword.merge(defaults, extra))
  end

  defp granted({principal, entries}), do: {principal, MapSet.new(entries)}

  defp dispatch(runtime, principal, method, params \\ %{}) do
    {:ok, response} =
      MCPTest.dispatch(runtime,
        protocol: @protocol,
        method: method,
        params: params,
        transport_metadata: %{auth: auth(principal)}
      )

    response
  end

  defp auth(nil), do: nil
  defp auth(principal), do: %{"principal" => principal}

  defp names(response, field, key \\ "name"),
    do: Enum.map(response["result"][field], &Map.fetch!(&1, key))

  test "one runtime serves a different effective catalog to each request context" do
    runtime =
      runtime(%{
        "alpha" => [
          {:tool, "echo"},
          {:prompt, "package_analysis"},
          {:resource, "static_readme"},
          {:resource_template, "probe_item"}
        ],
        "beta" => [
          {:tool, "probe_tool"},
          {:prompt, "probe_prompt"},
          {:resource, "probe_static"}
        ]
      })

    assert names(dispatch(runtime, "alpha", "tools/list"), "tools") == ["echo"]
    assert names(dispatch(runtime, "beta", "tools/list"), "tools") == ["probe_tool"]

    assert names(dispatch(runtime, "alpha", "prompts/list"), "prompts") == ["package_analysis"]
    assert names(dispatch(runtime, "beta", "prompts/list"), "prompts") == ["probe_prompt"]

    assert names(dispatch(runtime, "alpha", "resources/list"), "resources") == ["static_readme"]
    assert names(dispatch(runtime, "beta", "resources/list"), "resources") == ["probe_static"]

    assert names(dispatch(runtime, "alpha", "resources/templates/list"), "resourceTemplates") ==
             ["probe_item"]

    assert names(dispatch(runtime, "beta", "resources/templates/list"), "resourceTemplates") == []

    # An unauthenticated context sees an empty catalog rather than the whole one.
    assert names(dispatch(runtime, nil, "tools/list"), "tools") == []

    # Hiding a component during discovery is not an attempted boundary violation.
    assert_received {:authorization_hidden, "alpha", {:tool, "probe_tool"}}
    refute_received {:authorization_refused, _principal, _component, _method}
  end

  test "a guessed tool call is refused before argument validation and before the handler" do
    runtime = runtime(%{"alpha" => [{:tool, "echo"}]})

    # Without the policy these arguments would fail required-argument validation.
    response = dispatch(runtime, "alpha", "tools/call", %{"name" => "probe_tool"})

    assert response["error"] == %{
             "code" => @refused,
             "message" => "Application policy refused tool:probe_tool",
             "data" => %{"component" => "tool:probe_tool", "uri" => nil}
           }

    assert_received {:authorization_refused, "alpha", {:tool, "probe_tool"}, "tools/call"}
    refute_received {:probe, :tool_call}

    assert %{"result" => %{"content" => [%{"text" => "hello"}]}} =
             dispatch(runtime, "alpha", "tools/call", %{
               "name" => "echo",
               "arguments" => %{"text" => "hello"}
             })
  end

  test "prompt, resource, template, and completion invocation share the one policy" do
    runtime = runtime(%{"alpha" => []})

    refusals = [
      {"prompts/get", %{"name" => "probe_prompt"}, {:prompt, "probe_prompt"}},
      {"resources/read", %{"uri" => "probe://static"}, {:resource, "probe_static"}},
      {"resources/read", %{"uri" => "probe://items/7"}, {:resource_template, "probe_item"}},
      {"completion/complete",
       %{
         "ref" => %{"type" => "ref/prompt", "name" => "probe_prompt"},
         "argument" => %{"name" => "topic", "value" => "r"}
       }, {:prompt, "probe_prompt"}},
      {"completion/complete",
       %{
         "ref" => %{"type" => "ref/resource", "uri" => "probe://items/{id}"},
         "argument" => %{"name" => "id", "value" => "1"}
       }, {:resource_template, "probe_item"}}
    ]

    for {method, params, component} <- refusals do
      assert %{"error" => %{"code" => @refused}} = dispatch(runtime, "alpha", method, params)
      assert_received {:authorization_refused, "alpha", ^component, ^method}
    end

    refute_received {:probe, _callback}
  end

  test "an authorized context still reaches every handler" do
    runtime =
      runtime(%{
        "alpha" => [
          {:prompt, "probe_prompt"},
          {:resource, "probe_static"},
          {:resource_template, "probe_item"}
        ]
      })

    assert %{"result" => _} =
             dispatch(runtime, "alpha", "prompts/get", %{
               "name" => "probe_prompt",
               "arguments" => %{"topic" => "releases"}
             })

    assert_received {:probe, :prompt_get}

    assert %{"result" => _} =
             dispatch(runtime, "alpha", "resources/read", %{"uri" => "probe://static"})

    assert_received {:probe, :resource_read}

    assert %{"result" => _} =
             dispatch(runtime, "alpha", "resources/read", %{"uri" => "probe://items/7"})

    assert_received {:probe, :template_read}

    assert %{"result" => _} =
             dispatch(runtime, "alpha", "completion/complete", %{
               "ref" => %{"type" => "ref/prompt", "name" => "probe_prompt"},
               "argument" => %{"name" => "topic", "value" => "r"}
             })

    assert_received {:probe, :prompt_complete}

    assert %{"result" => _} =
             dispatch(runtime, "alpha", "completion/complete", %{
               "ref" => %{"type" => "ref/resource", "uri" => "probe://items/{id}"},
               "argument" => %{"name" => "id", "value" => "1"}
             })

    assert_received {:probe, :template_complete}
    refute_received {:authorization_refused, _principal, _component, _method}
  end

  test "pagination pages the effective catalog and cursors cannot cross policies" do
    runtime =
      runtime(
        %{
          "alpha" => [{:tool, "echo"}, {:tool, "probe_tool"}],
          "beta" => [{:tool, "probe_tool"}]
        },
        pagination: [page_size: 1]
      )

    first = dispatch(runtime, "alpha", "tools/list")
    assert names(first, "tools") == ["echo"]
    cursor = first["result"]["nextCursor"]
    assert is_binary(cursor)

    second = dispatch(runtime, "alpha", "tools/list", %{"cursor" => cursor})
    assert names(second, "tools") == ["probe_tool"]
    refute Map.has_key?(second["result"], "nextCursor")

    # Beta's effective catalog is a different catalog, so alpha's cursor expires
    # instead of indexing into a page beta never saw.
    replayed = dispatch(runtime, "beta", "tools/list", %{"cursor" => cursor})
    assert replayed["error"]["message"] == "Pagination cursor has expired"

    beta = dispatch(runtime, "beta", "tools/list")
    assert names(beta, "tools") == ["probe_tool"]
    refute Map.has_key?(beta["result"], "nextCursor")
  end

  test "the same policy applies below the HTTP transport" do
    runtime = runtime(%{"alpha" => [{:tool, "echo"}]})

    assert names(http(runtime, "alpha", "tools/list"), "tools") == ["echo"]
    assert names(http(runtime, "beta", "tools/list"), "tools") == []

    refused = http(runtime, "beta", "tools/call", %{"name" => "echo", "arguments" => %{}})
    assert refused["error"]["code"] == @refused
    assert_received {:authorization_refused, "beta", {:tool, "echo"}, "tools/call"}
  end

  test "the same policy applies below the stdio transport" do
    runtime = runtime(%{nil => [{:tool, "echo"}]})
    {:ok, io} = StringIO.open(stdio_input())
    assert :ok = Stdio.serve(runtime, input: io, output: io)
    {_input, output} = StringIO.contents(io)

    responses =
      output
      |> String.split("\n", trim: true)
      |> Enum.map(&JSON.decode!/1)
      |> Map.new(&{&1["id"], &1})

    assert names(responses["list"], "tools") == ["echo"]
    assert responses["guess"]["error"]["code"] == @refused
    assert_received {:authorization_refused, nil, {:tool, "probe_tool"}, "tools/call"}
  end

  test "every enabled dialect enforces the same policy" do
    runtime =
      runtime(%{"alpha" => [{:tool, "echo"}]},
        protocols: [V2026_07_28, V2025_11_25, V2025_06_18],
        capabilities: %{"tools" => %{}, "prompts" => %{}, "resources" => %{}}
      )

    for version <- ["2025-06-18", "2025-11-25"] do
      assert {:ok, listed} = legacy(runtime, version, "alpha", "tools/list")
      assert names(listed, "tools") == ["echo"]

      assert {:ok, refused} =
               legacy(runtime, version, "alpha", "tools/call", %{"name" => "probe_tool"})

      assert refused["error"]["code"] == @refused
      assert_received {:authorization_refused, "alpha", {:tool, "probe_tool"}, "tools/call"}
    end
  end

  test "a policy fault fails the operation instead of silently emptying a catalog" do
    for policy <- [Raising, InvalidDecision] do
      runtime = TestFixtures.runtime(tools: [Echo, ProbeTool], authorization: policy)

      listed = dispatch(runtime, "alpha", "tools/list")
      assert listed["error"]["code"] == -32_603
      refute Map.has_key?(listed, "result")

      called =
        dispatch(runtime, "alpha", "tools/call", %{
          "name" => "probe_tool",
          "arguments" => %{"text" => "hi"}
        })

      assert called["error"]["code"] == -32_603
      refute_received {:probe, :tool_call}
    end
  end

  test "an unconfigured runtime keeps the whole catalog and every call" do
    runtime = TestFixtures.runtime(tools: [Echo, ProbeTool])

    assert names(dispatch(runtime, nil, "tools/list"), "tools") == ["echo", "probe_tool"]

    assert %{"result" => _} =
             dispatch(runtime, nil, "tools/call", %{
               "name" => "probe_tool",
               "arguments" => %{"text" => "hi"}
             })

    assert_received {:probe, :tool_call}
  end

  test "advertised capabilities describe the server rather than one filtered catalog" do
    runtime = runtime(%{"alpha" => []})

    assert %{"result" => %{"capabilities" => capabilities}} =
             dispatch(runtime, "alpha", "server/discover")

    assert Map.has_key?(capabilities, "tools")
    assert Map.has_key?(capabilities, "prompts")
    assert Map.has_key?(capabilities, "resources")
    assert names(dispatch(runtime, "alpha", "tools/list"), "tools") == []
  end

  defmodule DeclaredServer do
    @moduledoc false

    use MCP.Server,
      name: "declared-authorization",
      version: "1.0.0",
      protocols: [MCP.Protocol.V2026_07_28],
      authorization: MCPEx.TestAuthorization.DenyAll

    tool(MCPEx.TestTools.Echo)
  end

  test "the server DSL carries a declared policy into every runtime" do
    runtime = DeclaredServer.runtime()
    assert runtime.authorization == {DenyAll, []}
    assert names(dispatch(runtime, "alpha", "tools/list"), "tools") == []

    assert dispatch(runtime, "alpha", "tools/call", %{
             "name" => "echo",
             "arguments" => %{"text" => "hi"}
           })["error"]["code"] == -32_004

    # A runtime override still replaces the declared policy.
    assert DeclaredServer.runtime(authorization: nil).authorization == nil
  end

  test "a policy is validated when the runtime is built" do
    assert Authorization.normalize!(nil) == nil
    assert Authorization.normalize!(Policy) == {Policy, []}
    assert Authorization.normalize!({Policy, :options}) == {Policy, :options}

    assert_raise ArgumentError, "authorization policy must export authorize/4", fn ->
      Authorization.normalize!(NotAPolicy)
    end

    assert_raise ArgumentError, ~r/could not be loaded/, fn ->
      Authorization.normalize!(MCPEx.TestAuthorization.Missing)
    end

    assert_raise ArgumentError, ~r/must be a module or a \{module, options\} tuple/, fn ->
      Authorization.normalize!("policy")
    end

    assert_raise ArgumentError, fn ->
      TestFixtures.runtime(authorization: NotAPolicy)
    end
  end

  defp http(runtime, principal, method, params \\ %{}) do
    raw = TestFixtures.request("http-#{method}", method, params)

    request = %Request{
      method: "POST",
      path: "/mcp",
      headers: http_headers(method, params),
      body: JSON.encode!(raw),
      peer: {{127, 0, 0, 1}, 50_000},
      connection_ref: make_ref()
    }

    {:ok, prepared} = StreamableHTTP.prepare(runtime, request)
    prepared = put_in(prepared.transport.metadata[:auth], auth(principal))
    JSON.decode!(StreamableHTTP.execute(runtime, prepared).body)
  end

  defp http_headers(method, params) do
    base = [
      {"Content-Type", "application/json"},
      {"Accept", "application/json, text/event-stream"},
      {"MCP-Protocol-Version", @protocol},
      {"Mcp-Method", method}
    ]

    case params do
      %{"name" => name} -> base ++ [{"Mcp-Name", name}]
      _other -> base
    end
  end

  defp legacy(runtime, version, principal, method, params \\ %{}) do
    transport = %TransportContext{
      transport: :direct,
      request_headers: %{"mcp-protocol-version" => version},
      metadata: %{auth: auth(principal)}
    }

    raw = %{"jsonrpc" => "2.0", "id" => 1, "method" => method, "params" => params}
    Server.dispatch(runtime, raw, transport)
  end

  defp stdio_input do
    [
      TestFixtures.request("list", "tools/list"),
      TestFixtures.request("guess", "tools/call", %{
        "name" => "probe_tool",
        "arguments" => %{"text" => "hi"}
      })
    ]
    |> Enum.map_join("", &(JSON.encode!(&1) <> "\n"))
  end
end
