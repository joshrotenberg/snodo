# Official TypeScript client acceptance

These checks use the unmodified `@modelcontextprotocol/client` **2.0.0** package
and its locked transitive dependencies against compiled public framework APIs.
They pin protocol **2026-07-28**; passing them is not a claim of support for older
protocol versions or every current feature.

From the repository root:

```sh
ERL_FLAGS='+S 4:4' MIX_ENV=dev mix deps.get
ERL_FLAGS='+S 4:4' MIX_ENV=dev mix compile --warnings-as-errors
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
- `check:mrtr`: five automatically retried workflows over both stdio and native
  Streamable HTTP. These cover tools, resources, prompts, signed state replacement
  and discard, fresh request IDs, changed-argument rejection, form elicitation,
  and URL consent that does not imply external workflow completion.

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
```

`SNODO_ELIXIR` selects the Elixir executable. `SNODO_EBIN` overrides the default
`_build/dev/lib/snodo/ebin` directory.

## Optional target-application acceptance

`npm run check:hexpm` runs the separate `hexpm-mcp` application over stdio and
HTTP. It is intentionally excluded from `check` and CI because that application
is not part of this repository. It needs a compiled sibling checkout, or an
explicit `HEXPM_MCP_PROJECT`; `HEXPM_MCP_BUILD_PATH` selects its Mix build tree.
The fixture uses seeded data and redirects upstream service URLs to an unused
loopback port, so it does not call public Hex.pm services.
