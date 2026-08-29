defmodule MCP.ExtensionAcceptanceTest do
  use ExUnit.Case, async: true

  alias MCP.Protocol.V2026_07_28
  alias MCP.Server
  alias MCP.Transport.Context, as: TransportContext
  alias MCP.Transport.Stdio
  alias MCPEx.ExtensionTestServer
  alias MCPEx.FutureDialect
  alias MCPEx.TestExtensions.AroundInner
  alias MCPEx.TestExtensions.AroundOuter
  alias MCPEx.TestExtensions.CoreEmbeddedCollision
  alias MCPEx.TestExtensions.CoreImplementedCollision
  alias MCPEx.TestExtensions.CoreUnsupportedCollision
  alias MCPEx.TestExtensions.CrossCollisionA
  alias MCPEx.TestExtensions.CrossCollisionB
  alias MCPEx.TestExtensions.DuplicateId
  alias MCPEx.TestExtensions.Echo
  alias MCPEx.TestExtensions.Faulty
  alias MCPEx.TestExtensions.FaultyAround
  alias MCPEx.TestExtensions.FutureAround
  alias MCPEx.TestExtensions.IncompleteSubscriptions
  alias MCPEx.TestExtensions.NotNegotiated
  alias MCPEx.TestExtensions.RequiredCapability
  alias MCPEx.TestExtensions.UnavailableVersion
  alias MCPEx.TestFixtures

  @tag mcp_contract: ["extension-registration"]
  test "registration rejects collisions with every part of the exact core catalog" do
    for extension <- [
          CoreImplementedCollision,
          CoreUnsupportedCollision,
          CoreEmbeddedCollision
        ] do
      assert_raise ArgumentError, ~r/collides with the 2026-07-28 core catalog/, fn ->
        TestFixtures.runtime(extensions: [extension])
      end
    end
  end

  test "registration rejects extension-to-extension collisions and duplicate IDs" do
    assert_raise ArgumentError, ~r/is already registered for 2026-07-28/, fn ->
      TestFixtures.runtime(extensions: [CrossCollisionA, CrossCollisionB])
    end

    assert_raise ArgumentError, ~r/duplicate extension id "com.example\/echo"/, fn ->
      TestFixtures.runtime(extensions: [Echo, DuplicateId])
    end
  end

  test "registration rejects an exact version absent from the protocol registry" do
    assert_raise ArgumentError, ~r/targets unavailable protocol 2099-12-31/, fn ->
      TestFixtures.runtime(extensions: [UnavailableVersion])
    end
  end

  test "registration requires subscription filter and event hooks as one lifecycle pair" do
    assert_raise ArgumentError, ~r/must export both subscription_filter\/2/, fn ->
      TestFixtures.runtime(extensions: [IncompleteSubscriptions])
    end
  end

  test "registration accepts keyword and map options and rejects malformed entries" do
    keyword_options = [owner: self(), label: "outer"]
    map_options = %{owner: self(), label: "inner"}

    runtime =
      TestFixtures.runtime(
        extensions: [{AroundOuter, keyword_options}, {AroundInner, map_options}],
        capabilities: middleware_capabilities([AroundOuter, AroundInner])
      )

    assert runtime.extension_registry.options_by_id == %{
             AroundOuter.id() => keyword_options,
             AroundInner.id() => map_options
           }

    assert_raise ArgumentError, ~r/extension options must be a keyword list or map/, fn ->
      TestFixtures.runtime(extensions: [{Echo, [:not_a_keyword]}])
    end

    assert_raise ArgumentError, ~r/extension entries must be modules/, fn ->
      TestFixtures.runtime(extensions: [{"not-a-module", %{}}])
    end
  end

  test "advertised middleware nests in registration order and propagates a derived context" do
    outer_options = [owner: self(), label: "outer"]
    inner_options = %{owner: self(), label: "inner"}

    runtime =
      TestFixtures.runtime(
        extensions: [{AroundOuter, outer_options}, {AroundInner, inner_options}],
        capabilities: middleware_capabilities([AroundOuter, AroundInner])
      )

    response =
      dispatch_direct(
        runtime,
        request("around-unnegotiated", "tools/call", %{
          "name" => "context_echo",
          "arguments" => %{}
        })
      )

    expected_options = %{
      AroundOuter.id() => outer_options,
      AroundInner.id() => inner_options
    }

    assert_receive {:around_dispatch, "outer", :before, false, ^outer_options, ^expected_options,
                    []}

    assert_receive {:around_dispatch, "inner", :before, false, ^inner_options, ^expected_options,
                    ["outer"]}

    assert_receive {:around_dispatch, "inner", :after, false, ^inner_options}
    assert_receive {:around_dispatch, "outer", :after, false, ^outer_options}

    assert get_in(response, [
             "result",
             "structuredContent",
             "metadata",
             "middlewareTrace"
           ]) == ["outer", "inner"]
  end

  test "the same advertised middleware runs after peer negotiation" do
    outer_options = [owner: self(), label: "outer"]

    runtime =
      TestFixtures.runtime(
        extensions: [{AroundOuter, outer_options}],
        capabilities: middleware_capabilities([AroundOuter])
      )

    response =
      dispatch_direct(
        runtime,
        request(
          "around-negotiated",
          "tools/call",
          %{"name" => "context_echo", "arguments" => %{}},
          %{AroundOuter.id() => %{}}
        )
      )

    expected_options = %{AroundOuter.id() => outer_options}

    assert_receive {:around_dispatch, "outer", :before, true, ^outer_options, ^expected_options,
                    []}

    assert_receive {:around_dispatch, "outer", :after, true, ^outer_options}

    assert get_in(response, [
             "result",
             "structuredContent",
             "metadata",
             "middlewareTrace"
           ]) == ["outer"]
  end

  test "installed but unadvertised middleware remains inert" do
    runtime =
      TestFixtures.runtime(extensions: [{AroundOuter, owner: self(), label: "not-advertised"}])

    response =
      dispatch_direct(
        runtime,
        request("around-installed-only", "tools/call", %{
          "name" => "context_echo",
          "arguments" => %{}
        })
      )

    refute_receive {:around_dispatch, _label, _stage, _negotiated, _options, _all_options, _trace}

    refute_receive {:around_dispatch, _label, _stage, _negotiated, _options}

    assert get_in(response, [
             "result",
             "structuredContent",
             "metadata",
             "middlewareTrace"
           ]) == nil
  end

  test "middleware and application options are restricted to the selected exact version" do
    current_options = [owner: self(), label: "current"]
    future_options = %{owner: self(), label: "future"}

    runtime =
      TestFixtures.runtime(
        protocols: [V2026_07_28, FutureDialect],
        extensions: [{AroundOuter, current_options}, {FutureAround, future_options}],
        capabilities: middleware_capabilities([AroundOuter, FutureAround])
      )

    raw = %{
      "jsonrpc" => "2.0",
      "id" => "future-around",
      "method" => "acme/echo",
      "params" => %{
        "name" => "echo",
        "arguments" => %{"text" => "future"},
        "_meta" => %{
          "com.acme/protocolVersion" => "2099-01-01",
          "com.acme/clientCapabilities" => %{}
        }
      }
    }

    assert %{"result" => %{"futureValue" => "future"}} = dispatch_direct(runtime, raw)

    expected_options = %{FutureAround.id() => future_options}

    assert_receive {:around_dispatch, "future", :before, false, ^future_options,
                    ^expected_options, []}

    assert_receive {:around_dispatch, "future", :after, false, ^future_options}

    refute_receive {:around_dispatch, "current", _stage, _negotiated, _options, _all_options,
                    _trace}

    refute_receive {:around_dispatch, "current", _stage, _negotiated, _options}
  end

  test "middleware may short-circuit core execution" do
    runtime =
      TestFixtures.runtime(
        extensions: [{FaultyAround, mode: :short_circuit}],
        capabilities: middleware_capabilities([FaultyAround])
      )

    response =
      dispatch_direct(
        runtime,
        request("around-short-circuit", "tools/call", %{
          "name" => "not-registered",
          "arguments" => %{}
        })
      )

    assert get_in(response, ["result", "content"]) == [
             %{"type" => "text", "text" => "short-circuited"}
           ]
  end

  test "raised and invalid middleware results become safe internal errors" do
    for mode <- [:raise, :invalid] do
      runtime =
        TestFixtures.runtime(
          extensions: [{FaultyAround, mode: mode}],
          capabilities: middleware_capabilities([FaultyAround])
        )

      response = dispatch_direct(runtime, request("around-#{mode}", "tools/list"))

      assert get_in(response, ["error", "code"]) == -32_603
      refute inspect(response) =~ "private"
      refute inspect(response) =~ "implementation detail"
    end
  end

  test "an advertised extension can override only its missing-client-capability error" do
    required_id = RequiredCapability.id()

    runtime =
      TestFixtures.runtime(
        extensions: [{RequiredCapability, mode: :required}],
        capabilities: extension_capabilities(RequiredCapability)
      )

    missing =
      dispatch_direct(
        runtime,
        request("required-missing", RequiredCapability.id())
      )

    assert %{
             "error" => %{
               "code" => -32_021,
               "data" => %{
                 "requiredCapabilities" => %{
                   "extensions" => %{^required_id => %{}}
                 }
               }
             }
           } = missing

    negotiated =
      dispatch_direct(
        runtime,
        request(
          "required-present",
          RequiredCapability.id(),
          %{},
          %{RequiredCapability.id() => %{}}
        )
      )

    assert %{"result" => %{"value" => _value}} = negotiated

    installed_only =
      TestFixtures.runtime(extensions: [{RequiredCapability, mode: :raise}])

    assert method_not_found?(
             dispatch_direct(
               installed_only,
               request("required-not-advertised", RequiredCapability.id())
             )
           )
  end

  test "missing-capability callback failures are contained without leaking" do
    for mode <- [:raise, :invalid] do
      runtime =
        TestFixtures.runtime(
          extensions: [{RequiredCapability, mode: mode}],
          capabilities: extension_capabilities(RequiredCapability)
        )

      response =
        dispatch_direct(
          runtime,
          request("required-callback-#{mode}", RequiredCapability.id())
        )

      assert get_in(response, ["error", "code"]) == -32_603
      refute inspect(response) =~ "private"
      refute inspect(response) =~ "implementation detail"
    end
  end

  test "installed and advertised are distinct and discovery projects only enabled extensions" do
    assert_raise ArgumentError, ~r/advertises unregistered extension "com.example\/echo"/, fn ->
      TestFixtures.runtime(capabilities: extension_capabilities(Echo))
    end

    installed_only = TestFixtures.runtime(extensions: [Echo])

    assert %{"result" => %{"capabilities" => capabilities}} =
             dispatch_direct(installed_only, request("discover-installed", "server/discover"))

    refute Map.has_key?(capabilities, "extensions")

    assert method_not_found?(
             dispatch_direct(
               installed_only,
               request("installed-only", "com.example/echo", %{"value" => "ignored"}, %{
                 Echo.id() => %{"mode" => "client"}
               })
             )
           )

    enabled =
      TestFixtures.runtime(
        extensions: [Echo],
        capabilities: extension_capabilities(Echo, %{"mode" => "server"})
      )

    assert %{
             "result" => %{
               "capabilities" => %{
                 "extensions" => %{"com.example/echo" => %{"mode" => "server"}}
               }
             }
           } = dispatch_direct(enabled, request("discover-enabled", "server/discover"))
  end

  test "both peers must advertise and the extension must accept negotiation" do
    enabled =
      TestFixtures.runtime(
        extensions: [Echo],
        capabilities: extension_capabilities(Echo, %{"mode" => "server"})
      )

    assert dispatch_direct(
             enabled,
             request("client-missing", "com.example/echo", %{"value" => "ignored"})
           )
           |> method_not_found?()

    not_negotiated =
      TestFixtures.runtime(
        extensions: [NotNegotiated],
        capabilities: extension_capabilities(NotNegotiated)
      )

    assert dispatch_direct(
             not_negotiated,
             request(
               "declined",
               "com.example/not-negotiated",
               %{},
               %{NotNegotiated.id() => %{}}
             )
           )
           |> method_not_found?()
  end

  @tag mcp_contract: ["extension-negotiation-dispatch"]
  test "negotiated settings reach validation, dispatch, and result shaping" do
    runtime = echo_runtime()

    response =
      dispatch_direct(
        runtime,
        request(
          "echo-success",
          "com.example/echo",
          %{"value" => "hello"},
          %{Echo.id() => %{"mode" => "client"}}
        )
      )

    negotiated = %{"clientMode" => "client", "serverMode" => "server"}

    assert response == %{
             "jsonrpc" => "2.0",
             "id" => "echo-success",
             "result" => %{
               "extensionResult" => %{
                 "value" => "hello",
                 "negotiated" => negotiated
               },
               "contextExtensions" => %{Echo.id() => negotiated}
             }
           }
  end

  test "extension validation and dispatch errors use the extension error dialect" do
    runtime = echo_runtime()
    client_extensions = %{Echo.id() => %{"mode" => "client"}}

    invalid =
      dispatch_direct(
        runtime,
        request("invalid", "com.example/echo", %{"value" => 7}, client_extensions)
      )

    assert %{
             "id" => "invalid",
             "error" => %{
               "code" => -32_602,
               "message" => "Echo extension rejected the request",
               "data" => %{
                 "negotiated" => %{"clientMode" => "client", "serverMode" => "server"},
                 "originalData" => %{
                   "extension" => "com.example/echo",
                   "field" => "value"
                 }
               }
             }
           } = invalid

    failed =
      dispatch_direct(
        runtime,
        request(
          "dispatch-error",
          "com.example/echo",
          %{"value" => "dispatch-error"},
          client_extensions
        )
      )

    assert get_in(failed, ["error", "code"]) == -32_603
    assert get_in(failed, ["error", "message"]) == "Echo extension rejected the request"
    refute inspect(failed) =~ "private_dispatch_cause"
  end

  test "raised validation, dispatch, result, and error callbacks never leak implementation details" do
    runtime =
      TestFixtures.runtime(
        extensions: [Faulty],
        capabilities: extension_capabilities(Faulty)
      )

    for stage <- ~w(validate dispatch shape_result shape_error) do
      response =
        dispatch_direct(
          runtime,
          request(
            "fault-#{stage}",
            "com.example/faulty",
            %{"stage" => stage},
            %{Faulty.id() => %{}}
          )
        )

      assert get_in(response, ["error", "code"]) == -32_603
      refute inspect(response) =~ "private"
      refute inspect(response) =~ "implementation detail"
    end
  end

  test "the same negotiated extension has exact direct and stdio behavior" do
    runtime = echo_runtime()

    raw =
      request(
        "transport-parity",
        "com.example/echo",
        %{"value" => "same"},
        %{Echo.id() => %{"mode" => "client"}}
      )

    assert dispatch_direct(runtime, raw) == dispatch_stdio(runtime, raw)
  end

  test "the declarative server DSL installs and advertises an out-of-tree extension" do
    runtime = ExtensionTestServer.runtime()

    response =
      dispatch_direct(
        runtime,
        request(
          "dsl-extension",
          "com.example/echo",
          %{"value" => "from-dsl"},
          %{Echo.id() => %{"mode" => "client"}}
        )
      )

    assert get_in(response, ["result", "extensionResult", "value"]) == "from-dsl"
    assert get_in(response, ["result", "extensionResult", "negotiated", "serverMode"]) == "server"
  end

  defp echo_runtime do
    TestFixtures.runtime(
      extensions: [Echo],
      capabilities: extension_capabilities(Echo, %{"mode" => "server"})
    )
  end

  defp extension_capabilities(extension, settings \\ %{}) do
    %{
      "tools" => %{},
      "extensions" => %{extension.id() => settings}
    }
  end

  defp middleware_capabilities(extensions) do
    %{
      "tools" => %{},
      "extensions" => Map.new(extensions, &{&1.id(), %{}})
    }
  end

  defp request(id, method, params \\ %{}, client_extensions \\ %{}) do
    client_capabilities =
      if client_extensions == %{},
        do: %{},
        else: %{"extensions" => client_extensions}

    %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => method,
      "params" =>
        %{
          "_meta" => V2026_07_28.request_metadata(client_capabilities)
        }
        |> Map.merge(params)
    }
  end

  defp dispatch_direct(runtime, raw) do
    assert {:ok, response} =
             Server.dispatch(runtime, raw, %TransportContext{transport: :direct})

    response
  end

  defp dispatch_stdio(runtime, raw) do
    {:ok, io} = StringIO.open(JSON.encode!(raw) <> "\n")
    assert :ok = Stdio.serve(runtime, input: io, output: io)
    {_input, output} = StringIO.contents(io)
    output |> String.trim() |> JSON.decode!()
  end

  defp method_not_found?(%{"error" => %{"code" => -32_601}}), do: true
  defp method_not_found?(_response), do: false
end
