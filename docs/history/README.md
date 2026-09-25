# Project history

Dated records from the architecture spike through the first application port.
They are kept as written. Module and package names were updated by the snodo
rename, and some statements, test counts, and scores are out of date. The
[guides](../../guides) describe the library as it is now.

| Record | What it is |
|---|---|
| [spike-findings.md](spike-findings.md) | Outcome of the Phase 0 to 2 spike: router, dialect admission, stdio concurrency, and the deferrals chosen |
| [application-readiness-plan.md](application-readiness-plan.md) | The plan for building real applications on the `2026-07-28` protocol, with `hexpm-mcp` as the first target |
| [target-application-findings.md](target-application-findings.md) | What porting `hexpm-mcp` exposed, and the fixes that followed |
| [examples-roadmap.md](examples-roadmap.md) | The ordered plan and status for the numbered examples |
| [static-analysis-plan.md](static-analysis-plan.md) | How Credo and Dialyzer were introduced as gates for all six packages |
| [release-readiness.md](release-readiness.md) | The pre-release support profile and release gates as of mid-September 2026 |
| [private-release-plan.md](private-release-plan.md) | Preparing the private repository for an eventual release (2026-09-14) |
| [where-to-next.md](where-to-next.md) | An outside assessment of the codebase and priorities (2026-09-18), with a second model's review appended |
| [backlog.md](backlog.md) | The eight backlog items distilled from that assessment, with status through 2026-09-25 |

Every backlog item is done: the Plug adapter, JSON Schema backend, and CI
(#1), initialize-era HTTP clients (#4), `Snodo.Client` and its transports (#8,
#9), and the ergonomics layer (#10). The repository was renamed from `mcp_ex`
to `snodo` in #11.
