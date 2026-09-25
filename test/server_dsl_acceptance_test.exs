defmodule Snodo.ServerDslAcceptanceTest do
  use ExUnit.Case, async: true

  alias Snodo.Protocol.V2026_07_28
  alias Snodo.Server.Runtime
  alias SnodoTest.TestPrompts.PackageAnalysis
  alias SnodoTest.TestResources.StaticText
  alias SnodoTest.TestServer
  alias SnodoTest.TestTools.ContextEcho
  alias SnodoTest.TestTools.Echo

  defmodule AttributeIdentityServer do
    @moduledoc false
    @version "9.8.7"

    use Snodo.Server,
      name: "attribute-identity",
      version: @version,
      protocols: [Snodo.Protocol.V2026_07_28]
  end

  defmodule ConfiguredValidator do
    @moduledoc false
    @behaviour Snodo.Schema.Validator

    @impl true
    def validate(_instance, _schema), do: :ok
  end

  defmodule ValidatedServer do
    @moduledoc false

    use Snodo.Server,
      name: "validated",
      version: "1.0.0",
      protocols: [Snodo.Protocol.V2026_07_28],
      schema_validator: ConfiguredValidator
  end

  test "the DSL generates router and runtime builders without starting a process" do
    {:links, before_links} = Process.info(self(), :links)
    router = TestServer.router()
    runtime = TestServer.runtime()
    {:links, after_links} = Process.info(self(), :links)

    assert router.tools == %{"context_echo" => ContextEcho, "echo" => Echo}
    assert router.prompts == %{"package_analysis" => PackageAnalysis}
    assert router.resources == %{"test://static/readme" => StaticText}
    assert router.resource_templates == %{}
    assert %Runtime{} = runtime
    assert runtime.router == router
    assert runtime.server_info == %{"name" => "dsl-server", "version" => "1.2.3"}
    assert runtime.protocol_registry.protocols == [V2026_07_28]
    assert runtime.tools_cache == %{ttl_ms: 5, scope: "private"}
    assert runtime.prompts_cache == %{ttl_ms: 20, scope: "private"}
    assert runtime.resources_cache == %{ttl_ms: 30, scope: "public"}
    assert runtime.pagination.page_size == 2
    assert runtime.capabilities == %{"prompts" => %{}, "resources" => %{}, "tools" => %{}}
    assert before_links == after_links
  end

  test "runtime overrides are explicit and child_spec only wraps configured transports" do
    runtime = TestServer.runtime(tools_cache: [ttl_ms: 99, scope: "public"])
    assert runtime.tools_cache == %{ttl_ms: 99, scope: "public"}

    resource_runtime =
      TestServer.runtime(resources_cache: [ttl_ms: 123, scope: "private"])

    assert resource_runtime.resources_cache == %{ttl_ms: 123, scope: "private"}

    prompt_runtime = TestServer.runtime(prompts_cache: [ttl_ms: 77, scope: "public"])
    assert prompt_runtime.prompts_cache == %{ttl_ms: 77, scope: "public"}

    pagination_runtime = TestServer.runtime(pagination: [page_size: 1])
    assert pagination_runtime.pagination.page_size == 1

    assert_raise ArgumentError, ~r/positive integer/, fn ->
      TestServer.runtime(pagination: [page_size: 0])
    end

    assert %{type: :supervisor, start: {Snodo.Server.Supervisor, :start_link, [opts]}} =
             TestServer.child_spec([])

    assert %Runtime{} = opts[:runtime]
    assert opts[:transports] == []
  end

  test "server identity accepts compile-time module attributes" do
    assert AttributeIdentityServer.runtime().server_info == %{
             "name" => "attribute-identity",
             "version" => "9.8.7"
           }
  end

  test "server configuration carries an application schema validator into every runtime" do
    assert ValidatedServer.runtime().schema_validator == ConfiguredValidator
  end
end
