Claude Code 2.1.273 and Codex 0.149.0 cannot initialize against PR #1: their native HTTP clients request 2025-11-25 and 2025-06-18 respectively, while only 2026-07-28 is implemented. Both failures were reproduced without model inference against an isolated loopback server.

Implement explicitly enabled initialize-era HTTP dialects alongside the existing 2026 profile. Preserve the default 2026-only configuration and use stateless HTTP first, with no invented session IDs or session manager. Cover initialize/initialized/ping, tools, prompts, fixed and template resources, pagination, result/error projection, mixed-version routing, auth isolation and cancellation boundaries. Do not advertise unsupported server-initiated features.

Acceptance: exact June/November handshakes and HTTP lifecycle tests; native discovery, a harmless native tool call and resources where the client supports them; existing 2026 regressions; project quality and type gates with the inherited SQLite Tasks failure reported honestly. Keep Tasks unchanged.

Implementation is stacked on PR #1's exact head 4a98d8393da586c039c173cfb80b07fcbc2ba961. No merge or public Custode migration is authorized as part of this issue. The owner explicitly confirmed that mcp_ex remains private; do not publish source or packages.
