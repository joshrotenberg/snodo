defmodule SnodoTest.FakeOAuth do
  @moduledoc false
  # An authorization server and a resource server on loopback Bandit
  # listeners, shaped like the official conformance runner's scenario
  # servers. One agent, the world, holds the configuration, the tokens the
  # authorization server issued, and every request either server saw.
  #
  # Options (all optional):
  #   metadata_path, route_prefix, issuer, scopes_supported,
  #   grant_types_supported, token_endpoint_auth_methods_supported,
  #   client_id_metadata_document_supported, registration (false disables),
  #   iss_parameter_supported (true, false, or nil to omit),
  #   iss_in_redirect (:correct, :wrong, :omit, :normalized), deny,
  #   refresh_tokens, expires_in, on_register (body -> map),
  #   on_token (body, headers, world -> {:ok, map} | {:error, status, map}),
  #   prm_path (nil disables), prm_resource, prm_scopes_supported,
  #   authorization_servers (world -> list), required_scopes,
  #   include_prm_in_www_auth, include_scope_in_www_auth,
  #   auth (conn, message, world -> :ok | {:refuse, status, challenge, body}).

  alias Plug.Conn

  @doc "Starts the world and both listeners under the test supervisor."
  def start(opts \\ []) do
    config = Map.new(opts)

    world =
      ExUnit.Callbacks.start_supervised!(
        {Agent, fn -> %{config: config, events: [], tokens: %{}, as_url: nil, rs_url: nil} end},
        id: make_ref()
      )

    as_url = listen(__MODULE__.AS, world)
    rs_url = listen(__MODULE__.RS, world)
    Agent.update(world, &%{&1 | as_url: as_url, rs_url: rs_url})

    %{
      world: world,
      as_url: as_url,
      rs_url: rs_url,
      mcp_url: rs_url <> "/mcp",
      issuer: issuer(world)
    }
  end

  defp listen(plug, world) do
    listener =
      ExUnit.Callbacks.start_supervised!(
        {Bandit,
         plug: {plug, world: world},
         scheme: :http,
         ip: {127, 0, 0, 1},
         port: 0,
         startup_log: false},
        id: make_ref()
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(listener)
    "http://127.0.0.1:#{port}"
  end

  def config(world), do: Agent.get(world, & &1.config)
  def config(world, key, default \\ nil), do: Map.get(config(world), key, default)
  def as_url(world), do: Agent.get(world, & &1.as_url)
  def rs_url(world), do: Agent.get(world, & &1.rs_url)
  def record(world, event), do: Agent.update(world, &%{&1 | events: &1.events ++ [event]})
  def events(world), do: Agent.get(world, & &1.events)
  def events(world, tag), do: for({^tag, detail} <- events(world), do: detail)

  def put_config(world, key, value),
    do: Agent.update(world, &%{&1 | config: Map.put(&1.config, key, value)})

  def register_token(world, token, scopes),
    do: Agent.update(world, &%{&1 | tokens: Map.put(&1.tokens, token, scopes)})

  def token_scopes(world, token), do: Agent.get(world, &Map.fetch(&1.tokens, token))

  def issuer(world) do
    case config(world, :issuer) do
      nil -> as_url(world) <> config(world, :route_prefix, "")
      issuer -> issuer
    end
  end

  def json(conn, status, body) do
    conn
    |> Conn.put_resp_content_type("application/json")
    |> Conn.send_resp(status, JSON.encode!(body))
  end

  def parse(conn) do
    Plug.Parsers.call(
      conn,
      Plug.Parsers.init(parsers: [:urlencoded, :json], json_decoder: JSON, pass: ["*/*"])
    )
  end

  # Follows the authorization redirect as a browser would, which lands it
  # on the loopback listener.
  def follow(url) do
    request = {String.to_charlist(url), []}

    case :httpc.request(:get, request, [autoredirect: true, timeout: 5_000], body_format: :binary) do
      {:ok, {{_version, 200, _reason}, _headers, _body}} -> :ok
      other -> {:error, other}
    end
  end

  @doc "Fetches the authorization URL without following, and returns the redirect target."
  def location(url) do
    request = {String.to_charlist(url), []}

    case :httpc.request(:get, request, [autoredirect: false, timeout: 5_000],
           body_format: :binary
         ) do
      {:ok, {{_version, 302, _reason}, headers, _body}} ->
        {_name, location} = List.keyfind(headers, ~c"location", 0)
        {:ok, List.to_string(location)}

      other ->
        {:error, other}
    end
  end

  defmodule AS do
    @moduledoc false
    @behaviour Plug

    alias SnodoTest.FakeOAuth, as: World

    @impl true
    def init(opts), do: Map.new(opts)

    @impl true
    def call(conn, %{world: world}) do
      conn = conn |> Conn.fetch_query_params() |> World.parse()
      prefix = World.config(world, :route_prefix, "")

      metadata_path =
        World.config(world, :metadata_path, "/.well-known/oauth-authorization-server")

      case {conn.method, conn.request_path} do
        {"GET", ^metadata_path} ->
          World.record(world, {:as_metadata, conn.request_path})
          World.json(conn, 200, metadata(world, prefix))

        {"GET", path} when path == prefix <> "/authorize" ->
          authorize(conn, world)

        {"POST", path} when path == prefix <> "/token" ->
          token(conn, world)

        {"POST", path} when path == prefix <> "/register" ->
          register(conn, world)

        {method, path} ->
          World.record(world, {:as_other, {method, path}})
          World.json(conn, 404, %{"error" => "not_found"})
      end
    end

    defp metadata(world, prefix) do
      config = World.config(world)
      base = World.as_url(world) <> prefix

      %{
        "issuer" => World.issuer(world),
        "authorization_endpoint" => base <> "/authorize",
        "token_endpoint" => base <> "/token",
        "response_types_supported" => ["code"],
        "grant_types_supported" =>
          Map.get(config, :grant_types_supported, ["authorization_code", "refresh_token"]),
        "token_endpoint_auth_methods_supported" =>
          Map.get(config, :token_endpoint_auth_methods_supported, ["none"])
      }
      |> put_if(
        Map.get(config, :code_challenge_methods_supported, ["S256"]) != nil,
        "code_challenge_methods_supported",
        Map.get(config, :code_challenge_methods_supported, ["S256"])
      )
      |> put_if(
        Map.get(config, :registration, true),
        "registration_endpoint",
        base <> "/register"
      )
      |> put_if(
        Map.get(config, :iss_parameter_supported, true) != nil,
        "authorization_response_iss_parameter_supported",
        Map.get(config, :iss_parameter_supported, true)
      )
      |> put_if(config[:scopes_supported] != nil, "scopes_supported", config[:scopes_supported])
      |> put_if(
        config[:client_id_metadata_document_supported] != nil,
        "client_id_metadata_document_supported",
        config[:client_id_metadata_document_supported]
      )
      |> Map.merge(Map.get(config, :extra_metadata, %{}))
    end

    defp put_if(map, true, key, value), do: Map.put(map, key, value)
    defp put_if(map, _condition, _key, _value), do: map

    defp authorize(conn, world) do
      query = conn.query_params
      World.record(world, {:authorize, query})
      Agent.update(world, &Map.put(&1, :challenge, query["code_challenge"]))
      Agent.update(world, &Map.put(&1, :requested_scopes, scopes(query["scope"])))

      location = URI.parse(query["redirect_uri"])

      params =
        if World.config(world, :deny),
          do: [{"error", "access_denied"}, {"error_description", "denied"}],
          else: [{"code", "test-auth-code"}]

      params = if query["state"], do: params ++ [{"state", query["state"]}], else: params

      params =
        case World.config(world, :iss_in_redirect, :correct) do
          :correct -> params ++ [{"iss", World.issuer(world)}]
          :wrong -> params ++ [{"iss", "https://evil.example.com"}]
          :normalized -> params ++ [{"iss", World.issuer(world) <> "/"}]
          :omit -> params
        end

      existing = if location.query, do: URI.decode_query(location.query), else: %{}
      query_string = URI.encode_query(Map.to_list(existing) ++ params)

      conn
      |> Conn.put_resp_header("location", URI.to_string(%{location | query: query_string}))
      |> Conn.send_resp(302, "")
    end

    defp token(conn, world) do
      body = conn.body_params
      authorization = conn |> Conn.get_req_header("authorization") |> List.first()
      World.record(world, {:token, %{body: body, authorization: authorization}})

      case World.config(world, :on_token) do
        nil -> default_token(conn, world, body)
        on_token -> custom_token(conn, world, on_token.(body, authorization, world))
      end
    end

    defp default_token(conn, world, %{"grant_type" => "authorization_code"} = body) do
      challenge = Agent.get(world, &Map.get(&1, :challenge))
      verifier = body["code_verifier"]

      verified =
        is_binary(verifier) and challenge == Snodo.OAuth.Client.PKCE.challenge(verifier)

      World.record(world, {:pkce, verified})

      if verified and body["code"] == "test-auth-code" do
        issue(conn, world, Agent.get(world, &Map.get(&1, :requested_scopes, [])))
      else
        World.json(conn, 400, %{"error" => "invalid_grant"})
      end
    end

    defp default_token(conn, world, %{"grant_type" => "refresh_token"} = body) do
      case World.token_scopes(world, "refresh-of-" <> (body["refresh_token"] || "")) do
        {:ok, scopes} -> issue(conn, world, scopes)
        :error -> World.json(conn, 400, %{"error" => "invalid_grant"})
      end
    end

    defp default_token(conn, world, %{"grant_type" => "client_credentials"} = body),
      do: issue(conn, world, scopes(body["scope"]))

    defp default_token(conn, _world, _body),
      do: World.json(conn, 400, %{"error" => "unsupported_grant_type"})

    defp custom_token(conn, world, {:ok, %{} = response}) do
      World.register_token(world, response["access_token"], scopes(response["scope"]))
      World.json(conn, 200, response)
    end

    defp custom_token(conn, _world, {:error, status, body}), do: World.json(conn, status, body)

    defp issue(conn, world, scopes) do
      token = "tok-" <> Integer.to_string(System.unique_integer([:positive]))
      World.register_token(world, token, scopes)

      response = %{
        "access_token" => token,
        "token_type" => "Bearer",
        "expires_in" => World.config(world, :expires_in, 3600)
      }

      response =
        if scopes == [], do: response, else: Map.put(response, "scope", Enum.join(scopes, " "))

      response =
        if World.config(world, :refresh_tokens) do
          refresh = "refresh-" <> token
          World.register_token(world, "refresh-of-" <> refresh, scopes)
          Map.put(response, "refresh_token", refresh)
        else
          response
        end

      World.json(conn, 200, response)
    end

    defp register(conn, world) do
      body = conn.body_params
      World.record(world, {:register, body})

      response =
        case World.config(world, :on_register) do
          nil -> %{"client_id" => "test-client-id", "client_secret" => "test-client-secret"}
          on_register -> on_register.(body)
        end

      response =
        Map.merge(
          %{
            "client_name" => body["client_name"],
            "redirect_uris" => body["redirect_uris"] || []
          },
          response
        )

      World.json(conn, 201, response)
    end

    defp scopes(nil), do: []
    defp scopes(scope), do: String.split(scope, " ", trim: true)
  end

  defmodule RS do
    @moduledoc false
    @behaviour Plug

    alias SnodoTest.FakeOAuth, as: World

    @impl true
    def init(opts), do: Map.new(opts)

    @impl true
    def call(conn, %{world: world}) do
      prm_path = World.config(world, :prm_path, "/.well-known/oauth-protected-resource/mcp")

      case {conn.method, conn.request_path} do
        {"GET", ^prm_path} when is_binary(prm_path) ->
          World.record(world, {:prm, conn.request_path})
          World.json(conn, 200, prm(world, prm_path))

        {"POST", "/mcp"} ->
          mcp(conn, world)

        {method, path} ->
          World.record(world, {:rs_other, {method, path}})
          World.json(conn, 404, %{"error" => "not_found"})
      end
    end

    defp prm(world, prm_path) do
      rs_url = World.rs_url(world)

      default =
        if prm_path == "/.well-known/oauth-protected-resource", do: rs_url, else: rs_url <> "/mcp"

      servers =
        case World.config(world, :authorization_servers) do
          nil -> [World.issuer(world)]
          fun -> fun.(world)
        end

      %{
        "resource" => World.config(world, :prm_resource, default),
        "authorization_servers" => servers
      }
      |> put_scopes(World.config(world, :prm_scopes_supported))
    end

    defp put_scopes(prm, nil), do: prm
    defp put_scopes(prm, scopes), do: Map.put(prm, "scopes_supported", scopes)

    defp mcp(conn, world) do
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      message = JSON.decode!(body)

      case authenticate(conn, message, world) do
        :ok ->
          World.record(world, {:mcp, %{method: message["method"], token: token(conn)}})

          World.json(conn, 200, %{
            "jsonrpc" => "2.0",
            "id" => message["id"],
            "result" => result(message)
          })

        {:refuse, status, challenge, response} ->
          World.record(world, {:refused, %{method: message["method"], status: status}})

          conn
          |> Conn.put_resp_header("www-authenticate", challenge)
          |> World.json(status, response)
      end
    end

    defp result(%{"method" => "tools/list"}),
      do: %{"tools" => [%{"name" => "test-tool", "inputSchema" => %{"type" => "object"}}]}

    defp result(%{"method" => "tools/call"}),
      do: %{"content" => [%{"type" => "text", "text" => "test"}]}

    defp result(%{"method" => "server/discover"}),
      do: %{"supportedVersions" => ["2026-07-28"], "capabilities" => %{"tools" => %{}}}

    defp result(_message), do: %{}

    def token(conn) do
      case Conn.get_req_header(conn, "authorization") do
        ["Bearer " <> token] -> token
        _other -> nil
      end
    end

    defp authenticate(conn, message, world) do
      case World.config(world, :auth) do
        nil -> default_auth(conn, message, world)
        auth -> auth.(conn, message, world)
      end
    end

    def default_auth(conn, _message, world) do
      required = World.config(world, :required_scopes, [])

      with token when is_binary(token) <- token(conn),
           {:ok, scopes} <- World.token_scopes(world, token),
           [] <- required -- scopes do
        :ok
      else
        nil ->
          {:refuse, 401, challenge(world, []), %{"error" => "invalid_token"}}

        :error ->
          {:refuse, 401, challenge(world, [{"error", "invalid_token"}]),
           %{"error" => "invalid_token"}}

        _missing ->
          params = [{"error", "insufficient_scope"}, {"scope", Enum.join(required, " ")}]
          {:refuse, 403, challenge(world, params), %{"error" => "insufficient_scope"}}
      end
    end

    def challenge(world, params) do
      required = World.config(world, :required_scopes, [])
      prm_path = World.config(world, :prm_path, "/.well-known/oauth-protected-resource/mcp")

      params =
        if World.config(world, :include_scope_in_www_auth, false) and required != [] and
             not List.keymember?(params, "scope", 0),
           do: params ++ [{"scope", Enum.join(required, " ")}],
           else: params

      params =
        if World.config(world, :include_prm_in_www_auth, true) and is_binary(prm_path),
          do: params ++ [{"resource_metadata", World.rs_url(world) <> prm_path}],
          else: params

      case params do
        [] -> "Bearer"
        params -> "Bearer " <> Enum.map_join(params, ", ", fn {k, v} -> ~s(#{k}="#{v}") end)
      end
    end
  end
end
