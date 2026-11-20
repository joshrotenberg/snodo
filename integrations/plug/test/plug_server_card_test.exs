defmodule Snodo.Transport.PlugServerCardTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias Snodo.Router
  alias Snodo.Server.Runtime
  alias Snodo.Transport.Plug, as: TransportPlug

  @path "/services/mcp/server-card"
  @endpoint "https://example.com/services/mcp"

  setup do
    runtime =
      Runtime.new(
        router: Router.new(),
        protocols: [Snodo.Protocol.V2026_07_28],
        server_info: %{
          "name" => "com.example/weather",
          "version" => "1.2.3",
          "description" => "Weather forecasts"
        }
      )

    %{
      options: [
        runtime: runtime,
        executor: self(),
        path: "/services/mcp",
        allowed_hosts: ["example.com"]
      ]
    }
  end

  test "the card route is disabled by default", %{options: options} do
    assert TransportPlug.call(conn(:get, @path), TransportPlug.init(options)).status == 404
  end

  test "rejects invalid card configuration in init", %{options: options} do
    assert_raise ArgumentError, ~r/:server_card must be false or/, fn ->
      TransportPlug.init(Keyword.put(options, :server_card, true))
    end
  end

  test "appends the card suffix to an endpoint with a trailing slash", %{options: options} do
    opts =
      options
      |> Keyword.merge(path: "/mcp/", server_card: %{endpoint_url: "https://example.com/mcp/"})
      |> TransportPlug.init()

    card = :get |> conn("/mcp/server-card") |> with_host() |> TransportPlug.call(opts)
    double_slash = :get |> conn("/mcp//server-card") |> with_host() |> TransportPlug.call(opts)
    assert card.status == 200
    assert double_slash.status == 404
  end

  test "publishes a public card with CORS and conditional GET", %{options: options} do
    opts = TransportPlug.init([server_card: %{endpoint_url: @endpoint}] ++ options)

    request =
      :get
      |> conn(@path <> "?ignored=secret")
      |> with_host()
      |> put_req_header("origin", "https://browser.example")
      |> put_req_header("authorization", "Bearer secret")
      |> assign(:mcp_auth, %{token: "secret"})

    response = TransportPlug.call(request, opts)

    assert response.status == 200
    assert response.halted
    assert get_resp_header(response, "content-type") == ["application/mcp-server-card+json"]
    assert get_resp_header(response, "access-control-allow-origin") == ["*"]
    assert get_resp_header(response, "cache-control") == ["public, max-age=3600"]
    assert [etag] = get_resp_header(response, "etag")
    refute response.resp_body =~ "secret"
    assert %{"remotes" => [%{"url" => @endpoint}]} = JSON.decode!(response.resp_body)

    head = :head |> conn(@path) |> with_host() |> TransportPlug.call(opts)
    assert head.status == 200
    assert head.resp_body == ""

    assert get_resp_header(head, "content-length") == [
             Integer.to_string(byte_size(response.resp_body))
           ]

    assert get_resp_header(head, "etag") == [etag]

    conditional =
      request
      |> put_req_header("if-none-match", ~s("stale", W/#{etag}))
      |> TransportPlug.call(opts)

    assert conditional.status == 304
    assert conditional.resp_body == ""
    assert get_resp_header(conditional, "etag") == [etag]
  end

  test "enforces Host and handles methods and browser preflight", %{options: options} do
    opts = TransportPlug.init([server_card: %{endpoint_url: @endpoint}] ++ options)
    assert TransportPlug.call(conn(:get, @path), opts).status == 403

    post = :post |> conn(@path) |> with_host()
    response = TransportPlug.call(post, opts)
    assert response.status == 405
    assert get_resp_header(response, "allow") == ["GET, HEAD, OPTIONS"]

    options = :options |> conn(@path) |> with_host() |> TransportPlug.call(opts)
    assert options.status == 204
    assert get_resp_header(options, "allow") == ["GET, HEAD, OPTIONS"]

    preflight =
      :options
      |> conn(@path)
      |> with_host()
      |> put_req_header("origin", "https://browser.example")
      |> put_req_header("access-control-request-method", "GET")
      |> TransportPlug.call(opts)

    assert preflight.status == 204

    assert get_resp_header(preflight, "access-control-allow-headers") == [
             "Content-Type, If-None-Match"
           ]
  end

  # Plug.Test omits the raw Host header that the HTTP adapter supplies.
  defp with_host(conn), do: %{conn | req_headers: [{"host", "example.com"} | conn.req_headers]}
end
