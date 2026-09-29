<!-- Title: a conventional commit, for example "fix: bound the stdio line reader". Mark breaking changes with "!". -->

## What and why

<!-- What changes, and why. For a draft, the plan. -->

Closes #

<!-- One keyword per issue: "Closes #12. Closes #13." -->

## Tests

<!-- New or changed tests, and what they would catch. -->

## Gates

- [ ] `mix quality`
- [ ] `MIX_ENV=test mix quality.types`
- [ ] `MIX_ENV=dev mix docs --warnings-as-errors`
- [ ] `mix compile && (cd interop/official_client && npm run check)`
- [ ] Transport or wire changes: conformance lanes and `interop/schema_validation` (see `conformance/AGENTS.md`, `interop/AGENTS.md`)
- [ ] `mix snodo.contract` still reports 32 evidence groups, or the change says why not

## Not addressed

<!-- Anything left for a follow-up, with issue links. Delete if none. -->
