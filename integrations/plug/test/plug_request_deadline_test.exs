defmodule Snodo.Transport.PlugRequestDeadlineTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias Snodo.Server.Executor
  alias Snodo.Subscription.Hub
  alias Snodo.Transport.Plug, as: TransportPlug
  alias SnodoTest.PlugFixtures

  test "queue expiry gets 504 even with an infinite injected executor default" do
    executor =
      start_supervised!(
        {Executor, max_concurrency: 1, max_queue_wait: 0, default_timeout: :infinity}
      )

    assert {:ok, _ref} = Executor.submit(executor, :blocker, fn _ -> Process.sleep(:infinity) end)
    runtime = PlugFixtures.runtime(start_supervised!(Hub))

    opts =
      TransportPlug.init(runtime: runtime, executor: executor, disconnect_probe_ms: :infinity)

    assert opts.request_timeout == 30_000

    body =
      JSON.encode!(%{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "tools/list",
        "params" => %{
          "_meta" => %{
            "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
            "io.modelcontextprotocol/clientCapabilities" => %{}
          }
        }
      })

    response =
      :post
      |> conn("http://localhost/mcp", body)
      |> put_req_header("content-type", "application/json")
      |> put_req_header("content-length", Integer.to_string(byte_size(body)))
      |> put_req_header("accept", "application/json, text/event-stream")
      |> put_req_header("mcp-protocol-version", "2026-07-28")
      |> put_req_header("mcp-method", "tools/list")
      |> TransportPlug.call(opts)

    assert response.status == 504

    assert %{
             "id" => 1,
             "error" => %{
               "code" => -32_603,
               "message" => "Request expired in the execution queue"
             }
           } = JSON.decode!(response.resp_body)

    assert %{queued: 0, running: 1} = Executor.stats(executor)
    assert :ok = Executor.cancel(executor, :blocker)
  end
end
