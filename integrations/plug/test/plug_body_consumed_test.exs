defmodule Snodo.Transport.PlugBodyConsumedTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog
  import Plug.Conn
  import Plug.Test

  alias Snodo.Transport.Plug, as: TransportPlug

  @opts %{path: "/mcp"}

  test "a request whose body a parser already consumed gets an explicit 500 and a log line" do
    conn =
      :post
      |> conn("/mcp", ~s({"jsonrpc":"2.0"}))
      |> put_req_header("content-type", "application/json")
      |> Plug.Parsers.call(Plug.Parsers.init(parsers: [:json], json_decoder: JSON))

    assert is_map(conn.body_params)

    log =
      capture_log(fn ->
        send(self(), {:conn, TransportPlug.call(conn, @opts)})
      end)

    assert_received {:conn, conn}
    assert conn.status == 500
    assert conn.halted
    assert %{"error" => %{"code" => -32_603, "message" => message}} = JSON.decode!(conn.resp_body)
    assert message =~ "already consumed"
    assert message =~ "before the parser"
    assert log =~ "already consumed"
  end

  test "other paths are unaffected by a parsed body" do
    conn = :post |> conn("/other", "") |> Map.put(:body_params, %{})
    assert TransportPlug.call(conn, @opts).status == 404
  end
end
