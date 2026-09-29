defmodule Snodo.OAuth.ResourceServer.ScopePolicyTest do
  use ExUnit.Case, async: true

  alias Snodo.Client
  alias Snodo.OAuth.ResourceServer.ScopePolicy
  alias SnodoTest.OAuthFixtures, as: Fixtures

  @required %{
    {:tool, "write_thing"} => ["mcp:write"],
    {:resource, "demo://notes"} => ["notes:read"],
    {:prompt, "audit"} => ["audit", "mcp:read"]
  }

  defp runtime(policy_options) do
    router =
      Snodo.Router.new()
      |> Snodo.Router.register_tool(Fixtures.ReadTool)
      |> Snodo.Router.register_tool(Fixtures.WriteTool)
      |> Snodo.Router.register_resource(Fixtures.Notes)
      |> Snodo.Router.register_prompt(Fixtures.Audit)

    Snodo.Server.Runtime.new(
      router: router,
      protocols: [Snodo.Protocol.V2026_07_28],
      server_info: %{"name" => "scope-policy", "version" => "0.1.0"},
      authorization: {ScopePolicy, policy_options}
    )
  end

  defp client(runtime, scopes) do
    auth = if scopes, do: %{principal: "user-1", scopes: scopes}, else: nil
    {:ok, client} = Client.direct(runtime, auth: auth)
    client
  end

  defp names({:ok, items}), do: Enum.map(items, & &1["name"])

  test "discovery lists only the components whose scopes the caller holds" do
    runtime = runtime(required: @required, default: ["mcp:read"])

    read = client(runtime, ["mcp:read"])
    assert names(Client.list_tools(read)) == ["read_thing"]
    assert names(Client.list_resources(read)) == []
    assert names(Client.list_prompts(read)) == []

    all = client(runtime, ["mcp:read", "mcp:write", "notes:read", "audit"])
    assert names(Client.list_tools(all)) == ["read_thing", "write_thing"]
    assert names(Client.list_resources(all)) == ["notes"]
    assert names(Client.list_prompts(all)) == ["audit"]

    # Without the default scope, nothing is visible; all listed scopes are needed.
    partial = client(runtime, ["mcp:write", "audit"])
    assert names(Client.list_tools(partial)) == ["write_thing"]
    assert names(Client.list_prompts(partial)) == []
    assert names(Client.list_tools(client(runtime, []))) == []
    assert names(Client.list_tools(client(runtime, nil))) == []
  end

  test "invocation is refused with an insufficient_scope error before the handler runs" do
    runtime =
      runtime(
        required: @required,
        default: ["mcp:read"],
        resource_metadata: "https://mcp.example.test/prm"
      )

    read = client(runtime, ["mcp:read"])

    assert {:error, %Snodo.Error{code: -32_003} = error} =
             Client.call_tool(read, "write_thing", %{})

    assert error.message == "Insufficient scope for tool write_thing"

    assert error.data == %{
             "error" => "insufficient_scope",
             "scope" => "mcp:write",
             "resource_metadata" => "https://mcp.example.test/prm"
           }

    assert {:error, %Snodo.Error{code: -32_003, data: %{"scope" => "notes:read"}}} =
             Client.read_resource(read, "demo://notes")

    assert {:error, %Snodo.Error{code: -32_003, data: %{"scope" => "audit mcp:read"}}} =
             Client.get_prompt(read, "audit")

    assert {:ok, %{"structuredContent" => %{"principal" => "user-1", "scopes" => ["mcp:read"]}}} =
             Client.call_tool(read, "read_thing", %{})

    writer = client(runtime, ["mcp:read", "mcp:write"])

    assert {:ok, %{"content" => [%{"text" => "written"}]}} =
             Client.call_tool(writer, "write_thing", %{})
  end

  test "components without an entry need only the default, which is empty by default" do
    open = runtime(required: %{{:tool, "write_thing"} => ["mcp:write"]})
    anonymous = client(open, nil)
    assert names(Client.list_tools(anonymous)) == ["read_thing"]
    assert {:ok, _result} = Client.call_tool(anonymous, "read_thing", %{})
    assert {:error, %Snodo.Error{code: -32_003}} = Client.call_tool(anonymous, "write_thing", %{})
  end

  test "the error code is configurable and a resource may be keyed by name" do
    runtime = runtime(%{required: %{{:resource, "notes"} => ["notes:read"]}, code: -32_050})

    assert {:error, %Snodo.Error{code: -32_050, data: %{"scope" => "notes:read"}}} =
             Client.read_resource(client(runtime, []), "demo://notes")

    assert {:ok, _result} = Client.read_resource(client(runtime, ["notes:read"]), "demo://notes")
  end

  test "scopes/1 reads the bearer assign and ignores anything else" do
    context = %Snodo.Context{
      protocol_version: "2026-07-28",
      protocol: Snodo.Protocol.V2026_07_28,
      transport: %Snodo.Transport.Context{transport: :direct}
    }

    assert ScopePolicy.scopes(context) == []
    assert ScopePolicy.scopes(%{context | auth: %{principal: "u"}}) == []
    assert ScopePolicy.scopes(%{context | auth: %{scopes: "mcp:read"}}) == []
    assert ScopePolicy.scopes(%{context | auth: %{scopes: ["mcp:read"]}}) == ["mcp:read"]
  end
end
