defmodule Snodo.ClientTokenProviderTest do
  use ExUnit.Case, async: true

  alias Snodo.Client
  alias Snodo.Client.Challenge
  alias Snodo.Client.Subscription
  alias Snodo.Error

  @metadata "http://127.0.0.1/.well-known/oauth-protected-resource/mcp"
  @unauthorized_body ~s({"error":"invalid_token"})

  defmodule Provider do
    @moduledoc false
    # A scripted Snodo.Client.TokenProvider: `token/2` returns what the
    # agent holds under :token, `refresh/3` returns :refresh and, when that is
    # a token, makes it the current one. Every call is reported to the owner.
    @behaviour Snodo.Client.TokenProvider

    def start(owner, token, refresh) do
      {:ok, agent} = Agent.start_link(fn -> %{owner: owner, token: token, refresh: refresh} end)
      {__MODULE__, agent}
    end

    @impl true
    def token(agent, context) do
      %{owner: owner, token: token} = Agent.get(agent, & &1)
      send(owner, {:provider, :token, context})
      token
    end

    @impl true
    def refresh(agent, challenge, context) do
      %{owner: owner, refresh: refresh} = Agent.get(agent, & &1)
      send(owner, {:provider, :refresh, challenge, context})

      case refresh do
        {:ok, token} = result when is_binary(token) ->
          Agent.update(agent, &%{&1 | token: result})
          result

        other ->
          other
      end
    end
  end

  defmodule FakeHTTP do
    @moduledoc false
    # Answers each request with `respond.(headers, message)`, a
    # `{status, headers, body}` triple, and reports the request to `owner`.

    def start(owner, respond) do
      {:ok, listen} =
        :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

      {:ok, port} = :inet.port(listen)
      pid = spawn_link(fn -> accept(listen, owner, respond) end)
      :ok = :gen_tcp.controlling_process(listen, pid)
      "http://127.0.0.1:#{port}/mcp"
    end

    defp accept(listen, owner, respond) do
      {:ok, socket} = :gen_tcp.accept(listen)
      :ok = :inet.setopts(socket, packet: :http_bin, send_timeout: 5_000)
      headers = read_headers(socket, %{})
      :ok = :inet.setopts(socket, packet: :raw)
      {:ok, body} = :gen_tcp.recv(socket, String.to_integer(headers["content-length"]))
      message = JSON.decode!(body)
      send(owner, {:fake_http, headers, message})
      {status, response_headers, response_body} = respond.(headers, message)
      length = {"content-length", Integer.to_string(byte_size(response_body))}

      :ok =
        :gen_tcp.send(socket, [
          "HTTP/1.1 #{status} Fake\r\n",
          Enum.map([length | response_headers], fn {name, value} ->
            [name, ": ", value, "\r\n"]
          end),
          "connection: close\r\n\r\n",
          response_body
        ])

      :ok = :gen_tcp.close(socket)
      accept(listen, owner, respond)
    end

    defp read_headers(socket, headers) do
      case :gen_tcp.recv(socket, 0, 5_000) do
        {:ok, {:http_request, _method, _uri, _version}} ->
          read_headers(socket, headers)

        {:ok, {:http_header, _field, name, _reserved, value}} ->
          read_headers(socket, Map.put(headers, String.downcase(to_string(name)), value))

        {:ok, :http_eoh} ->
          headers
      end
    end
  end

  defp ok(message) do
    body =
      JSON.encode!(%{"jsonrpc" => "2.0", "id" => message["id"], "result" => %{"tools" => []}})

    {200, [{"content-type", "application/json"}], body}
  end

  # An event stream that acknowledges a subscriptions/listen request and ends.
  defp acknowledge do
    event = %{
      "jsonrpc" => "2.0",
      "method" => "notifications/subscriptions/acknowledged",
      "params" => %{"notifications" => %{"toolsListChanged" => true}}
    }

    {200, [{"content-type", "text/event-stream"}],
     "event: message\ndata: " <> JSON.encode!(event) <> "\n\n"}
  end

  defp unauthorized(challenge), do: {401, [{"www-authenticate", challenge}], @unauthorized_body}

  # Accepts the request when it carries `token`, else answers `refusal`.
  defp require_token(token, refusal) do
    fn headers, message ->
      if headers["authorization"] == "Bearer " <> token, do: ok(message), else: refusal
    end
  end

  defp connect(url, provider), do: Client.connect({:http, url}, token_provider: provider)

  test "a request without a token carries no authorization header" do
    url = FakeHTTP.start(self(), fn _headers, message -> ok(message) end)
    {:ok, client} = connect(url, Provider.start(self(), {:ok, nil}, {:ok, "unused"}))

    assert {:ok, []} = Client.list_tools(client)
    assert_receive {:provider, :token, %{url: ^url}}, 1_000
    assert_receive {:fake_http, headers, _message}, 1_000
    refute Map.has_key?(headers, "authorization")
    refute_received {:provider, :refresh, _challenge, _context}
  end

  test "the provider's token is sent as a bearer token" do
    url = FakeHTTP.start(self(), require_token("t1", unauthorized("Bearer")))
    {:ok, client} = connect(url, Provider.start(self(), {:ok, "t1"}, {:ok, "unused"}))

    assert {:ok, []} = Client.list_tools(client)
    assert_receive {:fake_http, %{"authorization" => "Bearer t1"}, _message}, 1_000
    refute_received {:provider, :refresh, _challenge, _context}
  end

  test "a 401 asks the provider to refresh with the challenge and retries once" do
    challenge = ~s(Bearer resource_metadata="#{@metadata}", scope="mcp:read")
    url = FakeHTTP.start(self(), require_token("t2", unauthorized(challenge)))
    {:ok, client} = connect(url, Provider.start(self(), {:ok, "t1"}, {:ok, "t2"}))

    assert {:ok, []} = Client.list_tools(client)

    assert_receive {:provider, :refresh,
                    %Challenge{resource_metadata: @metadata, scope: ["mcp:read"]},
                    %{url: ^url, status: 401, token: "t1"}},
                   1_000

    assert_receive {:fake_http, %{"authorization" => "Bearer t1"}, _first}, 1_000
    assert_receive {:fake_http, %{"authorization" => "Bearer t2"}, _second}, 1_000
  end

  test "a 401 without a token or a challenge refreshes with nil" do
    url = FakeHTTP.start(self(), require_token("t2", {401, [], @unauthorized_body}))
    {:ok, client} = connect(url, Provider.start(self(), {:ok, nil}, {:ok, "t2"}))

    assert {:ok, []} = Client.list_tools(client)
    assert_receive {:provider, :refresh, nil, %{status: 401, token: nil}}, 1_000
  end

  test "a 403 insufficient_scope challenge is a step-up" do
    challenge = ~s(Bearer error="insufficient_scope", scope="mcp:write")

    url =
      FakeHTTP.start(self(), require_token("t2", {403, [{"www-authenticate", challenge}], "{}"}))

    {:ok, client} = connect(url, Provider.start(self(), {:ok, "t1"}, {:ok, "t2"}))

    assert {:ok, []} = Client.list_tools(client)

    assert_receive {:provider, :refresh,
                    %Challenge{error: "insufficient_scope", scope: ["mcp:write"]},
                    %{status: 403, token: "t1"}},
                   1_000
  end

  test "a 403 with another challenge is returned as it is" do
    challenge = ~s(Bearer error="invalid_token")

    url =
      FakeHTTP.start(self(), fn _headers, _message ->
        {403, [{"www-authenticate", challenge}], "no"}
      end)

    {:ok, client} = connect(url, Provider.start(self(), {:ok, "t1"}, {:ok, "t2"}))

    assert {:error, %Error{code: -32_000, kind: :transport, cause: {:http_status, 403, "no"}}} =
             Client.list_tools(client)

    refute_received {:provider, :refresh, _challenge, _context}
  end

  test "a second refusal is an authorization error that names no token" do
    challenge = ~s(Bearer error="invalid_token", resource_metadata="#{@metadata}")
    url = FakeHTTP.start(self(), fn _headers, _message -> unauthorized(challenge) end)
    {:ok, client} = connect(url, Provider.start(self(), {:ok, "secret-one"}, {:ok, "secret-two"}))

    assert {:error, %Error{code: -32_000, kind: :transport} = error} = Client.list_tools(client)
    assert {:unauthorized, 401, %Challenge{error: "invalid_token"}} = error.cause
    assert error.message =~ "HTTP 401"
    refute inspect(error) =~ "secret"

    assert_receive {:fake_http, %{"authorization" => "Bearer secret-one"}, _first}, 1_000
    assert_receive {:fake_http, %{"authorization" => "Bearer secret-two"}, _second}, 1_000
    refute_received {:fake_http, _headers, _third}
  end

  test "a listen stream carries the token and is opened once more after a 401" do
    challenge = ~s(Bearer resource_metadata="#{@metadata}")

    url =
      FakeHTTP.start(self(), fn headers, _message ->
        if headers["authorization"] == "Bearer t2",
          do: acknowledge(),
          else: unauthorized(challenge)
      end)

    {:ok, client} = connect(url, Provider.start(self(), {:ok, "t1"}, {:ok, "t2"}))

    assert {:ok, %Subscription{accepted: %{"toolsListChanged" => true}}} =
             Client.listen(client, %{"toolsListChanged" => true})

    assert_receive {:provider, :token, %{url: ^url}}, 1_000

    assert_receive {:provider, :refresh, %Challenge{resource_metadata: @metadata},
                    %{url: ^url, status: 401, token: "t1"}},
                   1_000

    assert_receive {:fake_http, %{"authorization" => "Bearer t1"},
                    %{"method" => "subscriptions/listen"}},
                   1_000

    assert_receive {:fake_http, %{"authorization" => "Bearer t2"},
                    %{"method" => "subscriptions/listen"}},
                   1_000
  end

  test "a listen stream refused twice is an authorization error" do
    challenge = ~s(Bearer error="insufficient_scope", scope="mcp:write")

    url =
      FakeHTTP.start(self(), fn _headers, _message ->
        {403, [{"www-authenticate", challenge}], "{}"}
      end)

    {:ok, client} = connect(url, Provider.start(self(), {:ok, "secret-one"}, {:ok, "secret-two"}))

    assert {:error, %Error{code: -32_000, kind: :transport} = error} =
             Client.listen(client, %{"toolsListChanged" => true})

    assert {:unauthorized, 403, %Challenge{error: "insufficient_scope"}} = error.cause
    refute inspect(error) =~ "secret"

    assert_receive {:provider, :refresh, %Challenge{scope: ["mcp:write"]},
                    %{status: 403, token: "secret-one"}},
                   1_000

    assert_receive {:fake_http, %{"authorization" => "Bearer secret-one"}, _first}, 1_000
    assert_receive {:fake_http, %{"authorization" => "Bearer secret-two"}, _second}, 1_000
    refute_received {:fake_http, _headers, _third}
  end

  test "a challenge of another scheme reaches the provider" do
    challenge = ~s(DPoP resource_metadata="#{@metadata}")
    url = FakeHTTP.start(self(), fn _headers, _message -> unauthorized(challenge) end)

    refusal = Error.internal("DPoP is not supported")
    {:ok, client} = connect(url, Provider.start(self(), {:ok, nil}, {:error, refusal}))

    assert {:error, ^refusal} = Client.list_tools(client)
    assert_receive {:provider, :refresh, %Challenge{scheme: "dpop"}, %{status: 401}}, 1_000
  end

  test "a provider error from token/2 fails the request before it is sent" do
    url = FakeHTTP.start(self(), fn _headers, message -> ok(message) end)
    refusal = %Error{code: -32_000, message: "no token", kind: :transport}
    {:ok, client} = connect(url, Provider.start(self(), {:error, refusal}, {:ok, "t2"}))

    assert {:error, ^refusal} = Client.list_tools(client)
    refute_received {:fake_http, _headers, _message}
  end

  test "an invalid token is refused without being repeated" do
    url = FakeHTTP.start(self(), fn _headers, message -> ok(message) end)

    {:ok, client} =
      connect(url, Provider.start(self(), {:ok, "bad\r\nx-injected: 1"}, {:ok, "t2"}))

    assert {:error, %Error{code: -32_000, cause: :invalid_token} = error} =
             Client.list_tools(client)

    refute inspect(error) =~ "injected"
    refute_received {:fake_http, _headers, _message}

    {:ok, client} = connect(url, Provider.start(self(), {:ok, ""}, {:ok, "t2"}))
    assert {:error, %Error{cause: :invalid_token}} = Client.list_tools(client)
  end

  test "a provider that returns something else raises" do
    url = FakeHTTP.start(self(), fn _headers, _message -> unauthorized("Bearer") end)

    {:ok, client} = connect(url, Provider.start(self(), :nope, {:ok, "t2"}))
    assert_raise ArgumentError, ~r/token\/2 must return/, fn -> Client.list_tools(client) end

    {:ok, client} = connect(url, Provider.start(self(), {:ok, nil}, {:ok, nil}))
    assert_raise ArgumentError, ~r/refresh\/3 must return/, fn -> Client.list_tools(client) end
  end

  test "without a provider a 401 is an unexpected status" do
    url = FakeHTTP.start(self(), fn _headers, _message -> unauthorized("Bearer") end)
    {:ok, client} = Client.connect({:http, url})

    assert {:error, %Error{cause: {:http_status, 401, @unauthorized_body}}} =
             Client.list_tools(client)
  end

  test "connect/2 checks the provider and the headers" do
    assert_raise ArgumentError, ~r/:token_provider must be/, fn ->
      Client.connect({:http, "http://127.0.0.1:1/mcp"}, token_provider: {Enum, nil})
    end

    assert_raise ArgumentError, ~r/:token_provider must be/, fn ->
      Client.connect({:http, "http://127.0.0.1:1/mcp"}, token_provider: :static)
    end

    assert_raise ArgumentError, ~r/cannot set authorization/, fn ->
      Client.connect({:http, "http://127.0.0.1:1/mcp"},
        token_provider: Provider.start(self(), {:ok, nil}, {:ok, "t"}),
        headers: [{"Authorization", "Bearer x"}]
      )
    end
  end
end
