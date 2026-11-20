defmodule Snodo.Compliance.V2025_11_25VectorsTest do
  use ExUnit.Case, async: true

  alias Snodo.Protocol.V2025_06_18
  alias Snodo.Protocol.V2025_11_25
  alias Snodo.Server
  alias Snodo.Session
  alias Snodo.Transport.Context, as: TransportContext
  alias SnodoTest.TestFixtures

  test "initialize carries client and server extension settings" do
    runtime =
      TestFixtures.runtime(
        protocols: [V2025_11_25],
        extensions: [{:declared, "com.example/ui", %{"version" => 1}}]
      )

    {:ok, session} = start_supervised({Session, runtime: runtime})
    transport = %TransportContext{transport: :stdio, metadata: %{session: Session.info(session)}}

    raw =
      JSON.decode!(~S"""
      {
        "jsonrpc": "2.0",
        "id": 1,
        "method": "initialize",
        "params": {
          "protocolVersion": "2025-11-25",
          "capabilities": {"extensions": {"com.example/ui": {"mimeTypes": ["text/html"]}}},
          "clientInfo": {"name": "compliance-client", "version": "1"}
        }
      }
      """)

    assert {:ok,
            %{
              "jsonrpc" => "2.0",
              "id" => 1,
              "result" => %{
                "protocolVersion" => "2025-11-25",
                "capabilities" => %{"extensions" => %{"com.example/ui" => %{"version" => 1}}}
              }
            }} = Server.dispatch(runtime, raw, transport)

    invalid =
      JSON.decode!(~S"""
      {
        "jsonrpc": "2.0",
        "id": 1,
        "method": "initialize",
        "params": {
          "protocolVersion": "2025-11-25",
          "capabilities": {"extensions": {"com.example/ui": true}},
          "clientInfo": {"name": "compliance-client", "version": "1"}
        }
      }
      """)

    assert {:ok, %{"id" => 1, "error" => %{"code" => -32_602}}} =
             Server.dispatch(runtime, invalid, transport)
  end

  test "initialize succeeds without an extensions capability" do
    runtime = TestFixtures.runtime(protocols: [V2025_11_25])

    raw =
      JSON.decode!(~S"""
      {
        "jsonrpc": "2.0",
        "id": 2,
        "method": "initialize",
        "params": {
          "protocolVersion": "2025-11-25",
          "capabilities": {},
          "clientInfo": {"name": "compliance-client", "version": "1"}
        }
      }
      """)

    assert {:ok,
            %{
              "jsonrpc" => "2.0",
              "id" => 2,
              "result" => %{"protocolVersion" => "2025-11-25", "capabilities" => capabilities}
            }} = Server.dispatch(runtime, raw, %TransportContext{transport: :direct})

    refute Map.has_key?(capabilities, "extensions")
  end

  test "2025-06-18 initialize omits extensions even when both peers declare one" do
    runtime =
      TestFixtures.runtime(
        protocols: [V2025_06_18],
        extensions: [{:declared, "com.example/ui", %{}}]
      )

    {:ok, session} = start_supervised({Session, runtime: runtime})
    transport = %TransportContext{transport: :stdio, metadata: %{session: Session.info(session)}}

    raw =
      JSON.decode!(~S"""
      {
        "jsonrpc": "2.0",
        "id": 3,
        "method": "initialize",
        "params": {
          "protocolVersion": "2025-06-18",
          "capabilities": {"extensions": {"com.example/ui": {}}},
          "clientInfo": {"name": "compliance-client", "version": "1"}
        }
      }
      """)

    assert {:ok,
            %{
              "id" => 3,
              "result" => %{"protocolVersion" => "2025-06-18", "capabilities" => capabilities}
            }} = Server.dispatch(runtime, raw, transport)

    refute Map.has_key?(capabilities, "extensions")
  end
end
