defmodule Snodo.OAuth.ClientTest do
  use ExUnit.Case, async: true

  alias Snodo.Client
  alias Snodo.Error
  alias Snodo.OAuth.Client, as: OAuth
  alias SnodoTest.FakeOAuth, as: Fake

  @cimd "https://client.example.test/metadata.json"

  defp start_oauth(fake, opts \\ []) do
    opts =
      Keyword.merge(
        [resource: fake.mcp_url, authorize: &Fake.follow/1, authorization_timeout: 5_000],
        opts
      )

    start_supervised!({OAuth, opts}, id: make_ref())
  end

  defp connect(fake, oauth) do
    {:ok, client} =
      Client.connect({:http, fake.mcp_url}, token_provider: {OAuth, oauth}, timeout: 5_000)

    client
  end

  defp list_tools(fake, opts \\ []) do
    oauth = start_oauth(fake, opts)
    {oauth, Client.list_tools(connect(fake, oauth))}
  end

  defp tokens(fake), do: for(%{token: token} <- Fake.events(fake.world, :mcp), do: token)

  describe "the authorization code flow" do
    test "authorizes with registration, PKCE, and the resource indicator" do
      fake = Fake.start()
      {oauth, result} = list_tools(fake)
      assert {:ok, [%{"name" => "test-tool"}]} = result

      redirect = OAuth.redirect_uri(oauth)
      assert redirect =~ ~r{^http://127\.0\.0\.1:\d+/callback$}

      assert [%{"client_name" => "snodo", "application_type" => "native"} = registration] =
               Fake.events(fake.world, :register)

      assert registration["redirect_uris"] == [redirect]
      assert registration["grant_types"] == ["authorization_code", "refresh_token"]
      assert registration["token_endpoint_auth_method"] == "none"

      assert [query] = Fake.events(fake.world, :authorize)
      assert query["response_type"] == "code"
      assert query["client_id"] == "test-client-id"
      assert query["redirect_uri"] == redirect
      assert query["code_challenge_method"] == "S256"
      assert byte_size(query["code_challenge"]) == 43
      assert byte_size(query["state"]) == 43
      assert query["resource"] == fake.mcp_url
      refute Map.has_key?(query, "scope")

      assert [true] = Fake.events(fake.world, :pkce)

      assert [%{body: body, authorization: nil}] = Fake.events(fake.world, :token)
      assert body["grant_type"] == "authorization_code"
      assert body["code"] == "test-auth-code"
      assert body["redirect_uri"] == redirect
      assert body["resource"] == fake.mcp_url
      assert body["client_id"] == "test-client-id"
      refute Map.has_key?(body, "client_secret")

      assert [%{status: 401}] = Fake.events(fake.world, :refused)
      assert [%{method: "tools/list", token: "tok-" <> _rest}] = Fake.events(fake.world, :mcp)

      # The metadata came from the challenge, so the root location was never tried.
      assert ["/.well-known/oauth-protected-resource/mcp"] = Fake.events(fake.world, :prm)
      assert ["/.well-known/oauth-authorization-server"] = Fake.events(fake.world, :as_metadata)
      assert Fake.events(fake.world, :rs_other) == []
      assert Fake.events(fake.world, :as_other) == []
    end

    test "reuses the token and the registration across requests" do
      fake = Fake.start()
      oauth = start_oauth(fake)
      client = connect(fake, oauth)

      assert {:ok, _tools} = Client.list_tools(client)
      assert {:ok, _result} = Client.call_tool(client, "test-tool", %{})
      assert {:ok, _tools} = Client.list_tools(connect(fake, oauth))

      assert [_one] = Fake.events(fake.world, :authorize)
      assert [_one] = Fake.events(fake.world, :register)
      assert [token, token, token] = tokens(fake)
    end

    test "finds the metadata at the well-known locations without a challenge URL" do
      fake =
        Fake.start(
          include_prm_in_www_auth: false,
          metadata_path: "/.well-known/openid-configuration"
        )

      assert {_oauth, {:ok, _tools}} = list_tools(fake)
      assert ["/.well-known/oauth-protected-resource/mcp"] = Fake.events(fake.world, :prm)

      assert [{"GET", "/.well-known/oauth-authorization-server"}] =
               Fake.events(fake.world, :as_other)

      assert ["/.well-known/openid-configuration"] = Fake.events(fake.world, :as_metadata)
    end

    test "inserts the well-known segment before an issuer path and never asks the root" do
      fake =
        Fake.start(
          include_prm_in_www_auth: false,
          prm_path: "/.well-known/oauth-protected-resource",
          route_prefix: "/tenant1",
          metadata_path: "/.well-known/oauth-authorization-server/tenant1"
        )

      assert fake.issuer == fake.as_url <> "/tenant1"
      assert {_oauth, {:ok, _tools}} = list_tools(fake)

      assert [{"GET", "/.well-known/oauth-protected-resource/mcp"}] =
               Fake.events(fake.world, :rs_other)

      assert ["/.well-known/oauth-protected-resource"] = Fake.events(fake.world, :prm)

      assert ["/.well-known/oauth-authorization-server/tenant1"] =
               Fake.events(fake.world, :as_metadata)

      assert Fake.events(fake.world, :as_other) == []

      assert [%{body: %{"resource" => resource}}] = Fake.events(fake.world, :token)
      assert resource == fake.rs_url
    end

    test "falls back to the OpenID configuration under the issuer path" do
      fake =
        Fake.start(
          prm_path: "/custom/metadata/location.json",
          route_prefix: "/tenant1",
          metadata_path: "/tenant1/.well-known/openid-configuration"
        )

      assert {_oauth, {:ok, _tools}} = list_tools(fake)
      assert ["/custom/metadata/location.json"] = Fake.events(fake.world, :prm)

      assert [
               {"GET", "/.well-known/oauth-authorization-server/tenant1"},
               {"GET", "/.well-known/openid-configuration/tenant1"}
             ] = Fake.events(fake.world, :as_other)

      assert ["/tenant1/.well-known/openid-configuration"] = Fake.events(fake.world, :as_metadata)
    end

    test "uses the configured authorization server when the resource publishes no metadata" do
      fake = Fake.start(prm_path: nil)
      assert {_oauth, {:ok, _tools}} = list_tools(fake, authorization_server: fake.issuer)
      assert [%{"resource" => resource}] = Fake.events(fake.world, :authorize)
      assert resource == fake.mcp_url
    end

    test "fails without metadata or a configured authorization server" do
      fake = Fake.start(prm_path: nil)

      assert {_oauth, {:error, %Error{kind: :authorization, cause: cause}}} = list_tools(fake)
      assert {:no_protected_resource_metadata, _resource} = cause
      assert Fake.events(fake.world, :authorize) == []
    end
  end

  describe "scope selection" do
    test "takes the scope from the challenge" do
      fake = Fake.start(required_scopes: ["mcp:basic"], include_scope_in_www_auth: true)
      assert {_oauth, {:ok, _tools}} = list_tools(fake)
      assert [%{"scope" => "mcp:basic"}] = Fake.events(fake.world, :authorize)
    end

    test "takes every scope the resource supports when the challenge names none" do
      scopes = ["mcp:basic", "mcp:read", "mcp:write"]
      fake = Fake.start(required_scopes: scopes, prm_scopes_supported: scopes)
      assert {_oauth, {:ok, _tools}} = list_tools(fake)
      assert [%{"scope" => "mcp:basic mcp:read mcp:write"}] = Fake.events(fake.world, :authorize)
    end

    test "omits the scope when nothing defines one" do
      fake = Fake.start()
      assert {_oauth, {:ok, _tools}} = list_tools(fake)
      assert [query] = Fake.events(fake.world, :authorize)
      refute Map.has_key?(query, "scope")
    end

    test "adds the configured scopes" do
      fake = Fake.start(required_scopes: ["mcp:basic"], include_scope_in_www_auth: true)
      assert {_oauth, {:ok, _tools}} = list_tools(fake, scopes: ["profile"])
      assert [%{"scope" => "mcp:basic profile"}] = Fake.events(fake.world, :authorize)
    end

    test "requests offline_access when the server lists it, unless turned off" do
      fake =
        Fake.start(
          required_scopes: ["mcp:basic"],
          prm_scopes_supported: ["mcp:basic"],
          scopes_supported: ["mcp:basic", "offline_access"]
        )

      assert {_oauth, {:ok, _tools}} = list_tools(fake)
      assert [%{"scope" => "mcp:basic offline_access"}] = Fake.events(fake.world, :authorize)

      fake =
        Fake.start(
          prm_scopes_supported: ["mcp:basic"],
          scopes_supported: ["mcp:basic", "offline_access"]
        )

      assert {_oauth, {:ok, _tools}} = list_tools(fake, offline_access: false)
      assert [%{"scope" => "mcp:basic"}] = Fake.events(fake.world, :authorize)
    end

    test "does not request offline_access the server does not list" do
      scopes = ["mcp:basic", "mcp:read"]

      fake =
        Fake.start(
          required_scopes: scopes,
          prm_scopes_supported: scopes,
          scopes_supported: scopes
        )

      assert {_oauth, {:ok, _tools}} = list_tools(fake)
      assert [%{"scope" => "mcp:basic mcp:read"}] = Fake.events(fake.world, :authorize)
    end
  end

  # tools/list needs mcp:basic and tools/call needs mcp:write, as in the
  # runner's step-up scenario.
  defp step_up_auth(conn, message, world) do
    needed = if message["method"] == "tools/call", do: ["mcp:write"], else: ["mcp:basic"]

    case Fake.RS.token(conn) do
      nil ->
        {:refuse, 401, Fake.RS.challenge(world, [{"scope", "mcp:basic"}]),
         %{"error" => "invalid_token"}}

      token ->
        with {:ok, scopes} <- Fake.token_scopes(world, token),
             [] <- needed -- scopes do
          :ok
        else
          _missing ->
            params = [{"error", "insufficient_scope"}, {"scope", Enum.join(needed, " ")}]
            {:refuse, 403, Fake.RS.challenge(world, params), %{"error" => "insufficient_scope"}}
        end
    end
  end

  describe "step-up" do
    test "authorizes again for the union of the granted and the challenged scopes" do
      fake = Fake.start(auth: &step_up_auth/3, prm_scopes_supported: ["mcp:profile"])
      oauth = start_oauth(fake)
      client = connect(fake, oauth)

      assert {:ok, _tools} = Client.list_tools(client)
      assert {:ok, %{"content" => _content}} = Client.call_tool(client, "test-tool", %{})

      assert [%{"scope" => "mcp:basic"}, %{"scope" => second}] =
               Fake.events(fake.world, :authorize)

      assert second |> String.split(" ") |> Enum.sort() == ["mcp:basic", "mcp:write"]
      assert [%{status: 401}, %{status: 403}] = Fake.events(fake.world, :refused)
    end

    test "is refused when the challenge names nothing the token lacks" do
      fake = Fake.start(auth: fn conn, _message, world -> retry_limit_auth(conn, world) end)
      oauth = start_oauth(fake)
      client = connect(fake, oauth)

      assert {:error, %Error{kind: :transport, cause: {:unauthorized, 403, _challenge}}} =
               Client.list_tools(client)

      assert {:error, %Error{kind: :authorization, cause: {:step_up_refused, ["mcp:admin"]}}} =
               Client.list_tools(client)

      assert [%{"scope" => "mcp:admin"}] = Fake.events(fake.world, :authorize)
    end
  end

  # Every authenticated request is refused with the scope it already has.
  defp retry_limit_auth(conn, world) do
    case Fake.RS.token(conn) do
      nil ->
        {:refuse, 401, Fake.RS.challenge(world, [{"scope", "mcp:admin"}]),
         %{"error" => "invalid_token"}}

      _token ->
        params = [{"error", "insufficient_scope"}, {"scope", "mcp:admin"}]
        {:refuse, 403, Fake.RS.challenge(world, params), %{"error" => "insufficient_scope"}}
    end
  end

  describe "client identity" do
    test "uses the client ID metadata document URL when the server supports it" do
      fake = Fake.start(client_id_metadata_document_supported: true)
      assert {_oauth, {:ok, _tools}} = list_tools(fake, client_metadata_url: @cimd)
      assert Fake.events(fake.world, :register) == []
      assert [%{"client_id" => @cimd}] = Fake.events(fake.world, :authorize)

      assert [%{body: %{"client_id" => @cimd}, authorization: nil}] =
               Fake.events(fake.world, :token)
    end

    test "registers when the server does not support metadata documents" do
      fake = Fake.start()
      assert {_oauth, {:ok, _tools}} = list_tools(fake, client_metadata_url: @cimd)
      assert [_registration] = Fake.events(fake.world, :register)
      assert [%{"client_id" => "test-client-id"}] = Fake.events(fake.world, :authorize)
    end

    test "uses pre-registered credentials with HTTP basic authentication" do
      fake =
        Fake.start(
          registration: false,
          token_endpoint_auth_methods_supported: ["client_secret_basic"]
        )

      assert {_oauth, {:ok, _tools}} =
               list_tools(fake,
                 client_id: "pre-registered-client",
                 client_secret: "pre-registered-secret"
               )

      assert Fake.events(fake.world, :register) == []
      assert [%{body: body, authorization: "Basic " <> encoded}] = Fake.events(fake.world, :token)
      assert Base.decode64!(encoded) == "pre-registered-client:pre-registered-secret"
      refute Map.has_key?(body, "client_secret")
    end

    test "fails without an identity when the server offers no registration" do
      fake = Fake.start(registration: false)
      assert {_oauth, {:error, %Error{cause: :no_client_identity}}} = list_tools(fake)
      assert Fake.events(fake.world, :authorize) == []
    end

    for {method, check} <- [
          {"client_secret_basic",
           quote do
             assert %{authorization: "Basic " <> encoded, body: body} = var!(request)
             assert Base.decode64!(encoded) == "registered-id:registered-secret"
             refute Map.has_key?(body, "client_secret")
           end},
          {"client_secret_post",
           quote do
             assert %{authorization: nil, body: %{"client_secret" => "registered-secret"}} =
                      var!(request)
           end},
          {"none",
           quote do
             assert %{authorization: nil, body: body} = var!(request)
             refute Map.has_key?(body, "client_secret")
           end}
        ] do
      test "authenticates at the token endpoint as the registration says: #{method}" do
        method = unquote(method)

        fake =
          Fake.start(
            token_endpoint_auth_methods_supported: [method],
            on_register: fn _body ->
              secret =
                if method == "none", do: %{}, else: %{"client_secret" => "registered-secret"}

              Map.merge(
                %{"client_id" => "registered-id", "token_endpoint_auth_method" => method},
                secret
              )
            end
          )

        assert {_oauth, {:ok, _tools}} = list_tools(fake)
        assert [%{"token_endpoint_auth_method" => ^method}] = Fake.events(fake.world, :register)
        assert [request] = Fake.events(fake.world, :token)
        assert request.body["client_id"] == "registered-id"
        unquote(check)
      end
    end

    test "registers again with a new authorization server and reuses nothing" do
      fake2 = Fake.start(on_register: fn _body -> %{"client_id" => "as2-client-id"} end)
      as1_id = "as1-client-id-LEAKED-IF-SEEN-AT-AS2"
      test = self()

      fake1 =
        Fake.start(
          on_register: fn _body -> %{"client_id" => as1_id, "client_secret" => "as1-secret"} end,
          required_scopes: ["mcp:basic"],
          include_scope_in_www_auth: true,
          authorization_servers: fn world ->
            if Agent.get(world, &Map.get(&1, :migrated)),
              do: [fake2.issuer],
              else: [Fake.issuer(world)]
          end,
          auth: fn conn, message, world ->
            migrated = Agent.get(world, &Map.get(&1, :migrated, false))
            token = Fake.RS.token(conn)

            cond do
              is_nil(token) ->
                Fake.RS.default_auth(conn, message, world)

              migrated and match?({:ok, _scopes}, Fake.token_scopes(fake2.world, token)) ->
                :ok

              migrated ->
                {:refuse, 401, Fake.RS.challenge(world, []), %{"error" => "invalid_token"}}

              true ->
                Agent.update(world, &Map.put(&1, :migrated, true))
                send(test, :migrated)
                :ok
            end
          end
        )

      oauth = start_oauth(fake1)
      client = connect(fake1, oauth)

      assert {:ok, _tools} = Client.list_tools(client)
      assert_receive :migrated, 1_000
      assert {:ok, _tools} = Client.list_tools(client)

      assert [_as2_registration] = Fake.events(fake2.world, :register)
      assert [%{"client_id" => "as2-client-id"}] = Fake.events(fake2.world, :authorize)
      assert [%{body: %{"client_id" => "as2-client-id"}}] = Fake.events(fake2.world, :token)
      refute inspect(Fake.events(fake2.world)) =~ as1_id
    end
  end

  describe "issuer checks" do
    test "refuses the resource metadata of another resource" do
      fake = Fake.start(prm_resource: "https://evil.example.com/mcp")

      assert {_oauth, {:error, %Error{cause: {:resource_mismatch, requested, configured}}}} =
               list_tools(fake)

      assert requested == fake.mcp_url
      assert configured == "https://evil.example.com/mcp"
      assert Fake.events(fake.world, :authorize) == []
    end

    test "accepts metadata whose resource is a prefix of the server path" do
      fake = Fake.start()
      Fake.put_config(fake.world, :prm_resource, fake.rs_url)
      assert {_oauth, {:ok, _tools}} = list_tools(fake)
    end

    test "refuses authorization server metadata with another issuer" do
      fake = Fake.start(issuer: "https://attacker.example.com", route_prefix: "/mismatched-as")
      Fake.put_config(fake.world, :authorization_servers, fn world -> [Fake.as_url(world)] end)

      assert {_oauth, {:error, %Error{cause: {:issuer_mismatch, expected, found}}}} =
               list_tools(fake)

      assert expected == fake.as_url
      assert found == "https://attacker.example.com"
      assert ["/.well-known/oauth-authorization-server"] = Fake.events(fake.world, :as_metadata)
      assert Fake.events(fake.world, :register) == []
      assert Fake.events(fake.world, :authorize) == []
    end

    for {name, methods} <- [
          {"refuses a server whose metadata does not list PKCE methods", nil},
          {"refuses a server that does not list S256", ["plain"]}
        ] do
      test name do
        fake = Fake.start(code_challenge_methods_supported: unquote(methods))
        issuer = fake.as_url

        assert {_oauth, {:error, %Error{cause: {:pkce_unsupported, ^issuer}} = error}} =
                 list_tools(fake)

        assert error.message =~ "S256"
        assert Fake.events(fake.world, :register) == []
        assert Fake.events(fake.world, :authorize) == []
        assert Fake.events(fake.world, :token) == []
      end
    end

    test "client credentials do not need PKCE" do
      fake =
        Fake.start(
          registration: false,
          code_challenge_methods_supported: nil,
          token_endpoint_auth_methods_supported: ["client_secret_basic"]
        )

      assert {_oauth, {:ok, _tools}} =
               list_tools(fake,
                 grant: :client_credentials,
                 client_id: "cc-client",
                 client_secret: "cc-secret"
               )
    end

    for {name, advertised, redirect, expected} <- [
          {"accepts a matching iss the server advertised", true, :correct, :ok},
          {"proceeds without iss when the server does not advertise it", nil, :omit, :ok},
          {"rejects a missing iss the server advertised", true, :omit, :missing_iss},
          {"rejects a wrong iss", true, :wrong, :issuer_mismatch_in_response},
          {"rejects a wrong iss the server did not advertise", nil, :wrong,
           :issuer_mismatch_in_response},
          {"rejects an iss that only matches after normalization", true, :normalized,
           :issuer_mismatch_in_response}
        ] do
      test name do
        fake =
          Fake.start(
            iss_parameter_supported: unquote(advertised),
            iss_in_redirect: unquote(redirect)
          )

        {_oauth, result} = list_tools(fake)

        case unquote(expected) do
          :ok ->
            assert {:ok, _tools} = result
            assert [_request] = Fake.events(fake.world, :token)

          :issuer_mismatch_in_response ->
            assert {:error, %Error{cause: {:issuer_mismatch_in_response, _expected, _found}}} =
                     result

            assert Fake.events(fake.world, :token) == []

          reason ->
            assert {:error, %Error{cause: ^reason}} = result
            assert Fake.events(fake.world, :token) == []
        end
      end
    end
  end

  describe "the redirect" do
    test "a mismatched state is refused in constant time and the pending authorization dropped" do
      fake = Fake.start()

      authorize = fn url ->
        {:ok, location} = Fake.location(url)
        uri = URI.parse(location)
        query = uri.query |> URI.decode_query() |> Map.put("state", String.duplicate("x", 43))
        {:ok, URI.to_string(%{uri | query: URI.encode_query(query)})}
      end

      assert {_oauth, {:error, %Error{cause: :state_mismatch}}} =
               list_tools(fake, authorize: authorize)

      assert Fake.events(fake.world, :token) == []
    end

    test "a refusal by the authorization server is reported" do
      fake = Fake.start(deny: true)

      assert {_oauth, {:error, %Error{cause: {:authorization_denied, "access_denied", nil}}}} =
               list_tools(fake)

      assert Fake.events(fake.world, :token) == []
    end

    test "the authorize function may return the redirect URL" do
      fake = Fake.start()
      authorize = fn url -> Fake.location(url) end
      assert {_oauth, {:ok, _tools}} = list_tools(fake, authorize: authorize)
    end

    test "an external redirect is delivered with callback/2" do
      fake = Fake.start()
      test = self()

      authorize = fn url ->
        {:ok, location} = Fake.location(url)
        send(test, {:location, location})
        :ok
      end

      oauth =
        start_oauth(fake,
          authorize: authorize,
          redirect: {:external, "https://app.example.test/oauth/cb"}
        )

      assert OAuth.redirect_uri(oauth) == "https://app.example.test/oauth/cb"

      assert OAuth.callback(oauth, "https://app.example.test/oauth/cb?code=x") ==
               {:error, :no_pending_authorization}

      task = Task.async(fn -> Client.list_tools(connect(fake, oauth)) end)
      assert_receive {:location, "https://app.example.test/oauth/cb?" <> _query = location}, 5_000
      assert :ok = OAuth.callback(oauth, location)
      assert {:ok, _tools} = Task.await(task, 5_000)

      assert [
               %{
                 "redirect_uris" => ["https://app.example.test/oauth/cb"],
                 "application_type" => "web"
               }
             ] =
               Fake.events(fake.world, :register)
    end

    test "gives up after the authorization timeout" do
      fake = Fake.start()
      authorize = fn _url -> :ok end

      assert {_oauth, {:error, %Error{cause: :authorization_timeout}}} =
               list_tools(fake, authorize: authorize, authorization_timeout: 200)
    end

    test "a failing authorize function fails the request" do
      fake = Fake.start()

      assert {_oauth, {:error, %Error{cause: {:authorize_failed, :no_browser}}}} =
               list_tools(fake, authorize: fn _url -> {:error, :no_browser} end)

      assert {_oauth, {:error, %Error{cause: {:authorize_raised, %RuntimeError{}}}}} =
               list_tools(fake, authorize: fn _url -> raise "boom" end)

      assert {_oauth, {:error, %Error{cause: {:authorize_invalid_return, :what}}}} =
               list_tools(fake, authorize: fn _url -> :what end)
    end

    test "the loopback listener answers other requests with 404 and keeps waiting" do
      fake = Fake.start()
      test = self()

      authorize = fn url ->
        redirect = URI.parse(URI.decode_query(URI.parse(url).query)["redirect_uri"])
        send(test, {:redirect, redirect})
        other = URI.to_string(%{redirect | path: "/favicon.ico", query: nil})

        {:ok, {{_version, 404, _reason}, _headers, _body}} =
          :httpc.request(:get, {String.to_charlist(other), []}, [timeout: 5_000],
            body_format: :binary
          )

        Fake.follow(url)
      end

      assert {_oauth, {:ok, _tools}} = list_tools(fake, authorize: authorize)
    end
  end

  describe "tokens" do
    test "refreshes an expired token with its refresh token before the request" do
      fake = Fake.start(refresh_tokens: true, expires_in: 1)
      oauth = start_oauth(fake)
      client = connect(fake, oauth)

      assert {:ok, _tools} = Client.list_tools(client)
      assert {:ok, _tools} = Client.list_tools(client)

      assert [%{body: %{"grant_type" => "authorization_code"}}, %{body: refresh}] =
               Fake.events(fake.world, :token)

      assert refresh["grant_type"] == "refresh_token"
      assert refresh["refresh_token"] == "refresh-" <> hd(tokens(fake))
      assert refresh["resource"] == fake.mcp_url
      assert [_one] = Fake.events(fake.world, :authorize)
      assert [%{status: 401}] = Fake.events(fake.world, :refused)
    end

    test "authorizes again when the refresh is refused" do
      fake = Fake.start(refresh_tokens: true, expires_in: 1)
      oauth = start_oauth(fake)
      client = connect(fake, oauth)

      assert {:ok, _tools} = Client.list_tools(client)

      Fake.put_config(fake.world, :on_token, fn _body, _auth, _world ->
        {:error, 400, %{"error" => "invalid_grant"}}
      end)

      assert {:error,
              %Error{cause: {:token_endpoint, 400, %{"error" => "invalid_grant"}}} = error} =
               Client.list_tools(client)

      refute inspect(error) =~ "tok-"

      assert [
               _first,
               %{body: %{"grant_type" => "refresh_token"}},
               %{body: %{"grant_type" => "authorization_code"}}
             ] =
               Fake.events(fake.world, :token)
    end

    test "forget/1 drops the token" do
      fake = Fake.start()
      oauth = start_oauth(fake)
      client = connect(fake, oauth)

      assert {:ok, _tools} = Client.list_tools(client)
      assert :ok = OAuth.forget(oauth)
      assert {:ok, _tools} = Client.list_tools(client)
      assert [_first, _second] = Fake.events(fake.world, :authorize)
    end

    test "concurrent requests share one authorization" do
      fake = Fake.start()
      oauth = start_oauth(fake)
      client = connect(fake, oauth)

      results =
        1..5
        |> Enum.map(fn _index -> Task.async(fn -> Client.list_tools(client) end) end)
        |> Task.await_many(5_000)

      assert Enum.all?(results, &match?({:ok, _tools}, &1))
      assert [_one] = Fake.events(fake.world, :authorize)
      assert [_one] = Fake.events(fake.world, :token)
    end

    test "a token of another type is refused" do
      fake =
        Fake.start(
          on_token: fn _body, _auth, _world ->
            {:ok, %{"access_token" => "x", "token_type" => "DPoP"}}
          end
        )

      assert {_oauth, {:error, %Error{cause: {:unsupported_token_type, "DPoP"}}}} =
               list_tools(fake)
    end

    test "a DPoP challenge is refused" do
      fake =
        Fake.start(
          auth: fn _conn, _message, world ->
            {:refuse, 401,
             "DPoP resource_metadata=\"#{Fake.rs_url(world)}/.well-known/oauth-protected-resource/mcp\"",
             %{}}
          end
        )

      assert {_oauth, {:error, %Error{cause: {:unsupported_scheme, "dpop"}}}} = list_tools(fake)
      assert Fake.events(fake.world, :prm) == []
    end

    test "an endpoint that is neither https nor loopback is refused" do
      fake = Fake.start(extra_metadata: %{"token_endpoint" => "http://as.example.com/token"})

      assert {_oauth, {:error, %Error{cause: {:insecure_url, "http://as.example.com/token"}}}} =
               list_tools(fake)
    end
  end

  describe "client credentials" do
    test "obtains the token before the first request with client_secret_basic" do
      fake =
        Fake.start(
          registration: false,
          grant_types_supported: ["client_credentials"],
          token_endpoint_auth_methods_supported: ["client_secret_basic"]
        )

      assert {_oauth, {:ok, _tools}} =
               list_tools(fake,
                 grant: :client_credentials,
                 client_id: "cc-client",
                 client_secret: "cc-secret"
               )

      assert Fake.events(fake.world, :refused) == []
      assert Fake.events(fake.world, :authorize) == []
      assert [%{body: body, authorization: "Basic " <> encoded}] = Fake.events(fake.world, :token)
      assert Base.decode64!(encoded) == "cc-client:cc-secret"
      assert body["grant_type"] == "client_credentials"
      assert body["resource"] == fake.mcp_url
      refute Map.has_key?(body, "scope")
    end

    test "sends the secret in the body with client_secret_post and the scope the resource lists" do
      fake =
        Fake.start(
          registration: false,
          prm_scopes_supported: ["mcp:read"],
          token_endpoint_auth_methods_supported: ["client_secret_post"]
        )

      assert {_oauth, {:ok, _tools}} =
               list_tools(fake,
                 grant: :client_credentials,
                 client_id: "cc-client",
                 client_secret: "cc-secret"
               )

      assert [
               %{
                 body: %{"client_secret" => "cc-secret", "scope" => "mcp:read"},
                 authorization: nil
               }
             ] =
               Fake.events(fake.world, :token)
    end

    test "authenticates with a private_key_jwt assertion" do
      jwk = JOSE.JWK.generate_key({:ec, "P-256"})
      {_kty, public} = JOSE.JWK.to_public_map(jwk)
      pem = JOSE.JWK.to_pem(jwk) |> elem(1)
      test = self()

      fake =
        Fake.start(
          registration: false,
          grant_types_supported: ["client_credentials"],
          token_endpoint_auth_methods_supported: ["private_key_jwt"],
          on_token: fn body, _auth, _world ->
            send(test, {:assertion, body})

            case JOSE.JWT.verify_strict(
                   JOSE.JWK.from_map(public),
                   ["ES256"],
                   body["client_assertion"]
                 ) do
              {true, %JOSE.JWT{fields: claims}, _jws} ->
                send(test, {:claims, claims})

                {:ok,
                 %{"access_token" => "cc-token-1", "token_type" => "Bearer", "expires_in" => 60}}

              _invalid ->
                {:error, 401, %{"error" => "invalid_client"}}
            end
          end
        )

      assert {_oauth, {:ok, _tools}} =
               list_tools(fake,
                 grant: :client_credentials,
                 client_id: "jwt-client",
                 private_key: pem
               )

      assert_receive {:assertion, body}, 1_000

      assert body["client_assertion_type"] ==
               "urn:ietf:params:oauth:client-assertion-type:jwt-bearer"

      assert body["client_id"] == "jwt-client"
      assert_receive {:claims, claims}, 1_000
      assert claims["iss"] == "jwt-client"
      assert claims["sub"] == "jwt-client"
      assert claims["aud"] == fake.issuer
      assert is_binary(claims["jti"])
      assert claims["exp"] > claims["iat"]
    end
  end

  describe "Discovery on its own" do
    alias Snodo.OAuth.Client.Discovery

    test "fetches both documents with keyword settings" do
      fake = Fake.start(prm_scopes_supported: ["mcp:read"])

      assert {:ok, %{"resource" => resource, "scopes_supported" => ["mcp:read"]} = metadata} =
               Discovery.protected_resource([timeout_ms: 2_000], fake.mcp_url)

      assert resource == fake.mcp_url
      assert Discovery.issuer(metadata) == fake.issuer

      assert {:ok, %{"issuer" => issuer, "token_endpoint" => _endpoint}} =
               Discovery.authorization_server([], fake.issuer)

      assert issuer == fake.issuer
    end

    test "reports what it could not find" do
      fake = Fake.start(prm_path: nil)

      assert {:error, :no_protected_resource_metadata} =
               Discovery.protected_resource([], fake.mcp_url)

      assert {:error, {:no_authorization_server_metadata, _issuer}} =
               Discovery.authorization_server([], fake.rs_url)

      assert {:error, {:invalid_issuer, "not a url"}} =
               Discovery.authorization_server([], "not a url")

      assert {:error, {:insecure_url, _url}} =
               Discovery.authorization_server([], "http://auth.example.com")
    end
  end

  test "options are checked" do
    fake = Fake.start()

    for {opts, message} <- [
          {[], ":resource is required"},
          {[resource: fake.mcp_url], ":authorize is required"},
          {[resource: fake.mcp_url, authorize: fn -> :ok end], ":authorize must be a function"},
          {[resource: fake.mcp_url, grant: :implicit], ":grant must be"},
          {[resource: fake.mcp_url, grant: :client_credentials, redirect: :none],
           ":redirect must be"},
          {[resource: fake.mcp_url, grant: :client_credentials, client_metadata_url: "http://x"],
           "https URL"},
          {[
             resource: fake.mcp_url,
             grant: :client_credentials,
             token_endpoint_auth_method: "mtls"
           ], ":token_endpoint_auth_method"},
          {[resource: fake.mcp_url, grant: :client_credentials, private_key: "not a pem"], "PEM"},
          {[resource: fake.mcp_url, grant: :client_credentials, scopes: "a b"], ":scopes"},
          {[resource: fake.mcp_url, grant: :client_credentials, token_store: Enum],
           "token_store must be"},
          {[resource: fake.mcp_url, grant: :client_credentials, http: [timeout_ms: 0]],
           "timeout_ms"}
        ] do
      assert_raise ArgumentError, ~r/#{Regex.escape(message)}/, fn -> OAuth.init(opts) end
    end
  end
end
