defmodule Snodo.OAuth.Client.Flow do
  @moduledoc false
  # One authorization run, in a process of its own so `Snodo.OAuth.Client`
  # stays responsive while the user is in the browser. The stores live in
  # the owner and are reached through it. A run ends with `{:ok, token}` or
  # `{:error, %Snodo.Error{}}`; it never raises into the owner.

  alias Snodo.Error
  alias Snodo.OAuth.Client.ClientAuth
  alias Snodo.OAuth.Client.Discovery
  alias Snodo.OAuth.Client.HTTP
  alias Snodo.OAuth.Client.Loopback
  alias Snodo.OAuth.Client.PKCE

  @pending_ttl 600

  @type trigger :: :initial | :refresh | {:challenge, 401 | 403, Snodo.Client.Challenge.t() | nil}

  @spec run(map()) :: {:ok, String.t()} | {:error, Error.t()}
  def run(ctx) do
    with :ok <- check_scheme(ctx.trigger),
         {:ok, prm, resource} <- discover_resource(ctx),
         {:ok, issuer} <- issuer(prm, ctx),
         {:ok, as_metadata} <- Discovery.authorization_server(ctx.config.http, issuer) do
      obtain(ctx, as_metadata, %{resource: resource, prm: prm})
    end
    |> finish()
  rescue
    exception -> {:error, error({:flow_crashed, exception})}
  catch
    :exit, reason -> {:error, error({:flow_crashed, reason})}
  end

  defp finish({:ok, token}), do: {:ok, token}
  defp finish({:error, %Error{} = error}), do: {:error, error}
  defp finish({:error, reason}), do: {:error, error(reason)}

  # The challenge names the metadata document; without one the well-known
  # locations are tried. A server without one is only usable when the
  # application configured the authorization server.
  defp discover_resource(ctx) do
    case Discovery.protected_resource(ctx.config.http, ctx.resource, metadata_url(ctx.trigger)) do
      {:ok, prm} ->
        {:ok, prm, prm["resource"]}

      {:error, :no_protected_resource_metadata} when is_binary(ctx.config.authorization_server) ->
        {:ok, nil, ctx.resource}

      {:error, :no_protected_resource_metadata} ->
        {:error, {:no_protected_resource_metadata, ctx.resource}}

      {:error, _reason} = error ->
        error
    end
  end

  defp metadata_url({:challenge, _status, %{resource_metadata: url}}) when is_binary(url), do: url
  defp metadata_url(_trigger), do: nil

  defp issuer(prm, ctx) do
    case prm && Discovery.issuer(prm) do
      issuer when is_binary(issuer) ->
        {:ok, issuer}

      _none when is_binary(ctx.config.authorization_server) ->
        {:ok, ctx.config.authorization_server}

      _none ->
        {:error, :no_authorization_server}
    end
  end

  defp check_scheme({:challenge, _status, %{scheme: scheme}}) when scheme != "bearer",
    do: {:error, {:unsupported_scheme, scheme}}

  defp check_scheme(_trigger), do: :ok

  # A token from another authorization server is not reused (SEP-2352).
  defp current(ctx, as_metadata) do
    issuer = as_metadata["issuer"]

    case ctx.current do
      %{issuer: ^issuer} = token ->
        token

      %{} ->
        _deleted = store(ctx, :token, {:delete, ctx.resource})
        nil

      nil ->
        nil
    end
  end

  defp obtain(ctx, as_metadata, target) do
    current = current(ctx, as_metadata)

    case ctx.trigger do
      {:challenge, 403, challenge} ->
        step_up(ctx, as_metadata, target, current, challenge)

      _other when is_map(current) and is_binary(current.refresh_token) ->
        case refresh_grant(ctx, as_metadata, target, current) do
          {:ok, token} -> {:ok, token}
          {:error, _reason} -> grant(ctx, as_metadata, target, nil, [])
        end

      _other ->
        grant(ctx, as_metadata, target, current, [])
    end
  end

  # A step-up asks for the challenged scopes on top of the granted ones. When
  # the challenge names nothing the current token lacks, authorizing again
  # cannot help, and refusing here is what bounds a server that answers
  # every request with 403.
  defp step_up(ctx, as_metadata, target, current, challenge) do
    challenged = (challenge && challenge.scope) || []
    granted = (current && current.scopes) || []

    cond do
      challenged == [] -> {:error, :step_up_without_scope}
      challenged -- granted == [] -> {:error, {:step_up_refused, challenged}}
      true -> grant(ctx, as_metadata, target, current, challenged)
    end
  end

  defp grant(%{config: %{grant: :authorization_code}} = ctx, as_metadata, target, current, extra) do
    with {:ok, identity} <- identity(ctx, as_metadata),
         scopes = scopes(ctx, as_metadata, target, current, extra),
         {:ok, code, pending} <- authorize(ctx, as_metadata, target, identity, scopes),
         {:ok, token} <- exchange_code(ctx, as_metadata, target, identity, code, pending) do
      store_token(ctx, token)
    end
  end

  defp grant(%{config: %{grant: :client_credentials}} = ctx, as_metadata, target, current, extra) do
    with {:ok, identity} <- identity(ctx, as_metadata) do
      scopes = scopes(ctx, as_metadata, target, current, extra)

      fields = [
        {"grant_type", "client_credentials"},
        {"resource", target.resource} | scope_field(scopes)
      ]

      with {:ok, token} <- token_request(ctx, as_metadata, target, identity, fields, scopes) do
        store_token(ctx, token)
      end
    end
  end

  # Client identity, in order: a client ID metadata document when the server
  # accepts one, the configured registration, the registration stored for
  # this issuer, and dynamic client registration.
  defp identity(ctx, as_metadata) do
    config = ctx.config

    cond do
      as_metadata["client_id_metadata_document_supported"] == true and
          is_binary(config.client_metadata_url) ->
        {:ok,
         %{
           client_id: config.client_metadata_url,
           client_secret: nil,
           token_endpoint_auth_method: "none",
           source: :cimd
         }}

      is_binary(config.client_id) ->
        {:ok,
         %{
           client_id: config.client_id,
           client_secret: config.client_secret,
           token_endpoint_auth_method: nil,
           source: :configured
         }}

      true ->
        registered(ctx, as_metadata)
    end
  end

  defp registered(ctx, as_metadata) do
    case store(ctx, :registration, {:fetch, as_metadata["issuer"]}) do
      {:ok, %{redirect_uri: uri} = registration}
      when uri == ctx.redirect or ctx.config.grant == :client_credentials ->
        {:ok, Map.put(registration, :source, :stored)}

      _absent_or_stale ->
        register(ctx, as_metadata)
    end
  end

  defp register(ctx, as_metadata) do
    case as_metadata["registration_endpoint"] do
      endpoint when is_binary(endpoint) ->
        metadata = registration_metadata(ctx, as_metadata)

        case HTTP.post_json(ctx.config.http, endpoint, metadata) do
          {:ok, status, %{"client_id" => client_id} = response}
          when status in [200, 201] and is_binary(client_id) ->
            registration = %{
              client_id: client_id,
              client_secret: string(response["client_secret"]),
              token_endpoint_auth_method: string(response["token_endpoint_auth_method"]),
              issuer: as_metadata["issuer"],
              redirect_uri: ctx.redirect,
              response: response
            }

            _stored = store(ctx, :registration, {:put, as_metadata["issuer"], registration})
            {:ok, Map.put(registration, :source, :registered)}

          {:ok, status, body} ->
            {:error, {:registration_failed, status, sanitize(body)}}

          {:error, reason} ->
            {:error, {:registration_failed, reason}}
        end

      _absent ->
        {:error, :no_client_identity}
    end
  end

  defp registration_metadata(ctx, as_metadata) do
    config = ctx.config

    base = %{
      "client_name" => config.client_name,
      "token_endpoint_auth_method" => ClientAuth.registration_method(as_metadata, config),
      "application_type" => config.application_type || application_type(ctx.redirect)
    }

    grant =
      case config.grant do
        :authorization_code ->
          %{
            "redirect_uris" => [ctx.redirect],
            "grant_types" => ["authorization_code", "refresh_token"],
            "response_types" => ["code"]
          }

        :client_credentials ->
          %{"grant_types" => ["client_credentials"], "response_types" => []}
      end

    base |> Map.merge(grant) |> Map.merge(config.client_metadata)
  end

  defp application_type("https://" <> _rest), do: "web"
  defp application_type(_redirect), do: "native"

  # The scope to request: what the challenge asked for, else everything the
  # resource lists; plus what the current token was granted, the configured
  # scopes, and `offline_access` when the server offers it (SEP-2207).
  defp scopes(ctx, as_metadata, target, current, extra) do
    config = ctx.config

    challenged =
      case ctx.trigger do
        {:challenge, _status, %{scope: [_first | _rest] = scope}} -> scope
        _other -> strings(target.prm && target.prm["scopes_supported"])
      end

    granted = (current && current.scopes) || []

    offline =
      if config.offline_access and config.grant == :authorization_code and
           "offline_access" in strings(as_metadata["scopes_supported"]),
         do: ["offline_access"],
         else: []

    Enum.uniq(challenged ++ extra ++ granted ++ config.scopes ++ offline)
  end

  defp scope_field([]), do: []
  defp scope_field(scopes), do: [{"scope", Enum.join(scopes, " ")}]

  # The pending authorization is stored before the URL leaves this process,
  # and the loopback listener is already bound, so the redirect always has
  # somewhere to land.
  defp authorize(ctx, as_metadata, target, identity, scopes) do
    with {:ok, endpoint} <- endpoint(as_metadata, "authorization_endpoint") do
      verifier = PKCE.verifier()
      state = 32 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

      pending = %{
        code_verifier: verifier,
        redirect_uri: ctx.redirect,
        resource: target.resource,
        issuer: as_metadata["issuer"],
        scopes: scopes,
        client_id: identity.client_id,
        created_at: System.os_time(:second)
      }

      _stored = store(ctx, :pending, {:put, state, pending})

      query =
        [
          {"response_type", "code"},
          {"client_id", identity.client_id},
          {"redirect_uri", ctx.redirect},
          {"code_challenge", PKCE.challenge(verifier)},
          {"code_challenge_method", "S256"},
          {"state", state},
          {"resource", target.resource}
        ] ++ scope_field(scopes)

      url = with_query(endpoint, query)

      with {:ok, params} <- redirect(ctx, url),
           do: validate_redirect(ctx, as_metadata, params, state)
    end
  end

  defp redirect(ctx, url) do
    timeout = ctx.config.authorization_timeout
    acceptor = if ctx.listener, do: Loopback.accept(ctx.listener, self(), ctx.ref, timeout)
    {pid, monitor, tag} = run_authorize(ctx.config.authorize, url)

    try do
      await_redirect(ctx, tag, monitor, deadline(timeout))
    after
      if acceptor, do: Process.unlink(acceptor)
      if acceptor, do: Process.exit(acceptor, :kill)
      Process.demonitor(monitor, [:flush])
      Process.exit(pid, :kill)
    end
  end

  defp run_authorize(authorize, url) do
    parent = self()
    tag = make_ref()

    {pid, monitor} =
      spawn_monitor(fn ->
        result =
          try do
            authorize.(url)
          rescue
            exception -> {:raised, exception}
          end

        send(parent, {tag, result})
      end)

    {pid, monitor, tag}
  end

  # The redirect arrives from the loopback listener or from the owner's
  # `callback/2`, or the authorize function returns the redirect URL itself.
  defp await_redirect(ctx, tag, monitor, deadline) do
    ref = ctx.ref

    receive do
      {:redirect, ^ref, %{} = params} ->
        {:ok, params}

      {^tag, {:ok, url}} when is_binary(url) ->
        {:ok, URI.decode_query(URI.parse(url).query || "", %{}, :www_form)}

      {^tag, {:ok, %{} = params}} ->
        {:ok, params}

      {^tag, :ok} ->
        Process.demonitor(monitor, [:flush])
        await_redirect(ctx, tag, monitor, deadline)

      {^tag, {:error, reason}} ->
        {:error, {:authorize_failed, reason}}

      {^tag, {:raised, exception}} ->
        {:error, {:authorize_raised, exception}}

      {^tag, other} ->
        {:error, {:authorize_invalid_return, other}}

      {:DOWN, ^monitor, :process, _pid, reason} ->
        {:error, {:authorize_exit, reason}}
    after
      remaining(deadline) -> {:error, :authorization_timeout}
    end
  end

  # `state` is compared in constant time against the value this run issued,
  # and only then used to look the pending authorization up.
  defp validate_redirect(ctx, as_metadata, params, expected) do
    with {:ok, state} <- param(params, "state", :missing_state),
         :ok <- check_state(state, expected),
         {:ok, pending} <- fetch_pending(ctx, expected),
         :ok <- check_error(params),
         {:ok, code} <- param(params, "code", :missing_code),
         :ok <- check_iss(as_metadata, params["iss"]) do
      {:ok, code, pending}
    end
  end

  defp check_state(state, expected)
       when byte_size(state) == byte_size(expected) and byte_size(expected) > 0 do
    if :crypto.hash_equals(state, expected), do: :ok, else: {:error, :state_mismatch}
  end

  defp check_state(_state, _expected), do: {:error, :state_mismatch}

  defp fetch_pending(ctx, state) do
    result = store(ctx, :pending, {:fetch, state})
    _deleted = store(ctx, :pending, {:delete, state})

    case result do
      {:ok, %{created_at: created} = pending} ->
        if created + @pending_ttl >= System.os_time(:second),
          do: {:ok, pending},
          else: {:error, :stale_authorization}

      _absent ->
        {:error, :unknown_state}
    end
  end

  defp check_error(%{"error" => error}) when is_binary(error),
    do: {:error, {:authorization_denied, error, nil}}

  defp check_error(_params), do: :ok

  # RFC 9207: a present `iss` must equal the issuer exactly, advertised or
  # not; an advertised `iss` must be present.
  defp check_iss(as_metadata, iss) do
    issuer = as_metadata["issuer"]

    cond do
      is_binary(iss) and iss == issuer ->
        :ok

      is_binary(iss) ->
        {:error, {:issuer_mismatch_in_response, issuer, iss}}

      as_metadata["authorization_response_iss_parameter_supported"] == true ->
        {:error, :missing_iss}

      true ->
        :ok
    end
  end

  defp exchange_code(ctx, as_metadata, target, identity, code, pending) do
    fields = [
      {"grant_type", "authorization_code"},
      {"code", code},
      {"redirect_uri", pending.redirect_uri},
      {"code_verifier", pending.code_verifier},
      {"resource", target.resource}
    ]

    token_request(ctx, as_metadata, target, identity, fields, pending.scopes)
  end

  # A refresh keeps the refresh token and the scopes when the response
  # carries none. A refusal drops the stored token; the caller authorizes
  # again from the start.
  defp refresh_grant(ctx, as_metadata, target, current) do
    with {:ok, identity} <- identity(ctx, as_metadata) do
      fields = [
        {"grant_type", "refresh_token"},
        {"refresh_token", current.refresh_token},
        {"resource", target.resource}
      ]

      case token_request(ctx, as_metadata, target, identity, fields, current.scopes) do
        {:ok, token} ->
          token = %{token | refresh_token: token.refresh_token || current.refresh_token}
          store_token(ctx, token)

        {:error, _reason} = error ->
          _deleted = store(ctx, :token, {:delete, ctx.resource})
          error
      end
    end
  end

  defp token_request(ctx, as_metadata, target, identity, fields, requested_scopes) do
    method = ClientAuth.method(identity, as_metadata, ctx.config)

    with {:ok, fields, headers} <-
           ClientAuth.apply(method, identity, ctx.config, as_metadata, fields),
         {:ok, endpoint} <- endpoint(as_metadata, "token_endpoint"),
         response = HTTP.post_form(ctx.config.http, endpoint, fields, headers),
         {:ok, body} <- token_response(response),
         :ok <- check_token_type(body) do
      {:ok,
       %{
         access_token: body["access_token"],
         token_type: "bearer",
         expires_at: expires_at(body["expires_in"]),
         refresh_token: string(body["refresh_token"]),
         scopes: granted_scopes(body["scope"], requested_scopes),
         issuer: as_metadata["issuer"],
         resource: target.resource
       }}
    end
  end

  defp token_response({:ok, 200, %{"access_token" => token} = body}) when is_binary(token),
    do: {:ok, body}

  defp token_response({:ok, status, body}),
    do: {:error, {:token_endpoint, status, sanitize(body)}}

  defp token_response({:error, reason}), do: {:error, {:token_endpoint, reason}}

  defp check_token_type(%{"token_type" => type}) when is_binary(type) do
    if String.downcase(type) == "bearer", do: :ok, else: {:error, {:unsupported_token_type, type}}
  end

  defp check_token_type(_body), do: {:error, {:unsupported_token_type, nil}}

  defp expires_at(seconds) when is_integer(seconds) and seconds > 0,
    do: System.os_time(:second) + seconds

  defp expires_at(_other), do: nil

  # RFC 6749 section 5.1: a response without `scope` granted what was asked.
  defp granted_scopes(scope, _requested) when is_binary(scope),
    do: String.split(scope, " ", trim: true)

  defp granted_scopes(_scope, requested), do: requested

  defp store_token(ctx, token) do
    _stored = store(ctx, :token, {:put, ctx.resource, token})
    {:ok, token.access_token}
  end

  defp endpoint(as_metadata, name) do
    with url when is_binary(url) <- as_metadata[name],
         :ok <- HTTP.check_url(url) do
      {:ok, url}
    else
      nil -> {:error, {:missing_endpoint, name}}
      {:error, _reason} = error -> error
    end
  end

  defp with_query(url, query) do
    encoded = URI.encode_query(query, :www_form)
    if String.contains?(url, "?"), do: url <> "&" <> encoded, else: url <> "?" <> encoded
  end

  defp param(params, name, missing) do
    case params do
      %{^name => value} when is_binary(value) and value != "" -> {:ok, value}
      _other -> {:error, missing}
    end
  end

  # Only the error fields of a response go in an error, never a token.
  defp sanitize(%{} = body), do: Map.take(body, ["error", "error_description", "error_uri"])
  defp sanitize(_body), do: nil

  defp string(value) when is_binary(value), do: value
  defp string(_value), do: nil

  defp strings(list) when is_list(list), do: Enum.filter(list, &is_binary/1)
  defp strings(_other), do: []

  defp store(ctx, kind, op), do: GenServer.call(ctx.owner, {:store, kind, op}, :infinity)

  defp deadline(:infinity), do: :infinity
  defp deadline(timeout), do: System.monotonic_time(:millisecond) + timeout

  defp remaining(:infinity), do: :infinity
  defp remaining(deadline), do: max(deadline - System.monotonic_time(:millisecond), 0)

  @doc false
  @spec error(term()) :: Error.t()
  def error(reason) do
    %Error{code: -32_000, message: message(reason), kind: :authorization, cause: reason}
  end

  defp message({:resource_mismatch, requested, configured}),
    do: "The protected resource metadata is for #{inspect(configured)}, not #{requested}"

  defp message({:no_protected_resource_metadata, resource}),
    do: "No protected resource metadata was found for #{resource}"

  defp message({:no_authorization_server_metadata, issuer}),
    do: "No authorization server metadata was found for #{issuer}"

  defp message(:no_authorization_server),
    do: "The protected resource metadata names no authorization server"

  defp message({:issuer_mismatch, expected, found}),
    do: "The authorization server metadata names issuer #{inspect(found)}, expected #{expected}"

  defp message({:issuer_mismatch_in_response, expected, found}),
    do: "The authorization response names issuer #{found}, expected #{expected}"

  defp message(:missing_iss),
    do: "The authorization response lacks the iss parameter the server advertised"

  defp message({:insecure_url, url}), do: "Refusing to use #{inspect(url)}: not https or loopback"
  defp message({:unsupported_scheme, scheme}), do: "Unsupported authentication scheme #{scheme}"

  defp message(:no_client_identity),
    do: "No client ID: the server accepts neither a client ID metadata document nor registration"

  defp message({:registration_failed, status, body}),
    do: "Client registration failed with HTTP #{status}: #{describe(body)}"

  defp message({:registration_failed, reason}),
    do: "Client registration failed: #{inspect(reason)}"

  defp message({:token_endpoint, status, body}),
    do: "The token endpoint answered HTTP #{status}: #{describe(body)}"

  defp message({:token_endpoint, reason}), do: "The token request failed: #{inspect(reason)}"

  defp message({:step_up_refused, scopes}),
    do: "The server asks for scope #{Enum.join(scopes, " ")}, which the token already carries"

  defp message(:step_up_without_scope), do: "The server asks for more scope without naming it"
  defp message(:authorization_timeout), do: "The authorization was not completed in time"

  defp message({:authorize_failed, reason}),
    do: "The authorize function failed: #{inspect(reason)}"

  defp message({:authorize_raised, exception}),
    do: "The authorize function raised: " <> Exception.message(exception)

  defp message({:authorize_exit, reason}), do: "The authorize function exited: #{inspect(reason)}"

  defp message({:authorize_invalid_return, _value}),
    do: "The authorize function must return :ok, {:ok, url}, or {:error, reason}"

  defp message(:missing_state), do: "The authorization response carries no state"
  defp message(:state_mismatch), do: "The authorization response state does not match"
  defp message(:unknown_state), do: "The authorization response matches no pending authorization"
  defp message(:stale_authorization), do: "The pending authorization is older than ten minutes"
  defp message(:missing_code), do: "The authorization response carries no code"

  defp message({:authorization_denied, error, _description}),
    do: "The authorization server refused: #{error}"

  defp message({:unsupported_token_type, type}),
    do: "The token is of type #{inspect(type)}; only bearer tokens are supported"

  defp message({:missing_endpoint, name}), do: "The authorization server metadata has no #{name}"
  defp message({:invalid_issuer, issuer}), do: "Invalid issuer #{inspect(issuer)}"
  defp message(:missing_client_secret), do: "The token endpoint needs a client secret"
  defp message(:missing_private_key), do: "private_key_jwt needs a :private_key"

  defp message({:unsupported_token_endpoint_auth_method, method}),
    do: "Unsupported token endpoint authentication method #{inspect(method)}"

  defp message({:flow_crashed, %{__exception__: true} = exception}),
    do: "The authorization flow raised: " <> Exception.message(exception)

  defp message({:flow_crashed, reason}), do: "The authorization flow exited: #{inspect(reason)}"
  defp message({:http_error, reason}), do: "The HTTP request failed: #{inspect(reason)}"
  defp message(:body_too_large), do: "A response exceeded the body limit"
  defp message({:invalid_json, status}), do: "A #{status} response was not a JSON object"
  defp message(reason), do: "Authorization failed: #{inspect(reason)}"

  defp describe(%{"error" => error} = body) when is_binary(error) do
    case body["error_description"] do
      description when is_binary(description) -> error <> " (" <> description <> ")"
      _none -> error
    end
  end

  defp describe(_body), do: "no error description"
end
