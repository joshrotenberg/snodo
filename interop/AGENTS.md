# AGENTS.md: interop

Two independent checks against pinned third-party code. Each directory has a README with details. The root [AGENTS.md](../AGENTS.md) applies here too.

## official_client

The unmodified official TypeScript client (`@modelcontextprotocol/client`, version pinned in `official_client/package.json`) against snodo servers over stdio and HTTP. It is part of the gates in the root `AGENTS.md`.

```sh
mix compile
cd interop/official_client
npm ci --ignore-scripts
npm run check             # check.mjs, check_mrtr.mjs, check_progress.mjs
```

The `*_fixture.exs` files are the servers under test. A change to wire shapes, transports, MRTR, or progress should keep all three scripts passing. `check_hexpm.mjs` exercises a separate consumer and is not part of `npm run check`.

## schema_validation

Validates messages the real server emits against the official JSON Schema for 2026-07-28 with AJV (draft 2020-12), plus negative controls that must fail. Run it when a change affects anything on the wire.

```sh
ERL_FLAGS='+S 4:4' mix compile --warnings-as-errors
cd interop/schema_validation
npm ci --ignore-scripts --no-audit --no-fund
npm run check
```

`schema.json` and `provenance.json` record the pinned schema and where it came from. The operations in the corpus are driven from `check.mjs` against the server in `fixture.exs`. When the server gains a new message shape, add an operation that emits it, so it is validated along with its negative control.

## Rules

- Install with `npm ci --ignore-scripts`. Do not run `npm install`, and do not add packages without a reviewed lockfile change.
- Do not modify the pinned client or schema to make a check pass. A failing check means snodo's output, or the check, needs a reviewed change.
