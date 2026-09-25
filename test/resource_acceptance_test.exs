defmodule Snodo.ResourceAcceptanceTest do
  use ExUnit.Case, async: true

  alias Snodo.Context
  alias Snodo.Error
  alias Snodo.Protocol.V2026_07_28
  alias Snodo.Resource
  alias Snodo.Resource.Definition
  alias Snodo.Result
  alias Snodo.Router
  alias Snodo.Transport.Context, as: TransportContext
  alias SnodoTest.TestResources.AmbiguousTemplateA
  alias SnodoTest.TestResources.AmbiguousTemplateB
  alias SnodoTest.TestResources.ArchiveTemplate
  alias SnodoTest.TestResources.ContextEcho
  alias SnodoTest.TestResources.DeclaredError
  alias SnodoTest.TestResources.PackageTemplate
  alias SnodoTest.TestResources.PackageTemplateCollision
  alias SnodoTest.TestResources.Raising
  alias SnodoTest.TestResources.RaisingMatcher
  alias SnodoTest.TestResources.StaticBlob
  alias SnodoTest.TestResources.StaticJSON
  alias SnodoTest.TestResources.StaticShadowTemplate
  alias SnodoTest.TestResources.StaticText
  alias SnodoTest.TestResources.StaticTextNameCollision
  alias SnodoTest.TestResources.StaticTextURICollision
  alias SnodoTest.TestResources.TermError
  alias SnodoTest.TestResources.WrongResultKind

  defp context(overrides \\ []) do
    defaults = [
      protocol_version: "2026-07-28",
      protocol: V2026_07_28,
      transport: %TransportContext{transport: :direct},
      request_id: "resource-request",
      auth: %{"tenant" => "fixture"},
      metadata: %{"com.example/request" => %{"trace" => [1, 2, 3]}}
    ]

    struct!(Context, Keyword.merge(defaults, overrides))
  end

  defp read(router, uri, params \\ %{}, request_context \\ context()) do
    Router.dispatch(
      router,
      {:resource_read, uri},
      Map.put(params, "uri", uri),
      request_context
    )
  end

  test "registration is immutable, idempotent, and listings are deterministic" do
    empty = Router.new()

    router =
      empty
      |> Router.register_resource(StaticText)
      |> Router.register_resource(PackageTemplate)
      |> Router.register_resource(StaticBlob)
      |> Router.register_resource(ArchiveTemplate)
      |> Router.register_resource(StaticJSON)

    assert empty.resources == %{}
    assert empty.resource_templates == %{}
    assert empty.resource_names == %{}

    assert Enum.map(Router.list_resources(router), & &1.uri) == [
             "test://static/blob",
             "test://static/data",
             "test://static/readme"
           ]

    assert Enum.map(Router.list_resource_templates(router), & &1.uri_template) == [
             "test://archives/{year}/{name}",
             "test://packages/{name}"
           ]

    assert Router.register_resource(router, StaticText) == router

    assert {:ok, %Result{kind: :resources, value: direct}} =
             Router.dispatch(router, :resources_list, %{}, context())

    assert {:ok, %Result{kind: :resource_templates, value: templates}} =
             Router.dispatch(router, :resource_templates_list, %{}, context())

    assert direct == Router.list_resources(router)
    assert templates == Router.list_resource_templates(router)
  end

  test "definition and content metadata survive the protocol-neutral boundary unchanged" do
    router = Router.new() |> Router.register_resource(StaticText)
    assert [%Definition{} = definition] = Router.list_resources(router)
    assert definition == Resource.definition(StaticText)

    assert Resource.definition_to_map(definition) == %{
             "uri" => "test://static/readme",
             "name" => "static_readme",
             "title" => "Static README",
             "description" => "A protocol-neutral text resource fixture",
             "mimeType" => "text/markdown",
             "size" => 18,
             "icons" => [
               %{
                 "src" => "https://example.test/readme.svg",
                 "mimeType" => "image/svg+xml",
                 "sizes" => ["any"],
                 "theme" => "dark",
                 "com.example/icon" => "preserved"
               }
             ],
             "annotations" => %{
               "audience" => ["user"],
               "priority" => 0.8,
               "lastModified" => "2026-08-25T00:00:00Z",
               "com.example/tag" => "fixture"
             },
             "_meta" => %{
               "com.example/resource" => %{
                 "tier" => "fixture",
                 "nested" => [true, 7, nil]
               }
             }
           }

    assert {:ok,
            %Result{
              kind: :resource_read,
              metadata: %{"com.example/result" => %{"kind" => "text"}},
              value: [content]
            }} = read(router, "test://static/readme")

    assert content == %{
             "uri" => "test://static/readme",
             "text" => "# Static resource\n",
             "mimeType" => "text/markdown",
             "annotations" => %{"audience" => ["assistant"], "priority" => 0.4},
             "_meta" => %{"com.example/content" => %{"preserved" => true}}
           }
  end

  test "application-owned matches?/1 controls template routing and receives original params" do
    router = Router.new() |> Router.register_resource(PackageTemplate)
    uri = "test://packages/plug"
    params = %{"uri" => uri, "com.example/request" => %{"preserve" => [true, nil]}}

    assert PackageTemplate.matches?(uri)
    refute PackageTemplate.matches?("test://packages/Plug")
    refute PackageTemplate.matches?("test://packages/plug/extra")

    assert {:ok, %Result{kind: :resource_read, value: [content]}} =
             Router.dispatch(router, {:resource_read, uri}, params, context())

    assert JSON.decode!(content["text"]) == %{
             "name" => "plug",
             "params" => params
           }

    assert content["uri"] == uri
    assert content["mimeType"] == "application/json"
    assert content["_meta"] == %{"com.example/content" => %{"template" => true}}

    assert {:error, %Error{code: -32_602, message: "Resource not found"}} =
             read(router, "test://packages/Plug")
  end

  test "text, JSON, and blob contents retain their distinct representations" do
    router =
      Router.new()
      |> Router.register_resource(StaticText)
      |> Router.register_resource(StaticJSON)
      |> Router.register_resource(StaticBlob)

    assert {:ok, %Result{value: [%{"text" => "# Static resource\n"} = text]}} =
             read(router, "test://static/readme")

    assert text["blob"] == nil

    assert {:ok,
            %Result{
              metadata: %{"com.example/result" => %{"kind" => "json"}},
              value: [%{"text" => encoded_json} = json]
            }} = read(router, "test://static/data")

    assert JSON.decode!(encoded_json) == %{
             "name" => "resource-json",
             "nested" => %{"values" => [true, 7, nil]}
           }

    assert json["mimeType"] == "application/json"
    assert json["_meta"] == %{"com.example/content" => "json"}

    assert {:ok,
            %Result{
              metadata: %{"com.example/result" => %{"kind" => "blob"}},
              value: [%{"blob" => encoded_blob} = blob]
            }} = read(router, "test://static/blob")

    assert Base.decode64!(encoded_blob) == <<0, 1, 2, 127, 128, 255>>
    assert blob["text"] == nil
    assert blob["mimeType"] == "application/octet-stream"
    assert blob["annotations"] == %{"audience" => ["assistant"]}
    assert blob["_meta"] == %{"com.example/content" => "blob"}
  end

  test "resource callbacks receive the original immutable request context" do
    router = Router.new() |> Router.register_resource(ContextEcho)
    request_context = context(request_id: 42)
    original = request_context

    assert {:ok, %Result{value: [%{"text" => encoded}]}} =
             read(router, "test://context", %{"owner" => self()}, request_context)

    assert_receive {:resource_context, ^request_context}
    assert request_context == original

    assert JSON.decode!(encoded) == %{
             "protocolVersion" => "2026-07-28",
             "requestId" => 42,
             "auth" => %{"tenant" => "fixture"},
             "metadata" => %{"com.example/request" => %{"trace" => [1, 2, 3]}}
           }
  end

  test "duplicate URI, template, and name registrations never overwrite" do
    direct = Router.new() |> Router.register_resource(StaticText)

    assert_raise ArgumentError, ~r/resource URI .* already registered/, fn ->
      Router.register_resource(direct, StaticTextURICollision)
    end

    assert_raise ArgumentError, ~r/resource name .* already registered/, fn ->
      Router.register_resource(direct, StaticTextNameCollision)
    end

    assert direct.resources == %{"test://static/readme" => StaticText}
    assert direct.resource_names == %{"static_readme" => StaticText}

    templates = Router.new() |> Router.register_resource(PackageTemplate)

    assert_raise ArgumentError, ~r/resource URI template .* already registered/, fn ->
      Router.register_resource(templates, PackageTemplateCollision)
    end

    assert templates.resource_templates == %{"test://packages/{name}" => PackageTemplate}
  end

  test "registration rejects a direct URI and template that already overlap" do
    direct = Router.new() |> Router.register_resource(StaticText)

    assert_raise ArgumentError, ~r/also matches URI owned by/, fn ->
      Router.register_resource(direct, StaticShadowTemplate)
    end

    template = Router.new() |> Router.register_resource(StaticShadowTemplate)

    assert_raise ArgumentError, ~r/already matched by/, fn ->
      Router.register_resource(template, StaticText)
    end
  end

  test "runtime ambiguity fails closed instead of choosing by registration order" do
    router_a_first =
      Router.new()
      |> Router.register_resource(AmbiguousTemplateA)
      |> Router.register_resource(AmbiguousTemplateB)

    router_b_first =
      Router.new()
      |> Router.register_resource(AmbiguousTemplateB)
      |> Router.register_resource(AmbiguousTemplateA)

    for router <- [router_a_first, router_b_first] do
      assert {:error,
              %Error{
                code: -32_603,
                kind: :execution,
                message: "Multiple resource routes matched the requested URI"
              }} = read(router, "test://ambiguous/value")
    end
  end

  test "missing resources are protocol-neutral invalid-params errors with the URI" do
    uri = "test://missing/resource"

    assert {:error,
            %Error{
              code: -32_602,
              kind: :protocol,
              message: "Resource not found",
              data: %{"uri" => ^uri}
            }} = read(Router.new(), uri)
  end

  test "declared errors survive while terms, exceptions, and wrong results fail closed" do
    router =
      Router.new()
      |> Router.register_resource(DeclaredError)
      |> Router.register_resource(TermError)
      |> Router.register_resource(Raising)
      |> Router.register_resource(WrongResultKind)

    assert {:error,
            %Error{
              code: -32_602,
              message: "Resource access denied",
              data: %{"reason" => "fixture"}
            }} = read(router, "test://errors/declared")

    assert {:error,
            %Error{
              code: -32_603,
              message: "Resource read failed",
              cause: :backend_offline
            }} = read(router, "test://errors/term")

    assert {:error, %Error{code: -32_603, message: "Resource raised an exception"}} =
             read(router, "test://errors/raise")

    assert {:error, %Error{code: -32_603, message: "Resource returned the wrong result kind"}} =
             read(router, "test://errors/wrong-kind")
  end

  test "matcher exceptions fail closed as resource routing errors" do
    router = Router.new() |> Router.register_resource(RaisingMatcher)

    assert {:error,
            %Error{
              code: -32_603,
              kind: :execution,
              message: "Resource matcher failed",
              cause: {:matcher_raised, RaisingMatcher, %RuntimeError{}, _stacktrace}
            }} = read(router, "test://matcher/boom")
  end
end
