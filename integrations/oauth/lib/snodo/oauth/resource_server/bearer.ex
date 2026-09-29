defmodule Snodo.OAuth.ResourceServer.Bearer do
  @moduledoc """
  Requires a valid bearer token and hands its identity to `snodo_plug`.

  Put it after `Snodo.OAuth.ResourceServer.Metadata` and before
  `Snodo.Transport.Plug`:

      plug Snodo.OAuth.ResourceServer.Bearer,
        resource: "https://mcp.example.com/mcp",
        verifier:
          {Snodo.OAuth.ResourceServer.Verifier.JWT,
           keys: MyApp.JWKS, issuer: "https://auth.example.com"},
        required_scopes: ["mcp:read"]

  For every request, the plug reads the `Authorization` header, calls the
  verifier, and checks the claims it returns: `exp` and `nbf` against the
  clock (with `:leeway`), `aud` against `:audience` (RFC 8707: a token must
  name this resource), and the granted scopes against `:required_scopes`.
  A request that passes carries the assign that `Snodo.Transport.Plug`
  trusts:

      %{principal: claims["sub"], client_id: claims["client_id"],
        scopes: ["mcp:read"], claims: claims}

  `scopes` comes from the `scope` claim (a space-separated string, RFC 9068)
  or a `scp` list. The raw token is not included in the assign; a handler
  must never forward it to another service.

  A request that fails is halted with a JSON body and a `WWW-Authenticate`
  challenge naming the metadata document, as the MCP authorization
  specification and RFC 9728 require:

  | Status | Header | When |
  |---|---|---|
  | 401 | `Bearer resource_metadata="..."` | No `Authorization` header, or a scheme other than `Bearer` |
  | 401 | `Bearer error="invalid_token", ...` | The verifier refused the token, it has expired or is not yet valid, or its audience is not this resource |
  | 403 | `Bearer error="insufficient_scope", scope="...", ...` | A required scope is missing |
  | 400 | `Bearer error="invalid_request", ...` | A malformed token or more than one `Authorization` header |

  When `:required_scopes` is set, the `scope` parameter is on every
  challenge, so a client knows what to request before it authorizes. The
  parameter values are restricted to the characters RFC 6750 allows inside
  a quoted string (`%x20-21 / %x23-5B / %x5D-7E`), so a verifier's error
  reason cannot break the header.

  Per-component scope requirements are the job of
  `Snodo.OAuth.ResourceServer.ScopePolicy`, which runs inside the router
  once the request is admitted. Its refusal is a JSON-RPC error inside a 200
  response, because the request itself was authenticated.

  ## Options

  | Option | Default | Meaning |
  |---|---|---|
  | `:resource` | required | The canonical resource URI; see `Snodo.OAuth.ResourceServer.resource!/1` |
  | `:verifier` | required | A `Snodo.OAuth.ResourceServer.Verifier` module, or `{module, options}` |
  | `:audience` | `[resource]` | Accepted `aud` values; compared with `Snodo.OAuth.ResourceServer.audience_match?/2` |
  | `:required_scopes` | `[]` | Scopes every request needs |
  | `:resource_metadata` | derived from `:resource` | The `resource_metadata` URL in challenges |
  | `:realm` | omitted | The `realm` parameter in challenges |
  | `:leeway` | 0 | Clock skew tolerated for `exp` and `nbf`, in seconds |
  | `:auth_assign` | `:mcp_auth` | The assign that receives the identity |
  """

  @behaviour Plug

  alias Plug.Conn
  alias Snodo.OAuth.ResourceServer

  @bearer ~r/\A[Bb][Ee][Aa][Rr][Ee][Rr]([ \t]|\z)/
  @token ~r/\A[Bb][Ee][Aa][Rr][Ee][Rr][ \t]+([A-Za-z0-9\-._~+\/]+=*)[ \t]*\z/
  @scope_token ~r/\A[\x21\x23-\x5B\x5D-\x7E]+\z/

  @impl true
  def init(opts) do
    resource = ResourceServer.resource!(required!(opts, :resource))

    %{
      verifier: verifier!(required!(opts, :verifier)),
      audience: audience!(Keyword.get(opts, :audience, [resource])),
      resource_metadata: string!(opts, :resource_metadata, ResourceServer.metadata_url(resource)),
      required_scopes: scopes!(Keyword.get(opts, :required_scopes, [])),
      realm: string!(opts, :realm, nil),
      leeway: leeway!(opts),
      auth_assign: assign!(opts)
    }
  end

  @impl true
  def call(%Conn{halted: true} = conn, _opts), do: conn

  def call(%Conn{} = conn, opts) do
    case token(conn) do
      {:ok, token} ->
        authenticate(conn, token, opts)

      {:error, :missing} ->
        refuse(conn, 401, nil, "A bearer token is required", opts)

      {:error, :malformed} ->
        refuse(conn, 400, "invalid_request", "The Authorization header is malformed", opts)

      {:error, :multiple} ->
        refuse(conn, 400, "invalid_request", "More than one Authorization header", opts)
    end
  end

  defp token(conn) do
    case Conn.get_req_header(conn, "authorization") do
      [] ->
        {:error, :missing}

      [value] ->
        cond do
          not Regex.match?(@bearer, value) -> {:error, :missing}
          match = Regex.run(@token, value) -> {:ok, Enum.at(match, 1)}
          true -> {:error, :malformed}
        end

      [_ | _] ->
        {:error, :multiple}
    end
  end

  defp authenticate(conn, token, %{verifier: {module, options}} = opts) do
    case module.verify(token, options) do
      {:ok, claims} when is_map(claims) ->
        admit(conn, claims, opts)

      {:error, reason} ->
        refuse(conn, 401, "invalid_token", "Token verification failed: " <> name(reason), opts)

      other ->
        raise ArgumentError,
              "#{inspect(module)}.verify/2 returned #{inspect(other)}; " <>
                "expected {:ok, claims} or {:error, reason}"
    end
  end

  defp admit(conn, claims, opts) do
    now = System.os_time(:second)

    with :ok <- check_expiry(claims["exp"], now, opts.leeway),
         :ok <- check_not_before(claims["nbf"], now, opts.leeway),
         :ok <- check_audience(claims["aud"], opts.audience),
         {:ok, scopes} <- granted_scopes(claims),
         :ok <- check_scopes(scopes, opts.required_scopes) do
      Conn.assign(conn, opts.auth_assign, %{
        principal: claims["sub"],
        client_id: claims["client_id"],
        scopes: scopes,
        claims: claims
      })
    else
      {:invalid_token, description} ->
        refuse(conn, 401, "invalid_token", description, opts)

      {:insufficient_scope, description} ->
        refuse(conn, 403, "insufficient_scope", description, opts)
    end
  end

  defp check_expiry(nil, _now, _leeway), do: :ok

  defp check_expiry(exp, now, leeway) when is_number(exp) do
    if now - leeway < exp, do: :ok, else: {:invalid_token, "The access token has expired"}
  end

  defp check_expiry(_exp, _now, _leeway), do: {:invalid_token, "The exp claim is not a number"}

  defp check_not_before(nil, _now, _leeway), do: :ok

  defp check_not_before(nbf, now, leeway) when is_number(nbf) do
    if nbf - leeway <= now, do: :ok, else: {:invalid_token, "The access token is not yet valid"}
  end

  defp check_not_before(_nbf, _now, _leeway),
    do: {:invalid_token, "The nbf claim is not a number"}

  defp check_audience(nil, _audience), do: {:invalid_token, "The access token has no audience"}

  defp check_audience(aud, audience) do
    if ResourceServer.audience_match?(aud, audience),
      do: :ok,
      else: {:invalid_token, "The access token was not issued for this resource"}
  end

  defp granted_scopes(claims) do
    case Map.get(claims, "scope", Map.get(claims, "scp")) do
      nil -> {:ok, []}
      scope when is_binary(scope) -> {:ok, String.split(scope, " ", trim: true)}
      scopes when is_list(scopes) -> scope_list(scopes)
      _other -> {:invalid_token, "The scope claim is malformed"}
    end
  end

  defp scope_list(scopes) do
    if Enum.all?(scopes, &is_binary/1),
      do: {:ok, scopes},
      else: {:invalid_token, "The scope claim is malformed"}
  end

  defp check_scopes(granted, required) do
    if required -- granted == [],
      do: :ok,
      else: {:insufficient_scope, "The access token lacks a required scope"}
  end

  defp refuse(conn, status, error, description, opts) do
    body =
      if error,
        do: %{"error" => error, "error_description" => description},
        else: %{"error_description" => description}

    conn
    |> Conn.put_resp_header("www-authenticate", challenge(opts, error, description))
    |> Conn.put_resp_content_type("application/json")
    |> Conn.send_resp(status, JSON.encode!(body))
    |> Conn.halt()
  end

  # RFC 6750 section 3: a challenge without authentication information
  # carries no error code, so it carries no description either.
  defp challenge(opts, error, description) do
    params = [
      {"realm", opts.realm},
      {"error", error},
      {"error_description", error && description},
      {"scope", scope_param(opts.required_scopes)},
      {"resource_metadata", opts.resource_metadata}
    ]

    "Bearer " <>
      (params
       |> Enum.reject(fn {_name, value} -> value in [nil, ""] end)
       |> Enum.map_join(", ", fn {name, value} -> name <> "=" <> quote_value(value) end))
  end

  defp scope_param([]), do: nil
  defp scope_param(scopes), do: Enum.join(scopes, " ")

  # Only the characters RFC 6750 allows in a quoted parameter value survive,
  # which makes escaping unnecessary and keeps the header a valid RFC 7235
  # quoted-string whatever a verifier or claim contained.
  defp quote_value(value) do
    kept =
      for <<c <- value>>, c in 0x20..0x21 or c in 0x23..0x5B or c in 0x5D..0x7E,
        into: "",
        do: <<c>>

    "\"" <> kept <> "\""
  end

  defp name(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp name(reason) when is_binary(reason), do: reason
  defp name(reason) when is_tuple(reason) and tuple_size(reason) > 0, do: name(elem(reason, 0))
  defp name(_reason), do: "unknown"

  defp required!(opts, key) do
    case Keyword.get(opts, key) do
      nil -> raise ArgumentError, "#{inspect(key)} is required"
      value -> value
    end
  end

  defp verifier!(module) when is_atom(module) and module != nil, do: {module, []}
  defp verifier!({module, options}) when is_atom(module) and module != nil, do: {module, options}

  defp verifier!(other) do
    raise ArgumentError, ":verifier must be a module or {module, options}, got: #{inspect(other)}"
  end

  defp audience!([_ | _] = audience) do
    if Enum.all?(audience, &is_binary/1),
      do: audience,
      else: raise(ArgumentError, ":audience must be a list of strings, got: #{inspect(audience)}")
  end

  defp audience!(other) do
    raise ArgumentError, ":audience must be a non-empty list of strings, got: #{inspect(other)}"
  end

  defp scopes!(scopes) when is_list(scopes) do
    Enum.each(scopes, fn scope ->
      unless is_binary(scope) and Regex.match?(@scope_token, scope) do
        raise ArgumentError, "scope must match the RFC 6749 scope-token syntax: #{inspect(scope)}"
      end
    end)

    scopes
  end

  defp scopes!(other) do
    raise ArgumentError, ":required_scopes must be a list of strings, got: #{inspect(other)}"
  end

  defp string!(opts, key, default) do
    case Keyword.get(opts, key, default) do
      nil -> nil
      value when is_binary(value) -> value
      other -> raise ArgumentError, "#{inspect(key)} must be a string, got: #{inspect(other)}"
    end
  end

  defp leeway!(opts) do
    case Keyword.get(opts, :leeway, 0) do
      leeway when is_integer(leeway) and leeway >= 0 ->
        leeway

      other ->
        raise ArgumentError, ":leeway must be a non-negative integer, got: #{inspect(other)}"
    end
  end

  defp assign!(opts) do
    case Keyword.get(opts, :auth_assign, :mcp_auth) do
      assign when is_atom(assign) and assign != nil -> assign
      other -> raise ArgumentError, ":auth_assign must be an atom, got: #{inspect(other)}"
    end
  end
end
