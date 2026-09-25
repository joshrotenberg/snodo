# Pre-release support profile and release gates

The next stage is the [private repository readiness plan](private-release-plan.md).
The user has chosen to keep the repository private; MIT is the recommended
first-party license for the upcoming foundations slice. That plan also records
the subsequently inspected remote CI results, separate from the local checkpoint
below. No license file or repository setting was changed by writing the plan.

This is the latest-only **2026-07-28** application slice. Package versions still
read `0.1.0`; that is development metadata, not an announcement of a published
release or a compatibility promise.

## Supported composition

- Synchronous protocol core with no runtime Hex dependencies.
- Tools, Resources, Prompts, completion, shared catalog pagination/cache hints,
  ordinary form/URL MRTR, and request progress.
- Stdio, native Streamable HTTP, and optional Plug/Bandit application integration.
- Application-owned subscription source or bounded Hub; exact-versioned Tasks
  can add authorized status subscriptions without changing the core profile.
- Optional JSV schema validation and optional SQLite/PostgreSQL Tasks storage.

The [recommended stack](../../guides/application-stack.md) records ownership and operational
limits. The [protocol evidence](../../guides/protocol-compliance.md) is the authoritative
claim boundary: 32/37 frozen required scenarios pass, not full conformance.
Official-client 2.0.0 acceptance is not a claim for every host or older MCP era.

## Local checkpoint: 2026-09-14

All six package quality and type gates pass on Elixir 1.20.4 / OTP 29.0.6:
329 core tests, 85 Tasks tests, nine database-independent PostgreSQL tests,
19 SQLite tests, 17 Plug/Bandit tests, 29 JSV tests, and 21 default examples.
The live PostgreSQL lane is excluded from this local gate. The target application
passes 148 tests, strict Credo, Dialyzer, and its offline durable-audit example.

Official-client baseline/MRTR/progress/application checks and independent AJV
wire validation pass. The frozen runner remains partial at 32/37; its exact
190-check regression inventory passes without waiving any failures. Workflow
syntax passes actionlint, but remote CI has not run in this slice. These are
uncommitted local-checkout results, not release or deployment evidence. See
[verification details and build-artifact cleanup](target-application-findings.md#verification--2026-09-14).

## Gates before distributing packages

1. Run the complete local quality/type/example, independent schema, client, and
   strict frozen-runner lanes against the same final commit. Retain raw artifacts.
2. Run the checked-in minimum/intermediate/current BEAM and PostgreSQL matrix on
   the private remote. A workflow file and a local current-version pass do not
   establish the other jobs have run.
3. Choose the license and distribution policy. No framework license file is
   currently present, and the repository is private. Do not infer MIT/public
   publication from the separate target application's existing license.
4. Confirm package/version naming for the six independently composed packages;
   replace local path dependencies with a deliberate publishable dependency
   policy. Add package manifests, source/documentation links, release notes, and
   verify dry-run archives contain only intended source/docs/license files.
5. Build a clean consumer application from the intended distributable artifacts,
   not sibling checkouts. Re-run application acceptance and confirm the exact
   supported client/version profile in its installation documentation.

## Gates before deploying the target application

- Decide native HTTP versus the optional Plug/Bandit host and install a real
  authentication pipeline. Loopback fixture auth is not deployment auth.
- Provision SQLite/Repo/migrations explicitly if enabling durable audits; define
  tenant identity, storage location, backup/retention, and recovery expectations.
- Re-audit production dependencies and review retained development-only
  advisories. See the target's dependency audit; do not suppress a nonzero audit
  to obtain a green release badge.
- Verify TLS/proxy/origin configuration, connection/write/execution limits,
  shutdown behavior, and operational load/soak for the selected deployment.
- Validate any additional host independently. The published Hex.pm application,
  binaries, and public endpoint are not automatically updated by this local port.

No public release, tag, package upload, deployment, or upstream issue/PR is
authorized merely by completing this checklist. Private preparation is the
selected direction; implementation can keep using path dependencies until the
planned distributable dependency strategy has been tested. Public distribution
requires a separate explicit decision.
