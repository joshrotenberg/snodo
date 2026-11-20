# Official TypeScript client acceptance

These checks use the unmodified `@modelcontextprotocol/client` package, at the
version pinned in `package.json`, and its locked transitive dependencies against compiled public framework APIs.
They pin protocol **2026-07-28**; passing them is not a claim of support for older
protocol versions or every current feature.

From the repository root:

```sh
ERL_FLAGS='+S 4:4' MIX_ENV=dev mix deps.get
ERL_FLAGS='+S 4:4' MIX_ENV=dev mix compile --warnings-as-errors
(cd integrations/oauth && mix deps.get && mix compile --warnings-as-errors)
npm --prefix interop/official_client ci --ignore-scripts
ERL_FLAGS='+S 4:4' npm --prefix interop/official_client run check
```

The client requires Node.js 20 or newer. CI pins
[Node.js 24.21.0 LTS](https://nodejs.org/en/blog/release/v24.21.0), Elixir 1.20, and
OTP 29. The compatibility workflow runs both checks as a failing gate and uploads
their output as `official-client-acceptance`, including on check failures.

`npm run check` runs these checks in order:

- `check:baseline`: stdio discovery, tool definition decoding, echo, cancellation,
  and a successful call after cancellation.
- `check:mrtr`: eight automatically retried workflows over both stdio and native
  Streamable HTTP. These cover tools, resources, prompts, signed state replacement
  and discard, fresh request IDs, changed-argument rejection, form elicitation,
  URL consent that does not imply external workflow completion, and the
  deprecated (SEP-2577) sampling and roots requests, alone and in one result
  next to a form, answered by the client's registered handlers.
- `check:progress`: progress notifications, cancellation, and MRTR, over stdio
  and native HTTP ([PROGRESS.md](PROGRESS.md)).
- `check:oauth`: a server protected by `snodo_oauth`, once over the native
  listener with `Snodo.OAuth.ResourceServer.Native` and once over `snodo_plug`
  on Bandit with the `Metadata` and `Bearer` plugs. `oauth_fixture.exs` also
  runs a loopback authorization server that issues ES256 JWT access tokens and
  serves the JWKS document the resource server fetches; the resource server
  holds no static keys. Over each transport the check covers the SDK's
  `WWW-Authenticate` parsing and protected resource metadata discovery, the
  authorization code flow through an `OAuthClientProvider` (dynamic client
  registration, PKCE `S256`, the `resource` parameter, `state`, `iss`, and
  `finishAuth`), the `client_credentials` grant through
  `ClientCredentialsProvider`, `tools/list` filtered by `ScopePolicy` and its
  `-32003` refusal of a tool that needs `mcp:write`, a refused token
  (401 `invalid_token`, `UnauthorizedError`), and a token without the endpoint
  scope (403 `insufficient_scope`, `InsufficientScopeError`).

Successful checks print JSON summaries. An assertion or process error fails the
command; the workflow does not suppress failures. MRTR fixtures bind HTTP to
loopback on an ephemeral port, stop on stdin EOF, and never open the elicitation
URL or make public service calls. The framework checks do not need a database or
the sibling application repository. Frozen external conformance scenarios live
in a separate [evidence lane](../../conformance/README.md).

Individual checks can be selected after changing to this directory:

```sh
npm run check:baseline
npm run check:mrtr -- --stdio
npm run check:mrtr -- --http
npm run check:oauth -- --native
npm run check:oauth -- --plug
```

`SNODO_ELIXIR` selects the Elixir executable. `SNODO_EBIN` overrides the default
`_build/dev/lib/snodo/ebin` directory. The OAuth fixture loads every
application under `integrations/oauth/_build/dev/lib`, or under
`$MIX_BUILD_PATH/lib` when `MIX_BUILD_PATH` is set; `SNODO_OAUTH_BUILD` overrides
that directory.

## Optional target-application acceptance

This optional check runs the real `hexpm-mcp` server callbacks with seeded
cache entries and loopback service URLs. It uses the pinned TypeScript client
and MCP `2026-07-28` over stdio and native Streamable HTTP. On each transport
it checks the 24-tool catalog across three pages, successful tool calls,
domain failures and invalid arguments, six prompt renders, two completions,
one automatically resumed review prompt, and five resource reads. The HTTP
check also verifies sessionless operation and fixture shutdown.

Build the target application in the Mix dev environment. The fixture defaults
to a sibling `hexpm-mcp` checkout. Set `HEXPM_MCP_PROJECT` to select another
checkout and `HEXPM_MCP_BUILD_PATH` if its build directory differs from
`_build/dev`. From the snodo repository root, run:

```sh
npm --prefix interop/official_client ci --ignore-scripts
npm --prefix interop/official_client run check:hexpm
```

Pass `-- --stdio` or `-- --http` to run one transport. The check is separate
from `npm run check` and CI because the application lives in a separate
repository. Its assertions cover the seeded loopback workflow.
