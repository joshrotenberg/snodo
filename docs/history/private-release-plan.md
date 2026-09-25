# Private repository readiness plan

Status: planned, 2026-09-14. The user has chosen to keep the repository private
while preparing it for an eventual release. This document does not apply a
license, change repository settings, commit/push work, or authorize publication.

## Direction and boundaries

- Recommend **MIT for first-party framework code**. There is no mandatory
  Elixir license: [Elixir uses Apache-2.0](https://github.com/elixir-lang/elixir),
  while [Phoenix uses MIT](https://github.com/phoenixframework/phoenix/blob/main/LICENSE.md).
  MIT is the proposed default for the first implementation slice, not a claim
  that this currently unlicensed checkout has already been licensed.
- Keep GitHub private. An eventual license file and repository visibility are
  separate concerns. Do not add publishing credentials, public docs hosting,
  automatic package uploads, releases, tags, or deployment workflows.
- Keep the six existing packages and their inward dependency graph. No umbrella
  conversion, repository split, additional protocol features, or legacy-version
  support is required merely to make this repository ready.
- Keep the latest-only support profile, 32/37 frozen conformance score, and
  operational limits explicit. Repository readiness is not full conformance or
  production deployment readiness.

## Starting evidence

Local quality/type/client evidence is recorded in
[target application findings](target-application-findings.md). It includes
329 core tests, 148 target-application tests, and 21 default examples, but much
of the implementation remains uncommitted.

A read-only GitHub check on 2026-09-14 confirmed `joshrotenberg/snodo` is
**PRIVATE** with default branch `main`. The latest inspected
[Compatibility run](https://github.com/joshrotenberg/mcp_ex/actions/runs/34896871246)
at `d8155192891eb6bb70a2a7394bdd8bc30f2f311c` failed:

- Elixir 1.18 / OTP 27 rejected formatting in the PostgreSQL persistence module.
- Elixir 1.20 / OTP 29 hit SQLite `database is locked` in the concurrent event
  replay test; the type-analysis step therefore did not run.
- Elixir 1.19 / OTP 28 and PostgreSQL 14, 16, and 18 passed.

These results concern that older committed tree, not the current uncommitted
integration/progress changes. Reproduce and verify fixes; do not assume the
latest local pass resolves the remote failures.

## Slice 1: License and maintainer foundations

- Add the selected first-party license to the root and every eventual package
  archive. Preserve upstream licenses/provenance for vendored schema and
  conformance material; do not blanket-relicense third-party assets.
- Add an Unreleased changelog, contributor setup/check instructions, a security
  reporting policy with a real private contact route, and a maintainer checklist.
  Do not invent contact details, response guarantees, or contributor agreements.
- Explain the six packages, recommended application stack, supported protocol
  profile, private/unreleased status, and required local toolchain in the README.
- Keep community templates and a code of conduct lightweight; they must not
  delay the substantive validation work.

Done when licensing scope is unambiguous and a collaborator can set up and
verify the checkout using the repository's instructions alone.

## Slice 2: Reproducible private CI

- Establish one canonical formatter version; retain compilation, tests, and
  protocol checks across the supported BEAM matrix. Do not require different
  formatter versions to produce byte-identical output by accident.
- Diagnose the SQLite contention failure under the failing environment/seed.
  Preserve replay/fencing assertions; distinguish a harness synchronization or
  timeout problem from a store defect instead of hiding it with retries/skips.
- Review and commit the current framework work in coherent checkpoints, then
  run the complete compatibility and protocol workflows on the private remote.
  Record commit SHA, toolchains, job results, and evidence artifacts together.
- Add explicit job timeouts, workflow linting, deliberate artifact retention,
  action revision pinning, and dependency/advisory review. Keep unsuppressed
  advisories visible and distinguish runtime from development/test exposure.
- After stable green jobs exist, configure appropriate required checks on the
  private repository, subject to the account's available features. Do not
  introduce merge requirements that a solo maintainer cannot satisfy.
- Detect numbered duplicate BEAM artifacts and keep validation outputs outside
  interfering build/cache locations. The prior cleanup does not establish why
  those duplicates appeared or that the environment cannot recreate them.

Done when the current reviewed commit passes the supported private CI matrix,
not just the local current-runtime suite. No publishing job is part of this slice.

## Slice 3: Six explicit package contracts

- Retain `snodo`, `snodo_tasks`, `snodo_tasks_sqlite`,
  `snodo_tasks_postgres`, `snodo_plug`, and `snodo_jsv`.
- Keep versions coordinated for the initial release candidate and document the
  pre-1.0 compatibility policy. Existing `0.1.0` values are not proof of release;
  do not create a tag or claim Hex name availability without checking it.
- Add descriptions, license identifiers, source/homepage links, and explicit
  per-package file allowlists. Exclude PLTs, BEAMs, caches, databases, local
  reports, credentials, and unrelated sibling packages. In particular, do not
  package all of `priv/`: every package currently keeps PLTs under `priv/plts`.
- Separate checkout-only Mix tasks and example/test aliases from supported
  consumer tooling. Consumers must not need missing repository test fixtures,
  conformance manifests, or `../../examples` paths to compile/use the library.

Done when all six packages build locally and their archive manifests contain
only deliberate source, documentation, license, and required runtime assets.
[Hex build configuration](https://hex.hexdocs.pm/Mix.Tasks.Hex.Build.html) defines
the local-only build command and archive inclusion settings.

## Slice 4: Real dependency resolution and clean consumers

- Give internal dependencies version requirements suitable for the initial
  package series, with an explicit local-development path override. Do not base
  the choice solely on `Mix.env()`, since dependencies normally compile in prod.
- Keep ordinary monorepo development convenient while making extracted package
  `mix.exs` files independent of the original directory layout.
- Build archives locally and resolve them through an ephemeral
  [local signed Hex registry](https://hex.hexdocs.pm/Mix.Tasks.Hex.Registry.html).
  This tests actual package metadata and transitive dependencies without
  publishing packages or buying/configuring a hosted private registry.
- Build a fresh consumer outside this workspace, without its build caches or
  sibling checkout paths. Verify core-only runtime dependencies, the combined
  stack, optional-driver absence, and real SQLite/HTTP smoke tests with drivers.
- Exercise the supported minimum and current toolchains, production compilation,
  public APIs, stdio/HTTP client acceptance, and representative durable work.
  If the real `hexpm-mcp` port is added to CI, supply a versioned private input;
  do not push its local rewrite to a public remote merely to make CI convenient.

Done when distributable artifacts, rather than workspace paths, power a working
consumer. [Hex's publication guide](https://hex.pm/docs/publish) documents the
metadata/dependency requirements; no publication command is needed for this plan.

## Slice 5: Documentation and discoverable examples

- Add ExDoc as development-only tooling and generate all six packages' docs
  locally or as private CI artifacts. Validate module, source, and guide links.
- Provide a short installation/composition guide, feature/support matrix, and
  links to the focused examples. Keep historical spike notes separate from
  current application-author guidance.
- Include authentication ownership, cancellation/timeout behavior, schema policy,
  durable recovery/retention, and upgrade/migration responsibilities where useful.
- Verify documentation and selected examples from the clean consumer as well
  as the monorepo. Do not publish docs to HexDocs or GitHub Pages.

Done when someone new can choose packages and run the supported workflows
without reading private implementation modules or this conversation.

## Slice 6: Private release rehearsal and stop point

- Produce a release checklist and reproducible verification command covering
  local gates, private CI, docs, archive inspection, and clean-consumer acceptance.
- Audit source/history and artifacts for secrets, personal paths, unintended
  binaries, missing notices, and stale readiness claims before wider sharing.
- Retain versioned release notes, archive hashes, exact dependency versions, and
  the tested protocol/client/runtime profile as private evidence.
- Keep all public actions as a separate, explicitly approved future step:
  visibility changes, Hex publication, public docs, release tags, and deployment.

Private-ready means another authorized collaborator can clone, test, document,
package, and run this project reproducibly. It does not mean any package has
been published, any deployment is approved, or all MCP features are implemented.

## First implementation slice

Start with license/maintainer foundations and the two observed CI failures.
Then add package metadata plus archive allowlists before touching dependency
distribution. This yields a reviewed private baseline and prevents accidental
artifact leakage while the standalone-consumer workflow is built.
