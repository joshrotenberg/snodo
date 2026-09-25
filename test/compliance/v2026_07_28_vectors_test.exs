defmodule Snodo.Compliance.V2026_07_28VectorsTest do
  use ExUnit.Case, async: true

  alias Snodo.Context
  alias Snodo.Envelope
  alias Snodo.Protocol.V2026_07_28
  alias Snodo.Resource.Definition, as: ResourceDefinition
  alias Snodo.Result
  alias Snodo.Router
  alias Snodo.Server
  alias Snodo.Server.Runtime
  alias Snodo.Transport.Context, as: TransportContext
  alias Snodo.Transport.Stdio
  alias SnodoTest.ComplianceCase
  alias SnodoTest.FutureDialect
  alias SnodoTest.TestCompletions.PackagePrompt
  alias SnodoTest.TestCompletions.RepositoryTemplate
  alias SnodoTest.TestFixtures
  alias SnodoTest.TestPrompts.MediaReview
  alias SnodoTest.TestPrompts.PackageAnalysis
  alias SnodoTest.TestResources.PackageTemplate
  alias SnodoTest.TestResources.StaticBlob
  alias SnodoTest.TestResources.StaticText
  alias SnodoTest.TestTools.Echo
  alias SnodoTest.TestTools.Failing
  alias SnodoTest.TestTools.Structured

  @literal_meta %{
    "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
    "io.modelcontextprotocol/clientCapabilities" => %{}
  }

  @spec_root "https://modelcontextprotocol.io/specification/2026-07-28"

  @tag mcp_contract: ["direct-stdio-success-vectors"]
  test "literal success vectors agree through direct and stdio admission" do
    runtime = TestFixtures.runtime(tools: [Echo, Failing, Structured])

    discover = request("discover-vector", "server/discover", %{})
    list = request("list-vector", "tools/list", %{})

    text_call =
      request("text-vector", "tools/call", %{
        "name" => "echo",
        "arguments" => %{"text" => "literal-vector"}
      })

    structured_call =
      request("structured-vector", "tools/call", %{
        "name" => "structured",
        "arguments" => %{"value" => %{"ok" => true}}
      })

    error_call =
      request("error-vector", "tools/call", %{
        "name" => "failing",
        "arguments" => %{}
      })

    for raw <- [discover, list, text_call, structured_call, error_call] do
      assert dispatch(runtime, raw, :direct) == dispatch(runtime, raw, :stdio)
    end

    discover_response = dispatch(runtime, discover, :direct)

    assert %{
             "jsonrpc" => "2.0",
             "id" => "discover-vector",
             "result" => %{
               "resultType" => "complete",
               "supportedVersions" => ["2026-07-28"],
               "capabilities" => %{"tools" => %{}},
               "ttlMs" => 0,
               "cacheScope" => "private",
               "_meta" => %{
                 "io.modelcontextprotocol/serverInfo" => %{
                   "name" => "snodo-spike",
                   "version" => "0.1.0"
                 }
               }
             }
           } = discover_response

    list_response = dispatch(runtime, list, :direct)

    assert %{
             "result" => %{
               "resultType" => "complete",
               "tools" => tools,
               "ttlMs" => 0,
               "cacheScope" => "private"
             }
           } = list_response

    assert Enum.map(tools, & &1["name"]) == ["echo", "failing", "structured"]

    echo = Enum.find(tools, &(&1["name"] == "echo"))
    assert echo["inputSchema"]["$schema"] == "https://json-schema.org/draft/2020-12/schema"
    assert echo["inputSchema"]["unevaluatedProperties"] == false
    assert echo["inputSchema"]["$defs"]["text"]["type"] == "string"

    assert get_in(dispatch(runtime, text_call, :direct), ["result", "content"]) == [
             %{"type" => "text", "text" => "literal-vector"}
           ]

    assert get_in(dispatch(runtime, structured_call, :direct), [
             "result",
             "structuredContent"
           ]) == %{"ok" => true}

    assert get_in(dispatch(runtime, error_call, :direct), ["result", "isError"]) == true
  end

  @tag mcp_contract: ["direct-stdio-negative-vectors"]
  test "literal negative vectors preserve codes and IDs across direct and stdio" do
    runtime = TestFixtures.runtime(tools: [Echo])

    cases = [
      %ComplianceCase{
        id: "unknown-method",
        spec_ref: @spec_root <> "/basic#requests",
        transports: [:direct, :stdio],
        request: request(11, "com.example/missing", %{}),
        expected: %{id: 11, code: -32_601}
      },
      %ComplianceCase{
        id: "missing-meta",
        spec_ref: @spec_root <> "/basic#meta",
        transports: [:direct, :stdio],
        request: %{"jsonrpc" => "2.0", "id" => 12, "method" => "tools/list", "params" => %{}},
        expected: %{id: 12, code: -32_602}
      },
      %ComplianceCase{
        id: "unsupported-version",
        spec_ref: @spec_root <> "/basic/versioning",
        transports: [:direct, :stdio],
        request:
          request(13, "tools/list", %{}, %{
            "io.modelcontextprotocol/protocolVersion" => "2099-01-01",
            "io.modelcontextprotocol/clientCapabilities" => %{}
          }),
        expected: %{id: 13, code: -32_022}
      },
      %ComplianceCase{
        id: "malformed-tool-arguments",
        spec_ref: @spec_root <> "/server/tools",
        transports: [:direct, :stdio],
        request: request(14, "tools/call", %{"name" => "echo", "arguments" => []}),
        expected: %{id: 14, code: -32_602}
      },
      %ComplianceCase{
        id: "batch-rejected",
        spec_ref: @spec_root <> "/basic",
        transports: [:direct, :stdio],
        request: [request(15, "tools/list", %{}), request(16, "tools/list", %{})],
        expected: %{id: nil, code: -32_600}
      },
      %ComplianceCase{
        id: "floating-request-id-rejected",
        spec_ref: @spec_root <> "/basic#requests",
        transports: [:direct, :stdio],
        request: request(16.5, "tools/list", %{}),
        expected: %{id: nil, code: -32_600}
      }
    ]

    Enum.each(cases, fn compliance_case ->
      Enum.each(compliance_case.transports, fn transport ->
        response = dispatch(runtime, compliance_case.request, transport)

        assert response["id"] == compliance_case.expected.id,
               "#{compliance_case.id} (#{compliance_case.spec_ref}) over #{transport} lost its ID"

        assert get_in(response, ["error", "code"]) == compliance_case.expected.code,
               "#{compliance_case.id} (#{compliance_case.spec_ref}) over #{transport} changed code"
      end)
    end)
  end

  @tag mcp_contract: ["response-free-cancellation"]
  test "literal cancellation notification is response-free on both bindings" do
    runtime = TestFixtures.runtime(tools: [Echo])

    cancellation = %{
      "jsonrpc" => "2.0",
      "method" => "notifications/cancelled",
      "params" => %{"requestId" => "gone", "reason" => "literal vector"}
    }

    assert dispatch(runtime, cancellation, :direct) == nil
    assert dispatch(runtime, cancellation, :stdio) == nil

    floating_id = put_in(cancellation, ["params", "requestId"], 1.5)

    assert {:error, error} =
             Server.resolve_notification(
               runtime,
               floating_id,
               %TransportContext{transport: :direct}
             )

    assert error.code == -32_602
    assert dispatch(runtime, floating_id, :direct) == nil
    assert dispatch(runtime, floating_id, :stdio) == nil
  end

  @tag mcp_contract: ["header-body-version-mismatch"]
  test "literal header/body mismatch maps to the final protocol error" do
    runtime = TestFixtures.runtime(tools: [Echo])
    raw = request(17, "tools/list", %{})

    response =
      dispatch(runtime, raw, :direct, request_headers: %{"MCP-Protocol-Version" => "2025-11-25"})

    assert response["id"] == 17
    assert get_in(response, ["error", "code"]) == -32_020

    assert get_in(response, ["error", "data"]) == %{
             "header" => "2025-11-25",
             "body" => "2026-07-28"
           }
  end

  @tag mcp_contract: ["exact-profile-admission"]
  test "conflicting exact dialect indicators are an invalid request, not an internal error" do
    runtime =
      TestFixtures.runtime(
        protocols: [Snodo.Protocol.V2026_07_28, FutureDialect],
        tools: [Echo]
      )

    raw = %{
      "jsonrpc" => "2.0",
      "id" => 18,
      "method" => "acme/echo",
      "params" => %{
        "name" => "echo",
        "arguments" => %{"text" => "ambiguous"},
        "_meta" => %{
          "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
          "io.modelcontextprotocol/clientCapabilities" => %{},
          "com.acme/protocolVersion" => "2099-01-01",
          "com.acme/clientCapabilities" => %{}
        }
      }
    }

    for transport <- [:direct, :stdio] do
      response = dispatch(runtime, raw, transport)
      assert response["id"] == 18
      assert get_in(response, ["error", "code"]) == -32_600
    end
  end

  @tag mcp_contract: ["exact-profile-admission", "resources-routing-wire"]
  test "resource operations preserve definitions and contents in exact complete results" do
    context = resource_context()

    static = %ResourceDefinition{
      kind: :resource,
      uri: "test://static/readme",
      name: "static_readme",
      title: "Static README",
      description: "A static text resource",
      mime_type: "text/markdown",
      size: 17,
      icons: [%{"src" => "https://example.test/readme.png", "mimeType" => "image/png"}],
      annotations: %{"audience" => ["user"], "priority" => 0.8},
      metadata: %{"com.example/catalog" => %{"stable" => true}}
    }

    template = %ResourceDefinition{
      kind: :template,
      uri_template: "test://packages/{name}",
      name: "package",
      description: "Package data",
      mime_type: "application/json",
      metadata: %{"com.example/template" => "package"}
    }

    list_result =
      Result.resources([static])
      |> with_cache_metadata(15_000, "public")
      |> then(&V2026_07_28.shape_result(:resources_list, &1, context))

    assert %{
             "resultType" => "complete",
             "resources" => [resource],
             "ttlMs" => 15_000,
             "cacheScope" => "public",
             "_meta" => %{
               "io.modelcontextprotocol/serverInfo" => %{
                 "name" => "resource-vectors",
                 "version" => "1.0.0"
               }
             }
           } = list_result

    assert resource == %{
             "uri" => "test://static/readme",
             "name" => "static_readme",
             "title" => "Static README",
             "description" => "A static text resource",
             "mimeType" => "text/markdown",
             "size" => 17,
             "icons" => [
               %{"src" => "https://example.test/readme.png", "mimeType" => "image/png"}
             ],
             "annotations" => %{"audience" => ["user"], "priority" => 0.8},
             "_meta" => %{"com.example/catalog" => %{"stable" => true}}
           }

    templates_result =
      Result.resource_templates([template])
      |> then(&V2026_07_28.shape_result(:resource_templates_list, &1, context))

    assert %{
             "resultType" => "complete",
             "resourceTemplates" => [
               %{
                 "uriTemplate" => "test://packages/{name}",
                 "name" => "package",
                 "description" => "Package data",
                 "mimeType" => "application/json",
                 "_meta" => %{"com.example/template" => "package"}
               }
             ],
             "ttlMs" => 0,
             "cacheScope" => "private"
           } = templates_result

    contents = [
      %{
        "uri" => "test://packages/ecto",
        "mimeType" => "application/json",
        "text" => ~s({"name":"ecto"}),
        "_meta" => %{"com.example/content" => 1}
      },
      %{
        "uri" => "test://packages/ecto/icon",
        "mimeType" => "image/png",
        "blob" => "AQID"
      }
    ]

    read_result =
      Result.resource_read(contents,
        metadata: %{
          "com.example/result" => "preserved",
          ttl_ms: 250,
          cache_scope: "private"
        }
      )
      |> then(
        &V2026_07_28.shape_result(
          {:resource_read, "test://packages/ecto"},
          &1,
          context
        )
      )

    assert read_result["resultType"] == "complete"
    assert read_result["contents"] == contents
    assert read_result["ttlMs"] == 250
    assert read_result["cacheScope"] == "private"

    assert read_result["_meta"] == %{
             "com.example/result" => "preserved",
             "io.modelcontextprotocol/serverInfo" => %{
               "name" => "resource-vectors",
               "version" => "1.0.0"
             }
           }
  end

  @tag mcp_contract: ["exact-profile-admission", "resources-routing-wire"]
  test "resource operation validation requires capability, absolute URI, and string cursors" do
    context = resource_context()

    read =
      request("resource-read", "resources/read", %{"uri" => "test://packages/ecto"})

    assert {:ok, envelope} =
             Envelope.decode(read, %TransportContext{transport: :direct})

    assert {:ok, {:resource_read, "test://packages/ecto"}} =
             V2026_07_28.resolve_operation(envelope)

    assert :ok =
             V2026_07_28.validate_operation(
               {:resource_read, "test://packages/ecto"},
               envelope.params,
               context
             )

    no_capability = %{context | server_capabilities: %{}}

    assert {:error, missing_capability} =
             V2026_07_28.validate_operation(:resources_list, %{}, no_capability)

    assert missing_capability.code == -32_601

    for operation <- [:resources_list, :resource_templates_list] do
      assert :ok = V2026_07_28.validate_operation(operation, %{"cursor" => "next"}, context)

      assert {:error, cursor_error} =
               V2026_07_28.validate_operation(operation, %{"cursor" => 7}, context)

      assert cursor_error.code == -32_602
    end

    assert {:error, uri_error} =
             V2026_07_28.validate_operation(
               {:resource_read, "relative/resource"},
               %{"uri" => "relative/resource"},
               context
             )

    assert uri_error.code == -32_602
  end

  @tag mcp_contract: [
         "direct-stdio-success-vectors",
         "direct-stdio-negative-vectors",
         "resources-routing-wire"
       ]
  test "literal resource vectors agree across direct and stdio dispatch" do
    runtime = resource_runtime()

    list = request("resources-list", "resources/list", %{})
    templates = request("resource-templates", "resources/templates/list", %{})

    text_read =
      request("resource-text", "resources/read", %{"uri" => "test://static/readme"})

    blob_read =
      request("resource-blob", "resources/read", %{"uri" => "test://static/blob"})

    template_read =
      request("resource-template", "resources/read", %{"uri" => "test://packages/ecto"})

    for raw <- [list, templates, text_read, blob_read, template_read] do
      assert dispatch(runtime, raw, :direct) == dispatch(runtime, raw, :stdio)
    end

    assert %{
             "result" => %{
               "resultType" => "complete",
               "resources" => resources,
               "ttlMs" => 12_000,
               "cacheScope" => "public"
             }
           } = dispatch(runtime, list, :direct)

    assert Enum.map(resources, & &1["uri"]) == [
             "test://static/blob",
             "test://static/readme"
           ]

    assert %{
             "result" => %{
               "resourceTemplates" => [
                 %{
                   "name" => "package",
                   "uriTemplate" => "test://packages/{name}",
                   "_meta" => %{"com.example/template" => %{"matcher" => "explicit"}}
                 }
               ],
               "ttlMs" => 12_000,
               "cacheScope" => "public"
             }
           } = dispatch(runtime, templates, :direct)

    assert %{
             "result" => %{
               "contents" => [
                 %{
                   "uri" => "test://static/readme",
                   "text" => "# Static resource\n",
                   "mimeType" => "text/markdown",
                   "_meta" => %{"com.example/content" => %{"preserved" => true}}
                 }
               ],
               "ttlMs" => 12_000,
               "cacheScope" => "public",
               "_meta" => %{
                 "com.example/result" => %{"kind" => "text"},
                 "io.modelcontextprotocol/serverInfo" => %{
                   "name" => "resource-vector-server",
                   "version" => "1.0.0"
                 }
               }
             }
           } = dispatch(runtime, text_read, :direct)

    assert %{
             "result" => %{
               "contents" => [
                 %{
                   "uri" => "test://static/blob",
                   "blob" => "AAECf4D/",
                   "mimeType" => "application/octet-stream"
                 }
               ]
             }
           } = dispatch(runtime, blob_read, :direct)

    template_content =
      runtime
      |> dispatch(template_read, :direct)
      |> get_in(["result", "contents", Access.at(0), "text"])
      |> JSON.decode!()

    assert template_content["name"] == "ecto"

    for raw <- [
          request("resources-cursor", "resources/list", %{"cursor" => "next"}),
          request("templates-cursor", "resources/templates/list", %{"cursor" => "next"}),
          request("resource-missing", "resources/read", %{"uri" => "test://missing"})
        ] do
      direct = dispatch(runtime, raw, :direct)
      assert direct == dispatch(runtime, raw, :stdio)
      assert get_in(direct, ["error", "code"]) == -32_602
    end
  end

  @tag mcp_contract: ["direct-stdio-success-vectors", "prompts-routing-wire"]
  test "literal prompt vectors agree across direct and stdio dispatch" do
    runtime =
      TestFixtures.runtime(
        tools: [],
        prompts: [PackageAnalysis, MediaReview],
        prompts_cache: [ttl_ms: 8_000, scope: "public"]
      )

    list = request("prompts-list", "prompts/list", %{})

    get =
      request("prompt-get", "prompts/get", %{
        "name" => "package_analysis",
        "arguments" => %{"name" => "plug", "focus" => "security"}
      })

    for raw <- [list, get] do
      assert dispatch(runtime, raw, :direct) == dispatch(runtime, raw, :stdio)
    end

    assert %{
             "result" => %{
               "resultType" => "complete",
               "prompts" => prompts,
               "ttlMs" => 8_000,
               "cacheScope" => "public"
             }
           } = dispatch(runtime, list, :direct)

    assert Enum.map(prompts, & &1["name"]) == ["media_review", "package_analysis"]

    assert %{
             "result" => %{
               "resultType" => "complete",
               "description" => "Analysis workflow for plug",
               "messages" => [%{"role" => "user"}, %{"role" => "assistant"}]
             }
           } = dispatch(runtime, get, :direct)

    for raw <- [
          request("prompt-missing-arg", "prompts/get", %{"name" => "package_analysis"}),
          request("prompts-cursor", "prompts/list", %{"cursor" => "next"})
        ] do
      direct = dispatch(runtime, raw, :direct)
      assert direct == dispatch(runtime, raw, :stdio)
      assert get_in(direct, ["error", "code"]) == -32_602
    end
  end

  @tag mcp_contract: ["list-pagination-wire"]
  test "opaque list cursors advance identically through direct and stdio dispatch" do
    runtime =
      TestFixtures.runtime(
        tools: [Echo, Failing, Structured],
        tools_cache: [ttl_ms: 91, scope: "public"],
        pagination: [page_size: 1]
      )

    first_request = request("page-one", "tools/list", %{})
    first = dispatch(runtime, first_request, :direct)

    assert first == dispatch(runtime, first_request, :stdio)
    assert get_in(first, ["result", "tools", Access.at(0), "name"]) == "echo"
    assert get_in(first, ["result", "ttlMs"]) == 91
    assert get_in(first, ["result", "cacheScope"]) == "public"
    cursor = get_in(first, ["result", "nextCursor"])
    assert is_binary(cursor)

    second_request = request("page-two", "tools/list", %{"cursor" => cursor})
    second = dispatch(runtime, second_request, :direct)

    assert second == dispatch(runtime, second_request, :stdio)
    assert get_in(second, ["result", "tools", Access.at(0), "name"]) == "failing"
    assert is_binary(get_in(second, ["result", "nextCursor"]))
  end

  @tag mcp_contract: ["completion-routing-wire"]
  test "literal completion vectors agree across direct and stdio dispatch" do
    runtime =
      TestFixtures.runtime(
        tools: [],
        prompts: [PackagePrompt],
        resources: [RepositoryTemplate]
      )

    prompt =
      request("prompt-completion", "completion/complete", %{
        "ref" => %{"type" => "ref/prompt", "name" => "package_search"},
        "argument" => %{"name" => "name", "value" => "ec"},
        "context" => %{"arguments" => %{"focus" => "health"}}
      })

    resource =
      request("resource-completion", "completion/complete", %{
        "ref" => %{"type" => "ref/resource", "uri" => "repo://{owner}/{name}"},
        "argument" => %{"name" => "name", "value" => "ec"},
        "context" => %{"arguments" => %{"owner" => "elixir-ecto"}}
      })

    for raw <- [prompt, resource] do
      assert dispatch(runtime, raw, :direct) == dispatch(runtime, raw, :stdio)
    end

    assert %{
             "result" => %{
               "resultType" => "complete",
               "completion" => %{
                 "values" => ["ecto", "ecto_sql"],
                 "total" => 2,
                 "hasMore" => false
               }
             }
           } = dispatch(runtime, prompt, :direct)

    malformed =
      request("bad-completion", "completion/complete", %{
        "ref" => %{"type" => "ref/prompt", "name" => "package_search"},
        "argument" => %{"name" => "name", "value" => 7}
      })

    assert dispatch(runtime, malformed, :direct) == dispatch(runtime, malformed, :stdio)
    assert get_in(dispatch(runtime, malformed, :direct), ["error", "code"]) == -32_602
  end

  @tag mcp_contract: ["stdio-error-id-correlation"]
  test "stdio parse errors carry an explicit null correlation ID" do
    runtime = TestFixtures.runtime(tools: [Echo])
    {:ok, io} = StringIO.open("{not-json}\n")

    assert :ok = Stdio.serve(runtime, input: io, output: io)
    {_input, output} = StringIO.contents(io)
    response = output |> String.trim() |> JSON.decode!()

    assert Map.has_key?(response, "id")
    assert response["id"] == nil
    assert get_in(response, ["error", "code"]) == -32_700
  end

  defp request(id, method, params, metadata \\ @literal_meta) do
    %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => method,
      "params" => Map.put(params, "_meta", metadata)
    }
  end

  defp resource_context do
    %Context{
      protocol_version: "2026-07-28",
      protocol: V2026_07_28,
      transport: %TransportContext{transport: :direct},
      server_info: %{"name" => "resource-vectors", "version" => "1.0.0"},
      server_capabilities: %{"resources" => %{}}
    }
  end

  defp resource_runtime do
    router =
      Enum.reduce(
        [StaticText, StaticBlob, PackageTemplate],
        Router.new(),
        &Router.register_resource(&2, &1)
      )

    Runtime.new(
      router: router,
      protocols: [V2026_07_28],
      server_info: %{"name" => "resource-vector-server", "version" => "1.0.0"},
      resources_cache: [ttl_ms: 12_000, scope: "public"]
    )
  end

  defp with_cache_metadata(%Result{} = result, ttl_ms, cache_scope) do
    %{result | metadata: %{ttl_ms: ttl_ms, cache_scope: cache_scope}}
  end

  defp dispatch(runtime, raw, transport, opts \\ [])

  defp dispatch(runtime, raw, :direct, opts) do
    transport = %TransportContext{
      transport: :direct,
      request_headers: Keyword.get(opts, :request_headers, %{})
    }

    assert {:ok, response} = Server.dispatch(runtime, raw, transport)
    response
  end

  defp dispatch(runtime, raw, :stdio, _opts) do
    {:ok, io} = StringIO.open(JSON.encode!(raw) <> "\n")
    assert :ok = Stdio.serve(runtime, input: io, output: io)
    {_input, output} = StringIO.contents(io)

    case String.split(output, "\n", trim: true) do
      [] -> nil
      [line] -> JSON.decode!(line)
    end
  end
end
