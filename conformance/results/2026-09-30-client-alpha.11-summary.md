# Frozen 2026-07-28 client conformance run

Run date: 2026-09-30  
Runner: `@modelcontextprotocol/conformance@0.2.0-alpha.11`  
Requirements SHA-256: `ae2f4f6210fd729e2e318edd5bbfa31a43cee0bc608e48052fa26dbf1d939b57`

## Exercised score

**31/32** required scenarios pass.
whole required scenarios with semantic success and no FAILURE, WARNING, or SKIPPED checks. The runner also attempts extension and pending scenarios separately.
Raw runner exit code: **0**. Regression gate: **pass**.
A passing regression gate does not mean full protocol conformance.

Required checks: 405 success, 0 failure, 2 skipped, 0 warning, 462 info.

## Passing required scenarios

- `tools_call`
- `request-metadata`
- `auth/metadata-default`
- `auth/metadata-var1`
- `auth/metadata-var2`
- `auth/metadata-var3`
- `auth/basic-cimd`
- `auth/scope-from-www-authenticate`
- `auth/scope-from-scopes-supported`
- `auth/scope-omitted-when-undefined`
- `auth/scope-step-up`
- `auth/scope-retry-limit`
- `auth/token-endpoint-auth-basic`
- `auth/token-endpoint-auth-post`
- `auth/token-endpoint-auth-none`
- `auth/pre-registration`
- `auth/resource-mismatch`
- `auth/offline-access-scope`
- `auth/offline-access-not-supported`
- `auth/authorization-server-migration`
- `auth/iss-supported`
- `auth/iss-not-advertised`
- `auth/iss-supported-missing`
- `auth/iss-wrong-issuer`
- `auth/iss-unexpected`
- `auth/iss-normalized`
- `auth/metadata-issuer-mismatch`
- `sep-2322-client-request-state`
- `http-custom-headers`
- `http-invalid-tool-headers`
- `json-schema-ref-no-deref`

## Remaining failing checks (including unscored lanes)

- `auth/enterprise-managed-authorization:complete-flow-token-exchange`
- `auth/enterprise-managed-authorization:complete-flow-jwt-bearer`
- `auth/dpop:sep-1932-client-token-request-proof`
- `auth/dpop:sep-1932-client-dpop-auth-scheme`
- `auth/dpop:sep-1932-client-fresh-proof`
- `auth/dpop-nonce:sep-1932-client-token-request-proof`
- `auth/dpop-nonce:sep-1932-client-dpop-auth-scheme`
- `auth/dpop-nonce:sep-1932-client-fresh-proof`
- `auth/dpop-nonce:sep-1932-client-as-nonce`
- `auth/dpop-nonce:sep-1932-client-rs-nonce`
- `auth/wif-jwt-bearer:wif-grant-type`

## Unscored scenarios

- `auth/client-credentials-jwt` (extension): 7 success, 0 failure, 0 skipped, 0 warning, 12 info
- `auth/client-credentials-basic` (extension): 7 success, 0 failure, 0 skipped, 0 warning, 12 info
- `auth/enterprise-managed-authorization` (extension): 16 success, 2 failure, 0 skipped, 0 warning, 20 info
- `auth/dpop` (extension): 0 success, 3 failure, 0 skipped, 0 warning, 4 info
- `auth/dpop-nonce` (extension): 0 success, 5 failure, 0 skipped, 0 warning, 4 info
- `auth/wif-jwt-bearer` (extension): 16 success, 1 failure, 0 skipped, 1 warning, 20 info
- `json-schema-2020-12-preservation` (added-after-release): 9 success, 0 failure, 0 skipped, 0 warning, 0 info

## Regression policy changes needed

Unexpected failures: 0; stale failure entries: 0; unexpected exclusions: 0; stale exclusions: 0; check status/inventory changes: 0.
See the JSON companion and raw check artifacts for exact outcomes. The baseline pins every check ID and status occurrence, including unscored scenarios. Missing, new, or changed checks require review; they never increase the exercised score.
