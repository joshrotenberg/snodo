# OAuth 2.1 for snodo

`snodo_oauth` implements both sides of the
[MCP authorization specification](https://modelcontextprotocol.io/specification/2026-07-28/basic/authorization).

For servers that run behind `snodo_plug`, the resource-server side: the
protected resource metadata document (RFC 9728), bearer token extraction and
validation with audience binding (RFC 8707), the `WWW-Authenticate` challenges
that point a client at the metadata, and a `Snodo.Authorization` policy that
requires scopes per tool, prompt, or resource.

For `Snodo.Client`, the [client side](#client): `Snodo.OAuth.Client` obtains,
refreshes, and steps up the bearer token the HTTP transport sends, through
metadata discovery, client ID metadata documents or dynamic client
registration, the authorization code flow with PKCE, and the client
credentials grant.

It depends on `plug` and `jose`; the `snodo` core stays free of Hex
dependencies. It does not implement the authorization server, token
introspection (RFC 7662), DPoP (RFC 9449), or CORS. The native HTTP listener
in the core sets no identity and is not covered by this package.

## Install

<!-- x-release-please-start-version -->
```elixir
{:snodo_plug, "~> 0.3.1"},
{:snodo_oauth, "~> 0.3.1"},
{:bandit, "~> 1.12"}
```
<!-- x-release-please-end -->

## How the pieces fit

| Module | Role |
|---|---|
| `Snodo.OAuth.ResourceServer.Metadata` | A plug serving the RFC 9728 document at `/.well-known/oauth-protected-resource` or, for a resource with a path, at `/.well-known/oauth-protected-resource/<path>` |
| `Snodo.OAuth.ResourceServer.Bearer` | A plug that requires a valid bearer token on every request, sets the `:mcp_auth` assign that `Snodo.Transport.Plug` trusts, and answers 400, 401, and 403 with a `WWW-Authenticate` challenge |
| `Snodo.OAuth.ResourceServer.Verifier` | The token verification behaviour |
| `Snodo.OAuth.ResourceServer.Verifier.JWT` | Verifies JWT access tokens (RFC 9068) with `jose` |
| `Snodo.OAuth.ResourceServer.JWKS` | A supervised key cache: static keys, a JWKS URL, or both |
| `Snodo.OAuth.ResourceServer.ScopePolicy` | A `Snodo.Authorization` policy comparing granted scopes with the scopes each component requires |

The order in a pipeline is metadata, bearer, transport. The metadata plug
answers its own path and passes everything else on; the bearer plug halts
any other request that lacks a valid token; the transport reads identity
from the assign only.

`resource` is the canonical URI of the MCP server, the value clients send as
the RFC 8707 `resource` parameter and authorization servers put in the
token's `aud` claim: `https://mcp.example.com/mcp`, with a lowercase scheme
and host and no trailing slash unless it is part of the path.

## Bandit

Start a key cache and an executor in the supervision tree, and compose the
three plugs in a small endpoint module:

```elixir
defmodule MyApp.MCPEndpoint do
  @behaviour Plug

  alias Snodo.OAuth.ResourceServer.Bearer
  alias Snodo.OAuth.ResourceServer.Metadata
  alias Snodo.OAuth.ResourceServer.Verifier.JWT

  @resource "https://mcp.example.com/mcp"
  @issuer "https://auth.example.com"

  @impl true
  def init(opts) do
    %{
      metadata:
        Metadata.init(
          resource: @resource,
          authorization_servers: [@issuer],
          scopes_supported: ["mcp:read", "mcp:write"]
        ),
      bearer:
        Bearer.init(
          resource: @resource,
          verifier: {JWT, keys: MyApp.JWKS, issuer: @issuer},
          required_scopes: ["mcp:read"]
        ),
      transport: Snodo.Transport.Plug.init(opts)
    }
  end

  @impl true
  def call(conn, plugs) do
    conn
    |> Metadata.call(plugs.metadata)
    |> Bearer.call(plugs.bearer)
    |> Snodo.Transport.Plug.call(plugs.transport)
  end
end
```

```elixir
children = [
  {Snodo.OAuth.ResourceServer.JWKS,
   name: MyApp.JWKS, url: "https://auth.example.com/.well-known/jwks.json"},
  {Snodo.Server.Executor, name: MyApp.SnodoExecutor, max_concurrency: 32, max_queue: 128},
  {Bandit,
   plug: {MyApp.MCPEndpoint, runtime: MyApp.MCPServer.runtime(), executor: MyApp.SnodoExecutor},
   ip: {0, 0, 0, 0},
   port: 4000,
   thousand_island_options: [transport_options: [send_timeout: 5_000, send_timeout_close: true]]}
]
```

Each plug halts the connection it answers, and each `call/2` passes a halted
connection through, so the chain needs no `Plug.Builder`. The transport
options are the ones `snodo_plug` documents.

## Phoenix

Serve the document as a route outside the MCP pipeline and put the bearer
plug in the pipeline that forwards to the transport:

```elixir
pipeline :mcp do
  plug Snodo.OAuth.ResourceServer.Bearer,
    resource: "https://mcp.example.com/mcp",
    verifier:
      {Snodo.OAuth.ResourceServer.Verifier.JWT,
       keys: MyApp.JWKS, issuer: "https://auth.example.com"},
    required_scopes: ["mcp:read"]
end

scope "/" do
  get "/.well-known/oauth-protected-resource/mcp", Snodo.OAuth.ResourceServer.Metadata,
    resource: "https://mcp.example.com/mcp",
    authorization_servers: ["https://auth.example.com"],
    scopes_supported: ["mcp:read", "mcp:write"]

  pipe_through :mcp

  forward "/mcp", Snodo.Transport.Plug,
    runtime: MyApp.MCPServer.runtime(),
    executor: MyApp.SnodoExecutor,
    path: "/mcp"
end
```

The route path must equal the path the metadata plug derives from
`resource:` (or its `path:` option), since the plug also compares
`conn.request_path`. Keep `Plug.Parsers` away from `/mcp`, as the
[transports guide](https://hexdocs.pm/snodo/transports.html#phoenix-endpoint)
describes.

## Scopes per component

Endpoint-level scopes (`required_scopes:` on the bearer plug) are checked
before the transport and refused with `403` and
`WWW-Authenticate: Bearer error="insufficient_scope", scope="..."`. Scopes
that differ per tool, prompt, or resource go on the runtime as a
`Snodo.Authorization` policy:

```elixir
defmodule MyApp.MCPServer do
  use Snodo.Server,
    name: "my-server",
    version: "1.0.0",
    authorization:
      {Snodo.OAuth.ResourceServer.ScopePolicy,
       required: %{
         {:tool, "publish_package"} => ["packages:write"],
         {:resource, "release_notes"} => ["packages:read"]
       },
       default: ["mcp:read"]}
end
```

`tools/list`, `prompts/list`, and the resource lists then contain only the
components whose scopes the token holds. A call without them is refused
before argument validation with the policy's own JSON-RPC error inside an
HTTP 200, because the request itself was authenticated:

```json
{"code": -32003, "message": "Insufficient scope for tool publish_package",
 "data": {"error": "insufficient_scope", "scope": "packages:write"}}
```

The data mirrors the parameters of an RFC 6750 `insufficient_scope`
challenge, so a client can start a step-up authorization with that scope.
An HTTP-level 403 for a specific tool would need the transport to know the
tool before it reads the body; `snodo_plug` keeps HTTP admission and
per-component policy separate, as its README explains.

## What the bearer plug checks

| Check | Result |
|---|---|
| No `Authorization` header, or another scheme | 401, `Bearer resource_metadata="..."`, and `scope="..."` when the endpoint requires scopes |
| Malformed token, or more than one `Authorization` header | 400 `invalid_request` |
| The verifier refuses the token | 401 `invalid_token`, with the reason's name in `error_description` |
| `exp` has passed, or `nbf` has not arrived, beyond `:leeway` | 401 `invalid_token` |
| `aud` is missing or names none of `:audience` | 401 `invalid_token` |
| A scope in `:required_scopes` is not granted | 403 `insufficient_scope` with `scope="..."` |

A request that passes carries `conn.assigns.mcp_auth`:

```elixir
%{principal: claims["sub"], client_id: claims["client_id"],
  scopes: ["mcp:read"], claims: claims}
```

`scopes` comes from the `scope` claim (a space-separated string) or an
`scp` list. The raw token is not in the assign: an MCP server must not
forward the token it received to another service. Every parameter value in
a challenge is reduced to the characters RFC 6750 allows in a quoted string,
so a verifier reason or a claim cannot break the header.

## Verification and keys

`Snodo.OAuth.ResourceServer.Verifier.JWT` accepts RSA, ECDSA, and EdDSA
signatures by default, never `alg: none`, and requires `iss` to equal a
configured issuer and `exp` to be present. HMAC algorithms can be listed
explicitly for a static `oct` key.

`Snodo.OAuth.ResourceServer.JWKS` fetches the document lazily, refreshes it
after `:ttl_ms` (one hour), refreshes on a token whose `kid` is unknown,
and never fetches more often than `:min_refresh_ms` (one minute), so an
unknown `kid` cannot turn the cache into a request amplifier. A document is
capped at `:max_keys` (32) signature keys. The default fetch uses `:httpc`
over TLS with peer verification against the operating system trust store;
plain `http` is accepted only for loopback hosts. A `:fetch` function
replaces it, which is how the tests run without a network. Static keys
(`keys:`, as JWK maps, PEM strings, `%JOSE.JWK{}` structs, or `{kid, key}`
tuples) are kept across refreshes and can stand alone without a URL.

Another verifier implements `Snodo.OAuth.ResourceServer.Verifier` with one
function, `verify(token, options)`, returning `{:ok, claims}` with string
keys or `{:error, reason}`. The lifetime, audience, and scope checks stay in
the plug, so they apply to every verifier.

## Client

`Snodo.OAuth.Client` is a `Snodo.Client.TokenProvider`. Start one per MCP
server and pass it to `Snodo.Client.connect/2`:

```elixir
{:ok, oauth} =
  Snodo.OAuth.Client.start_link(
    resource: "https://mcp.example.com/mcp",
    authorize: fn url ->
      {_output, 0} = System.cmd("open", [url])
      :ok
    end
  )

{:ok, client} =
  Snodo.Client.connect({:http, "https://mcp.example.com/mcp"},
    token_provider: {Snodo.OAuth.Client, oauth}
  )

{:ok, tools} = Snodo.Client.list_tools(client)
```

The first request goes out without a token. The server's `401` carries a
`WWW-Authenticate` challenge, the transport hands it to the client process,
and the flow runs:

1. The protected resource metadata (RFC 9728) from the challenge's
   `resource_metadata` URL or the well-known locations, checked to be for
   this server. A document for another resource stops the flow.
2. The authorization server metadata (RFC 8414, then OpenID Connect
   Discovery, with the well-known segment inserted before an issuer path)
   for the first `authorization_servers` entry. The document's `issuer` must
   equal the issuer used to build the URL.
3. A client ID: the `:client_metadata_url` when the server supports client
   ID metadata documents, else the configured `:client_id`, else the
   registration stored for this issuer, else dynamic client registration
   (RFC 7591) with `application_type`, `redirect_uris`, and
   `grant_types` including `refresh_token`.
4. The scope: the challenge's `scope`, else the resource's
   `scopes_supported`, plus scopes granted before, the configured `:scopes`,
   and `offline_access` when the server lists it (SEP-2207).
5. The authorization request with PKCE `S256`, a random `state`, and the
   `resource` (RFC 8707), handed to the `:authorize` function. The redirect
   lands on a loopback listener bound before the URL exists (RFC 8252), or
   the function returns it, or the application delivers it with
   `Snodo.OAuth.Client.callback/2` for a `{:external, uri}` redirect. `state`
   is compared in constant time; `iss` is compared exactly when present and
   required when the server advertises it (RFC 9207).
6. The token request, authenticated as the registration or the server
   requires: `none`, `client_secret_basic`, `client_secret_post`, or
   `private_key_jwt`. Only bearer tokens are accepted.

The transport retries the request with the token. Later requests carry it.
An expired token is refreshed with its refresh token before the request; a
refused one starts the flow again after the `401`, with a new registration
when the resource now names another authorization server (SEP-2352); a
`403` `insufficient_scope` starts a step-up for the union of the granted and
the challenged scopes, and is refused when the challenge names nothing the
token lacks, which bounds a server that answers every request with `403`.
Every caller that needs a token while a flow is under way waits for it.

For machine-to-machine clients, `grant: :client_credentials` with
`client_id:` and `client_secret:` (sent as `client_secret_basic` or
`client_secret_post`, whichever the server lists) or `private_key:` (a PEM
string, JWK map, or `JOSE.JWK`, sent as a `private_key_jwt` assertion signed
with the algorithm the key implies) obtains the token before the first
request.

| Module | Role |
|---|---|
| `Snodo.OAuth.Client` | The token provider: one process per server, which runs each flow in a process of its own and holds the stores |
| `Snodo.OAuth.Client.Discovery` | Protected resource and authorization server metadata with the resource and issuer checks |
| `Snodo.OAuth.Client.PKCE` | `S256` verifiers and challenges (RFC 7636) |
| `Snodo.OAuth.Client.TokenStore`, `Snodo.OAuth.Client.RegistrationStore`, `Snodo.OAuth.Client.PendingAuthorizationStore` | Store behaviours; each has an in-memory default under `.Memory` |

Every URL the flow fetches or posts to must be `https`, or `http` to a
loopback host. Documents and token responses are read up to
`max_body_bytes` (256 KiB). Tokens are kept in the token store and never
logged or placed in an error. `Snodo.OAuth.Client` documents every option.

Against the official conformance runner's client scenarios, every required
`auth/*` scenario passes with this client as the token provider; see the
[conformance workspace](../../conformance/README.md#client-leg). DPoP,
enterprise-managed authorization, and workload identity federation are not
implemented.

## Verification

```sh
cd integrations/oauth
mix deps.get
mix quality
mix quality.types
```

The tests generate RSA, EC, and Ed25519 keys with `jose` and never reach the
network. They cover the metadata document at the root and under a prefix,
every bearer plug outcome and its challenge, JWT verification including
tampering, algorithm confusion, and key rotation through a refresh, the
cache bounds and rate limit, the default fetch against a loopback Bandit
listener, the scope policy through `Snodo.Client.direct/2`, and a full
request path through `snodo_plug` on Bandit: 401 with the metadata URL,
403 `insufficient_scope`, `tools/list` filtered by scope, and a refused
`tools/call`.

The client is tested through `Snodo.Client` against fake authorization and
resource servers on loopback Bandit listeners shaped like the conformance
runner's: discovery at every metadata location, the resource and issuer
checks, each way of establishing a client ID, each token endpoint
authentication method including a verified `private_key_jwt` assertion,
scope selection, step-up and its bound, refresh, re-registration after an
authorization server change, the `iss` cases, the loopback listener and an
external redirect, `state` mismatch, and concurrent callers sharing one flow.
