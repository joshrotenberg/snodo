defmodule Snodo.OAuth.Client do
  @moduledoc """
  The client side of the MCP authorization specification, as a
  `Snodo.Client.TokenProvider` for `Snodo.Client.HTTP`.

  Start one per MCP server and pass it to the client:

      {:ok, oauth} =
        Snodo.OAuth.Client.start_link(
          resource: "https://mcp.example.com/mcp",
          authorize: fn url -> System.cmd("open", [url]) && :ok end
        )

      {:ok, client} =
        Snodo.Client.connect({:http, "https://mcp.example.com/mcp"},
          token_provider: {Snodo.OAuth.Client, oauth}
        )

  The first request goes out without a token. The server's `401` carries a
  `WWW-Authenticate` challenge, and the transport hands it to this process,
  which runs the flow and returns the token the transport then retries
  with. Later requests carry the token; an expired one is refreshed with
  its refresh token before the request, a refused one after the `401`, and
  a `403` `insufficient_scope` starts a step-up for the union of the scopes
  granted and the scopes challenged. The flow runs in a process of its own,
  so this process answers other callers meanwhile, and every caller that
  needs a token while a flow is under way waits for that flow.

  ## The authorization code flow

    1. Protected resource metadata (RFC 9728), from the challenge's
       `resource_metadata` URL or the well-known locations, and checked to
       be for this server (`Snodo.OAuth.Client.Discovery`).
    2. Authorization server metadata (RFC 8414, OpenID configuration) for
       the first `authorization_servers` entry, with the issuer checked. The
       code flow also requires `S256` in `code_challenge_methods_supported`
       and stops without it, before registering or authorizing.
    3. A client ID: the `:client_metadata_url` when the server supports
       client ID metadata documents, else the configured `:client_id`, else
       the registration stored for this issuer, else dynamic client
       registration (RFC 7591).
    4. The scope: the challenge's `scope`, else the resource's
       `scopes_supported`, plus scopes granted before, `:scopes`, and
       `offline_access` when the server lists it (SEP-2207).
    5. The authorization request, with PKCE `S256`, a random `state`, and
       the `resource` (RFC 8707), given to the `:authorize` function. The
       redirect lands on the loopback listener, or the function returns it,
       or the application delivers it with `callback/2`. `state` is compared
       in constant time; `iss` is compared exactly when present and required
       when the server advertises it (RFC 9207).
    6. The token request, authenticated as the registration or the server
       requires: `none`, `client_secret_basic`, `client_secret_post`, or
       `private_key_jwt`.

  With `grant: :client_credentials`, steps 1 to 3 run the same and the
  token request uses the client credentials grant; the first `token/2`
  call obtains the token without waiting for a challenge.

  ## Options

  | Option | Default | Meaning |
  |---|---|---|
  | `:resource` | required | The MCP server URL; see `Snodo.OAuth.ResourceServer.resource!/1` |
  | `:authorize` | required for the code flow | A function of the authorization URL; see below |
  | `:grant` | `:authorization_code` | `:authorization_code` or `:client_credentials` |
  | `:redirect` | `{:loopback, []}` | `{:loopback, port: 0, path: "/callback"}`, or `{:external, uri}` for an endpoint of the application's own |
  | `:client_metadata_url` | none | The `https` URL of this client's ID metadata document |
  | `:client_id`, `:client_secret` | none | A pre-registered client |
  | `:token_endpoint_auth_method` | derived | Forces one of `none`, `client_secret_basic`, `client_secret_post`, `private_key_jwt` |
  | `:private_key`, `:signing_algorithm` | none | The key for `private_key_jwt`: a PEM string, a JWK map, or a `JOSE.JWK`; the algorithm is derived from the key when not given |
  | `:client_assertion_audience` | the issuer | The `aud` of the `private_key_jwt` assertion |
  | `:client_name` | `"snodo"` | Registration metadata |
  | `:application_type` | `"native"`, or `"web"` for an `https` redirect | Registration metadata |
  | `:client_metadata` | `%{}` | Extra registration metadata, merged last |
  | `:scopes` | `[]` | Scopes to request on top of what the server asks for |
  | `:offline_access` | `true` | Request `offline_access` when the server lists it |
  | `:authorization_server` | none | The issuer to use when the server publishes no protected resource metadata |
  | `:authorization_timeout` | 300,000 | Milliseconds to wait for the redirect |
  | `:http` | `[]` | `timeout_ms` (10,000), `max_body_bytes` (262,144), and `ssl` options for the flow's requests |
  | `:token_store`, `:registration_store`, `:pending_store` | memory | `{module, arg}` per the store behaviours |
  | `:name` | none | A registered name |

  The `:authorize` function receives the authorization URL and returns
  `:ok` after starting the browser, when the redirect will arrive at the
  loopback listener or through `callback/2`; `{:ok, redirect_url}` when it
  obtained the redirect itself, for example by following the redirect in a
  headless client; or `{:error, reason}`. It runs in a process of its own
  and may block.

  Every URL the flow uses must be `https`, or `http` to a loopback host. A
  document or token response larger than `max_body_bytes` is refused, with
  `:body_too_large` in the error's `cause`; `:httpc` reads the body before
  its size is checked, so `timeout_ms` bounds the transfer. Tokens are kept
  in the token store and never logged or placed in an error.

  Errors have `kind: :authorization`, code -32000, and a `cause` naming the
  step that failed, such as `{:resource_mismatch, requested, configured}`,
  `{:issuer_mismatch, expected, found}`, `{:pkce_unsupported, issuer}`,
  `{:token_endpoint, status, body}` with only the error fields of the body,
  or `{:step_up_refused, scopes}`.
  """

  use GenServer

  @behaviour Snodo.Client.TokenProvider

  alias Snodo.OAuth.Client.ClientAuth
  alias Snodo.OAuth.Client.Flow
  alias Snodo.OAuth.Client.HTTP
  alias Snodo.OAuth.Client.Loopback
  alias Snodo.OAuth.ResourceServer

  @leeway 30
  @grants [:authorization_code, :client_credentials]

  @doc "Starts the client. See the module documentation for the options."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    case Keyword.pop(opts, :name) do
      {nil, opts} -> GenServer.start_link(__MODULE__, opts)
      {name, opts} -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @impl Snodo.Client.TokenProvider
  def token(client, context), do: GenServer.call(client, {:token, context}, :infinity)

  @impl Snodo.Client.TokenProvider
  def refresh(client, challenge, context),
    do: GenServer.call(client, {:refresh, challenge, context}, :infinity)

  @doc """
  Delivers the authorization server's redirect to a flow that waits for it,
  for a `{:external, uri}` redirect the application receives itself.

  Takes the full redirect URL or its decoded query parameters. Returns
  `{:error, :no_pending_authorization}` when no flow is waiting.
  """
  @spec callback(GenServer.server(), String.t() | map()) ::
          :ok | {:error, :no_pending_authorization}
  def callback(client, url) when is_binary(url),
    do: callback(client, URI.decode_query(URI.parse(url).query || "", %{}, :www_form))

  def callback(client, %{} = params), do: GenServer.call(client, {:callback, params})

  @doc "The redirect URI this client registers and expects the redirect on."
  @spec redirect_uri(GenServer.server()) :: String.t()
  def redirect_uri(client), do: GenServer.call(client, :redirect_uri)

  @doc "Forgets the token held for the resource. The next request authorizes again."
  @spec forget(GenServer.server()) :: :ok
  def forget(client), do: GenServer.call(client, :forget)

  @impl GenServer
  def init(opts) do
    resource = ResourceServer.resource!(required!(opts, :resource))
    config = config!(opts)
    listener = listener!(config.redirect)

    redirect =
      case config.redirect do
        {:loopback, _opts} -> listener.uri
        {:external, uri} -> uri
      end

    {:ok,
     %{
       resource: resource,
       config: config,
       listener: listener,
       redirect: redirect,
       stores: stores!(opts),
       flow: nil
     }}
  end

  @impl GenServer
  def handle_call({:token, _context}, from, %{flow: %{}} = state),
    do: {:noreply, join(state, from)}

  def handle_call({:token, _context}, from, state) do
    case current(state) do
      {:ok, %{access_token: token} = held} ->
        cond do
          fresh?(held) -> {:reply, {:ok, token}, state}
          is_binary(held.refresh_token) -> {:noreply, start_flow(state, :refresh, from)}
          true -> no_token(state, from)
        end

      :error ->
        no_token(state, from)
    end
  end

  def handle_call({:refresh, _challenge, _context}, from, %{flow: %{}} = state),
    do: {:noreply, join(state, from)}

  def handle_call({:refresh, challenge, context}, from, state) do
    case current(state) do
      {:ok, %{access_token: token} = held} when token != context.token ->
        if fresh?(held),
          do: {:reply, {:ok, token}, state},
          else: {:noreply, start_flow(state, {:challenge, context.status, challenge}, from)}

      _same_or_none ->
        {:noreply, start_flow(state, {:challenge, context.status, challenge}, from)}
    end
  end

  def handle_call({:callback, params}, _from, %{flow: %{pid: pid, ref: ref}} = state) do
    send(pid, {:redirect, ref, params})
    {:reply, :ok, state}
  end

  def handle_call({:callback, _params}, _from, state),
    do: {:reply, {:error, :no_pending_authorization}, state}

  def handle_call(:redirect_uri, _from, state), do: {:reply, state.redirect, state}

  def handle_call(:forget, _from, state) do
    {_result, state} = store(state, :token, {:delete, state.resource})
    {:reply, :ok, state}
  end

  def handle_call({:store, kind, op}, _from, state) do
    {result, state} = store(state, kind, op)
    {:reply, result, state}
  end

  @impl GenServer
  def handle_info({tag, result}, %{flow: %{tag: tag, monitor: monitor}} = state) do
    Process.demonitor(monitor, [:flush])
    {:noreply, finish(state, result)}
  end

  def handle_info({:DOWN, monitor, :process, _pid, reason}, %{flow: %{monitor: monitor}} = state),
    do: {:noreply, finish(state, {:error, Flow.error({:flow_crashed, reason})})}

  def handle_info(_message, state), do: {:noreply, state}

  # Without a token, the code flow waits for the server's challenge, which
  # names the metadata and the scope; client credentials need neither.
  defp no_token(%{config: %{grant: :client_credentials}} = state, from),
    do: {:noreply, start_flow(state, :initial, from)}

  defp no_token(state, _from), do: {:reply, {:ok, nil}, state}

  defp start_flow(state, trigger, from) do
    owner = self()
    tag = make_ref()

    ctx = %{
      owner: owner,
      resource: state.resource,
      config: state.config,
      redirect: state.redirect,
      listener: state.listener,
      trigger: trigger,
      current: current_token(state),
      ref: make_ref()
    }

    {pid, monitor} = spawn_monitor(fn -> send(owner, {tag, Flow.run(ctx)}) end)
    %{state | flow: %{pid: pid, monitor: monitor, tag: tag, ref: ctx.ref, waiters: [from]}}
  end

  defp join(%{flow: flow} = state, from),
    do: %{state | flow: %{flow | waiters: [from | flow.waiters]}}

  defp finish(%{flow: %{waiters: waiters}} = state, result) do
    Enum.each(waiters, &GenServer.reply(&1, result))
    %{state | flow: nil}
  end

  defp current(state) do
    {result, _state} = store(state, :token, {:fetch, state.resource})
    result
  end

  defp current_token(state) do
    case current(state) do
      {:ok, token} -> token
      :error -> nil
    end
  end

  defp fresh?(%{expires_at: nil}), do: true
  defp fresh?(%{expires_at: at}), do: at - @leeway > System.os_time(:second)

  defp store(state, kind, op) do
    {module, store} = Map.fetch!(state.stores, kind)

    case op do
      {:fetch, key} ->
        {module.fetch(store, key), state}

      {:put, key, value} ->
        {:ok, store} = module.put(store, key, value)
        {:ok, put_in(state, [:stores, kind], {module, store})}

      {:delete, key} ->
        {:ok, store} = module.delete(store, key)
        {:ok, put_in(state, [:stores, kind], {module, store})}
    end
  end

  defp config!(opts) do
    grant = Keyword.get(opts, :grant, :authorization_code)

    unless grant in @grants,
      do:
        raise(ArgumentError, ":grant must be one of #{inspect(@grants)}, got: #{inspect(grant)}")

    authorize = Keyword.get(opts, :authorize)

    unless is_nil(authorize) or is_function(authorize, 1),
      do: raise(ArgumentError, ":authorize must be a function of one argument")

    if grant == :authorization_code and is_nil(authorize),
      do: raise(ArgumentError, ":authorize is required for the authorization code flow")

    method = Keyword.get(opts, :token_endpoint_auth_method)

    unless is_nil(method) or method in ClientAuth.methods(),
      do:
        raise(
          ArgumentError,
          ":token_endpoint_auth_method must be one of #{inspect(ClientAuth.methods())}"
        )

    %{
      grant: grant,
      authorize: authorize,
      redirect: redirect!(Keyword.get(opts, :redirect, {:loopback, []})),
      client_metadata_url: https!(opts, :client_metadata_url),
      client_id: string!(opts, :client_id),
      client_secret: string!(opts, :client_secret),
      token_endpoint_auth_method: method,
      private_key: opts |> Keyword.get(:private_key) |> private_key!(),
      signing_algorithm: string!(opts, :signing_algorithm),
      client_assertion_audience: string!(opts, :client_assertion_audience),
      client_name: string!(opts, :client_name) || "snodo",
      application_type: application_type!(Keyword.get(opts, :application_type)),
      client_metadata: map!(opts, :client_metadata),
      scopes: scopes!(Keyword.get(opts, :scopes, [])),
      offline_access: boolean!(opts, :offline_access, true),
      authorization_server: string!(opts, :authorization_server),
      authorization_timeout: timeout!(Keyword.get(opts, :authorization_timeout, 300_000)),
      http: HTTP.config(Keyword.get(opts, :http, []))
    }
  end

  defp redirect!({:loopback, opts} = redirect) when is_list(opts), do: redirect

  defp redirect!({:external, uri} = redirect) when is_binary(uri) do
    case URI.new(uri) do
      {:ok, %URI{scheme: scheme}} when is_binary(scheme) and scheme != "" -> redirect
      _other -> raise ArgumentError, ":redirect {:external, uri} needs an absolute URI"
    end
  end

  defp redirect!(other) do
    raise ArgumentError,
          ":redirect must be {:loopback, opts} or {:external, uri}, got: #{inspect(other)}"
  end

  defp listener!({:loopback, opts}) do
    case Loopback.listen(opts) do
      {:ok, listener} ->
        listener

      {:error, reason} ->
        raise ArgumentError, "cannot bind the loopback listener: #{inspect(reason)}"
    end
  end

  defp listener!({:external, _uri}), do: nil

  defp stores!(opts) do
    Map.new([:token_store, :registration_store, :pending_store], fn key ->
      {kind, default} =
        case key do
          :token_store -> {:token, Snodo.OAuth.Client.TokenStore.Memory}
          :registration_store -> {:registration, Snodo.OAuth.Client.RegistrationStore.Memory}
          :pending_store -> {:pending, Snodo.OAuth.Client.PendingAuthorizationStore.Memory}
        end

      case Keyword.get(opts, key, {default, nil}) do
        {module, arg} when is_atom(module) ->
          {:ok, store} = module.init(arg)
          {kind, {module, store}}

        other ->
          raise ArgumentError, "#{key} must be {module, arg}, got: #{inspect(other)}"
      end
    end)
  end

  defp required!(opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, value} -> value
      :error -> raise ArgumentError, "#{inspect(key)} is required"
    end
  end

  defp string!(opts, key) do
    case Keyword.get(opts, key) do
      nil -> nil
      value when is_binary(value) -> value
      other -> raise ArgumentError, "#{inspect(key)} must be a string, got: #{inspect(other)}"
    end
  end

  defp https!(opts, key) do
    case string!(opts, key) do
      nil -> nil
      "https://" <> _rest = url -> url
      other -> raise ArgumentError, "#{inspect(key)} must be an https URL, got: #{inspect(other)}"
    end
  end

  defp private_key!(nil), do: nil
  defp private_key!(key), do: ClientAuth.jwk!(key)

  defp application_type!(nil), do: nil
  defp application_type!(type) when type in ["native", "web"], do: type

  defp application_type!(other),
    do:
      raise(
        ArgumentError,
        ":application_type must be \"native\" or \"web\", got: #{inspect(other)}"
      )

  defp map!(opts, key) do
    case Keyword.get(opts, key, %{}) do
      %{} = map -> map
      other -> raise ArgumentError, "#{inspect(key)} must be a map, got: #{inspect(other)}"
    end
  end

  defp scopes!(scopes) when is_list(scopes) do
    if Enum.all?(scopes, &(is_binary(&1) and &1 != "")),
      do: scopes,
      else: raise(ArgumentError, ":scopes must be a list of strings")
  end

  defp scopes!(other),
    do: raise(ArgumentError, ":scopes must be a list of strings, got: #{inspect(other)}")

  defp boolean!(opts, key, default) do
    case Keyword.get(opts, key, default) do
      value when is_boolean(value) -> value
      other -> raise ArgumentError, "#{inspect(key)} must be a boolean, got: #{inspect(other)}"
    end
  end

  defp timeout!(:infinity), do: :infinity
  defp timeout!(timeout) when is_integer(timeout) and timeout > 0, do: timeout

  defp timeout!(other),
    do:
      raise(
        ArgumentError,
        ":authorization_timeout must be a positive integer or :infinity, got: #{inspect(other)}"
      )
end
