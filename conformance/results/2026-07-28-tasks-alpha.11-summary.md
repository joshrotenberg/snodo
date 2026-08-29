# Tasks extension conformance probe

This is a visibility run for the released `io.modelcontextprotocol/tasks`
extension against the frozen
`@modelcontextprotocol/conformance@0.2.0-alpha.11` runner. Tasks is extension
evidence; it is not part of the frozen 37-scenario core score for MCP
`2026-07-28`.

## Result

- All **35/35 Tasks-specific assertions passed**.
- The runner's one notification check was skipped by the upstream scenario
  pending its `subscriptions/listen` rewrite.
- One generic wire-schema check passed and eight failed.
- The runner exited non-zero, so this is not reported as a whole-scenario pass.

The eight failures all have the same cause: the frozen generic schema validator
checks a task-creating `tools/call` response as the core `CallToolResult`, which
requires `content`. The released Tasks extension instead defines that response
as a flat `CreateTaskResult` with `resultType: "task"`. The Tasks-specific
assertions accept and validate that extension wire shape. We preserve both facts
rather than suppressing the generic failures.

| Scenario | Tasks assertions | Generic wire schema |
|---|---:|---|
| `tasks-lifecycle` | 8/8 | failure |
| `tasks-capability-negotiation` | 4/4 | failure |
| `tasks-wire-fields` | 3/3 | failure |
| `tasks-request-state-removal` | 2/2 | failure |
| `tasks-mrtr-input` | 3/3 | failure |
| `tasks-request-headers` | 4/4 | failure |
| `tasks-dispatch-and-envelope` | 8/8 | failure |
| `tasks-status-notifications` | 1 skipped | not run |
| `tasks-required-task-error` | 2/2 | success |
| `tasks-mrtr-composition` | 1/1 | failure |

## Pinned inputs

- Tasks specification and schema: commit
  `0d0a6bd4c258b35caa3c810a1dd506cf105b1501`
- Conformance scenarios: commit
  `c321dd32035556e6769d3724a8ee97d87c3faaac`
- Runner: `@modelcontextprotocol/conformance@0.2.0-alpha.11`
- Run began: `2026-08-25T03:43:27Z`

The machine-readable companion is
[`2026-07-28-tasks-alpha.11-summary.json`](2026-07-28-tasks-alpha.11-summary.json).
