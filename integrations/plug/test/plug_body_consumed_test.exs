defmodule Snodo.Transport.PlugBodyConsumedTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog
  import Plug.Conn
  import Plug.Test

  alias Snodo.Subscription.Hub
  alias Snodo.Transport.Plug, as: TransportPlug
  alias SnodoTest.PlugFixtures

  @json_parser Plug.Parsers.init(parsers: [:json], json_decoder: JSON)
  @pass_parser Plug.Parsers.init(parsers: [:json], pass: ["*/*"], json_decoder: JSON)

  setup do
    runtime = PlugFixtures.runtime(start_supervised!(Hub))
    %{opts: TransportPlug.init(runtime: runtime, executor: self())}
  end

  # Plug.Test sets no content-length; a real server always does for a body.
  defp post(path, body, content_type) do
    :post
    |> conn(path, body)
    |> put_req_header("content-type", content_type)
    |> put_req_header("content-length", Integer.to_string(byte_size(body)))
  end

  test "a body a parser already consumed gets an explicit 500 and a log line", %{opts: opts} do
    conn =
      "/mcp" |> post(~s({"jsonrpc":"2.0"}), "application/json") |> Plug.Parsers.call(@json_parser)

    log =
      capture_log(fn ->
        send(self(), {:conn, TransportPlug.call(conn, opts)})
      end)

    assert_received {:conn, conn}
    assert conn.status == 500
    assert conn.halted
    assert %{"error" => %{"code" => -32_603, "message" => message}} = JSON.decode!(conn.resp_body)
    assert message =~ "already consumed"
    assert message =~ "before the parser"
    assert log =~ "already consumed"
  end

  test "a body a pass-through parser left unread is read and admitted", %{opts: opts} do
    conn = "/mcp" |> post("not json", "text/plain") |> Plug.Parsers.call(@pass_parser)
    assert %Plug.Conn.Unfetched{} = conn.body_params

    conn = TransportPlug.call(conn, opts)
    refute conn.status == 500
    refute conn.resp_body =~ "already consumed"
  end

  test "params another plug set on a bodyless request are not taken as a consumed body", %{
    opts: opts
  } do
    conn = :post |> conn("/mcp") |> Map.put(:body_params, %{"set" => "elsewhere"})

    conn = TransportPlug.call(conn, opts)
    refute conn.status == 500
    refute conn.resp_body =~ "already consumed"
  end

  test "other paths are unaffected by a parsed body", %{opts: opts} do
    conn = "/other" |> post(~s({"a":1}), "application/json") |> Plug.Parsers.call(@json_parser)
    assert TransportPlug.call(conn, opts).status == 404
  end
end
