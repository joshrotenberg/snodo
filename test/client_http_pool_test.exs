defmodule Snodo.ClientHTTPPoolTest do
  use ExUnit.Case, async: true

  alias Snodo.Client.HTTP
  alias Snodo.Client.HTTP.Pool
  alias Snodo.Protocol.V2026_07_28

  defmodule KeepAliveServer do
    @moduledoc false

    def start(owner, respond, scheme) do
      {module, listen} = listen(scheme)
      {:ok, {_address, port}} = sockname(module, listen)
      spawn_link(fn -> accept(module, listen, owner, respond) end)
      {"#{scheme}://127.0.0.1:#{port}/mcp", {module, listen}}
    end

    defp listen(:http) do
      {:ok, socket} =
        :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

      {:gen_tcp, socket}
    end

    defp listen(:https) do
      {:ok, _started} = Application.ensure_all_started(:ssl)
      fixture = Path.expand("support/fixtures", __DIR__)

      {:ok, socket} =
        :ssl.listen(0,
          certfile: String.to_charlist(Path.join(fixture, "http_pool_cert.pem")),
          keyfile: String.to_charlist(Path.join(fixture, "http_pool_key.pem")),
          mode: :binary,
          active: false,
          reuseaddr: true,
          ip: {127, 0, 0, 1}
        )

      {:ssl, socket}
    end

    defp sockname(:gen_tcp, socket), do: :inet.sockname(socket)
    defp sockname(:ssl, socket), do: :ssl.sockname(socket)

    defp accept(module, listen, owner, respond) do
      case accept_socket(module, listen) do
        {:ok, socket} ->
          worker =
            spawn_link(fn ->
              receive do
                :start -> serve(module, socket, owner, respond, 0)
              end
            end)

          :ok = module.controlling_process(socket, worker)
          send(owner, {:accepted, worker})
          send(worker, :start)
          accept(module, listen, owner, respond)

        {:error, :closed} ->
          :ok
      end
    end

    defp accept_socket(:gen_tcp, listen), do: :gen_tcp.accept(listen)

    defp accept_socket(:ssl, listen) do
      with {:ok, socket} <- :ssl.transport_accept(listen), do: :ssl.handshake(socket)
    end

    defp serve(module, socket, owner, respond, count) do
      case read_request(module, socket) do
        {:ok, headers, message} ->
          send(owner, {:request, self(), message})
          {response_headers, body} = respond.(headers, message, count + 1)
          close? = Enum.any?(response_headers, &(&1 == {"connection", "close"}))

          head = [
            "HTTP/1.1 200 OK\r\n",
            "content-length: ",
            Integer.to_string(byte_size(body)),
            "\r\n",
            Enum.map(response_headers, fn {name, value} -> [name, ": ", value, "\r\n"] end),
            "\r\n"
          ]

          case module.send(socket, [head, body]) do
            :ok when close? -> module.close(socket)
            :ok -> serve(module, socket, owner, respond, count + 1)
            {:error, _reason} -> module.close(socket)
          end

        {:error, _reason} ->
          send(owner, {:closed, self()})
          module.close(socket)
      end
    end

    defp read_request(module, socket) do
      :ok = setopts(module, socket, packet: :http_bin)

      with {:ok, {:http_request, _method, _path, _version}} <- module.recv(socket, 0, 5_000),
           {:ok, headers} <- read_headers(module, socket, %{}),
           :ok <- setopts(module, socket, packet: :raw),
           {:ok, body} <- module.recv(socket, String.to_integer(headers["content-length"]), 5_000) do
        {:ok, headers, JSON.decode!(body)}
      end
    end

    defp setopts(:gen_tcp, socket, options), do: :inet.setopts(socket, options)
    defp setopts(:ssl, socket, options), do: :ssl.setopts(socket, options)

    defp read_headers(module, socket, headers) do
      case module.recv(socket, 0, 5_000) do
        {:ok, {:http_header, _index, name, _reserved, value}} ->
          read_headers(module, socket, Map.put(headers, String.downcase(to_string(name)), value))

        {:ok, :http_eoh} ->
          {:ok, headers}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp serve(respond, scheme \\ :http) do
    {url, {module, listen}} = KeepAliveServer.start(self(), respond, scheme)
    on_exit(fn -> module.close(listen) end)
    url
  end

  defp reply(message, result \\ %{}) do
    body = JSON.encode!(%{"jsonrpc" => "2.0", "id" => message["id"], "result" => result})
    {[{"content-type", "application/json"}], body}
  end

  defp request(state, id, timeout \\ 1_000) do
    message = %{"jsonrpc" => "2.0", "id" => id, "method" => "ping"}
    HTTP.request(state, message, dialect: V2026_07_28, timeout: timeout)
  end

  test "reuses a framed response on the same HTTP connection" do
    url = serve(fn _headers, message, _count -> reply(message) end)
    {:ok, state} = HTTP.connect(url, pool_size: 2)

    assert {:ok, %{"id" => 1}} = request(state, 1)
    assert_receive {:accepted, connection}, 1_000
    assert_receive {:request, ^connection, %{"id" => 1}}, 1_000

    assert {:ok, %{"id" => 2}} = request(state, 2)
    assert_receive {:request, ^connection, %{"id" => 2}}, 1_000
    refute_receive {:accepted, _another}, 50

    assert :ok = HTTP.close(state)
    assert_receive {:closed, ^connection}, 1_000
  end

  test "closes a transferred socket when its owner dies before check-in completes" do
    url = serve(fn _headers, message, _count -> reply(message) end)
    port = URI.parse(url).port
    key = {:http, "127.0.0.1", port, make_ref()}
    parent = self()

    owner =
      spawn(fn ->
        {:open, lease} = Pool.checkout(key, {1, 1_000, 10}, 1_000)
        {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false])
        :ok = GenServer.call(Pool, {:prepare_checkin, lease, {:gen_tcp, socket}})
        :ok = :gen_tcp.controlling_process(socket, Process.whereis(Pool))
        send(parent, :socket_transferred)

        receive do
          :complete -> :ok
        end
      end)

    monitor = Process.monitor(owner)
    assert_receive {:accepted, worker}, 1_000
    assert_receive :socket_transferred, 1_000
    Process.exit(owner, :kill)

    assert_receive {:DOWN, ^monitor, :process, ^owner, :killed}, 1_000
    assert_receive {:closed, ^worker}, 1_000
    refute Map.has_key?(:sys.get_state(Pool).buckets, key)
  end

  test "reuses the TLS session and socket for a second request" do
    url = serve(fn _headers, message, _count -> reply(message) end, :https)
    {:ok, state} = HTTP.connect(url, ssl: [verify: :verify_none])

    assert {:ok, %{"id" => 1}} = request(state, 1)
    assert_receive {:accepted, connection}, 1_000
    assert_receive {:request, ^connection, %{"id" => 1}}, 1_000

    assert {:ok, %{"id" => 2}} = request(state, 2)
    assert_receive {:request, ^connection, %{"id" => 2}}, 1_000
    refute_receive {:accepted, _another}, 50

    :ok = HTTP.close(state)
  end

  test "honors server-directed close and maximum requests per connection" do
    for {options, respond} <- [
          {[],
           fn _headers, message, _count ->
             {headers, body} = reply(message)
             {[{"connection", "close"} | headers], body}
           end},
          {[pool_max_requests: 1], fn _headers, message, _count -> reply(message) end}
        ] do
      url = serve(respond)
      {:ok, state} = HTTP.connect(url, options)

      assert {:ok, %{"id" => 1}} = request(state, 1)
      assert_receive {:accepted, first}, 1_000
      assert_receive {:request, ^first, %{"id" => 1}}, 1_000

      assert {:ok, %{"id" => 2}} = request(state, 2)
      assert_receive {:accepted, second}, 1_000
      assert second != first
      assert_receive {:request, ^second, %{"id" => 2}}, 1_000
      :ok = HTTP.close(state)
    end
  end

  test "expires idle connections" do
    url = serve(fn _headers, message, _count -> reply(message) end)
    {:ok, state} = HTTP.connect(url, pool_idle_timeout: 30)

    assert {:ok, %{"id" => 1}} = request(state, 1)
    assert_receive {:accepted, first}, 1_000
    assert_receive {:closed, ^first}, 1_000

    assert {:ok, %{"id" => 2}} = request(state, 2)
    assert_receive {:accepted, second}, 1_000
    assert second != first
    :ok = HTTP.close(state)
  end

  test "keeps SSE responses out of the reusable pool" do
    url =
      serve(fn _headers, message, _count ->
        body =
          "data: #{JSON.encode!(%{"jsonrpc" => "2.0", "id" => message["id"], "result" => %{}})}\n\n"

        {[{"content-type", "text/event-stream"}], body}
      end)

    {:ok, state} = HTTP.connect(url, [])
    assert {:ok, %{"id" => 1}} = request(state, 1)
    assert_receive {:accepted, first}, 1_000
    assert_receive {:closed, ^first}, 1_000

    assert {:ok, %{"id" => 2}} = request(state, 2)
    assert_receive {:accepted, second}, 1_000
    assert second != first
    :ok = HTTP.close(state)
  end

  test "an SSE callback can send another request when the pool size is one" do
    url =
      serve(fn _headers, message, _count ->
        if message["id"] == 1 do
          progress = %{
            "jsonrpc" => "2.0",
            "method" => "notifications/progress",
            "params" => %{"progressToken" => "nested", "progress" => 1}
          }

          response = %{"jsonrpc" => "2.0", "id" => 1, "result" => %{}}
          body = "data: #{JSON.encode!(progress)}\n\ndata: #{JSON.encode!(response)}\n\n"
          {[{"content-type", "text/event-stream"}], body}
        else
          reply(message)
        end
      end)

    {:ok, state} = HTTP.connect(url, pool_size: 1)

    message = %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "ping",
      "params" => %{"_meta" => %{"progressToken" => "nested"}}
    }

    assert {:ok, %{"id" => 1}} =
             HTTP.request(state, message,
               dialect: V2026_07_28,
               timeout: 1_000,
               on_progress: fn _progress ->
                 assert {:ok, %{"id" => 2}} = request(state, 2)
               end
             )

    assert_receive {:accepted, first}, 1_000
    assert_receive {:accepted, second}, 1_000
    assert first != second
    :ok = HTTP.close(state)
  end

  test "bounds concurrent connections while requests are in flight" do
    parent = self()

    url =
      serve(fn _headers, message, _count ->
        if message["id"] in [1, 2] do
          send(parent, {:held, self()})

          receive do
            :release -> reply(message)
          end
        else
          reply(message)
        end
      end)

    {:ok, state} = HTTP.connect(url, pool_size: 2)
    first = Task.async(fn -> request(state, 1, 2_000) end)
    second = Task.async(fn -> request(state, 2, 2_000) end)
    assert_receive {:held, worker_one}, 1_000
    assert_receive {:held, worker_two}, 1_000
    assert_receive {:accepted, _first_connection}, 1_000
    assert_receive {:accepted, _second_connection}, 1_000

    assert {:error, %Snodo.Error{code: -32_001}} = request(state, 3, 100)
    refute_receive {:accepted, _third_connection}, 50

    send(worker_one, :release)
    send(worker_two, :release)
    assert {:ok, _response} = Task.await(first, 2_000)
    assert {:ok, _response} = Task.await(second, 2_000)
    assert {:ok, %{"id" => 4}} = request(state, 4)
    :ok = HTTP.close(state)
  end

  test "closing a client retires its active connection after the request finishes" do
    parent = self()

    url =
      serve(fn _headers, message, _count ->
        send(parent, {:held, self()})

        receive do
          :release -> reply(message)
        end
      end)

    {:ok, state} = HTTP.connect(url, pool_size: 1)
    task = Task.async(fn -> request(state, 1) end)
    assert_receive {:held, worker}, 1_000

    assert :ok = HTTP.close(state)
    send(worker, :release)
    assert {:ok, %{"id" => 1}} = Task.await(task, 2_000)
    assert_receive {:closed, ^worker}, 1_000
    refute Map.has_key?(:sys.get_state(Snodo.Client.HTTP.Pool).buckets, state.pool_key)
  end

  test "response size limits still apply on reused connections" do
    url =
      serve(fn _headers, message, count ->
        if count == 2,
          do: reply(message, %{"large" => String.duplicate("x", 1_000)}),
          else: reply(message)
      end)

    {:ok, state} = HTTP.connect(url, max_response_bytes: 512)
    assert {:ok, %{"id" => 1}} = request(state, 1)
    assert_receive {:accepted, first}, 1_000

    assert {:error, %Snodo.Error{cause: {:max_response_bytes, 512}}} = request(state, 2)
    assert_receive {:request, ^first, %{"id" => 2}}, 1_000

    assert {:ok, %{"id" => 3}} = request(state, 3)
    assert_receive {:accepted, second}, 1_000
    assert second != first
    :ok = HTTP.close(state)
  end

  test "rejects invalid pool limits" do
    url = serve(fn _headers, message, _count -> reply(message) end)

    for option <- [:pool_size, :pool_idle_timeout, :pool_max_requests] do
      assert_raise ArgumentError, fn -> HTTP.connect(url, [{option, 0}]) end
    end
  end
end
