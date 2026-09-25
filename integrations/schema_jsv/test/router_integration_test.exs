defmodule Snodo.Schema.Validator.JSV.RouterIntegrationTest do
  use ExUnit.Case, async: true

  alias Snodo.Error
  alias Snodo.Result
  alias Snodo.Router
  alias Snodo.Schema.Validator.JSV, as: Validator
  alias SnodoTest.JSV.Echo
  alias SnodoTest.JSV.Server

  @meta %{
    "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
    "io.modelcontextprotocol/clientCapabilities" => %{}
  }

  test "the public server integration preserves advertised schemas and actual handler arguments" do
    response = request("tools/list", %{})
    echo = Enum.find(response["result"]["tools"], &(&1["name"] == "echo"))
    assert echo["inputSchema"] === Echo.input_schema()
    assert echo["outputSchema"] === Echo.output_schema()

    arguments = %{"count" => 1.0}
    response = request("tools/call", %{"name" => "echo", "arguments" => arguments})
    assert response["result"]["structuredContent"] === arguments
    assert Process.get(:jsv_echo_arguments) === arguments
    refute Map.has_key?(Process.get(:jsv_echo_arguments), "name")
  end

  test "invalid arguments are rejected before handlers run without leaking values" do
    response =
      request("tools/call", %{"name" => "echo", "arguments" => %{"count" => "private value"}})

    assert response["error"]["code"] == -32_602
    refute Process.get(:jsv_echo_arguments)
    refute inspect(response) =~ "private value"
  end

  test "output schema failures become internal errors" do
    response = request("tools/call", %{"name" => "bad_output"})
    assert response["error"]["code"] == -32_603
    refute Map.has_key?(response, "result")
  end

  test "bad schema is a server configuration failure, not invalid client arguments" do
    response = request("tools/call", %{"name" => "bad_schema"})
    assert response["error"]["code"] == -32_603
    refute Process.get(:jsv_bad_schema_called)
  end

  test "direct router callers can select the optional adapter without server macros" do
    router = Router.new() |> Router.register_tool(Echo)

    context = %Snodo.Context{
      protocol_version: "2026-07-28",
      protocol: Snodo.Protocol.V2026_07_28,
      transport: %Snodo.Transport.Context{transport: :direct}
    }

    assert {:ok, %Result{kind: :structured}} =
             Router.dispatch(
               router,
               {:tools_call, "echo"},
               %{"arguments" => %{"count" => 1}},
               context,
               schema_validator: Validator
             )

    assert {:error, %Error{code: -32_602}} =
             Router.dispatch(
               router,
               {:tools_call, "echo"},
               %{"arguments" => %{"extra" => true}},
               context,
               schema_validator: Validator
             )
  end

  defp request(method, params) do
    envelope = %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => method,
      "params" => Map.put(params, "_meta", @meta)
    }

    {:ok, response} =
      Snodo.Server.dispatch(Server.runtime(), envelope, %Snodo.Transport.Context{
        transport: :direct
      })

    response
  end
end
