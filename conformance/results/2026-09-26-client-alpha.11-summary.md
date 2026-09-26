# Frozen 2026-07-28 client conformance run

Run date: 2026-09-26  
Runner: `@modelcontextprotocol/conformance@0.2.0-alpha.11`  
Requirements SHA-256: `ae2f4f6210fd729e2e318edd5bbfa31a43cee0bc608e48052fa26dbf1d939b57`

## Exercised score

**6/32** required scenarios pass.
whole required scenarios with semantic success and no FAILURE, WARNING, or SKIPPED checks. The runner also attempts extension and pending scenarios separately.
Raw runner exit code: **1**. Regression gate: **pass**.
A passing regression gate does not mean full protocol conformance.

Required checks: 54 success, 46 failure, 4 skipped, 1 warning, 1 info.

## Passing required scenarios

- `tools_call`
- `auth/resource-mismatch`
- `sep-2322-client-request-state`
- `http-custom-headers`
- `http-invalid-tool-headers`
- `json-schema-ref-no-deref`

## Remaining failing checks (including unscored lanes)

- `auth/metadata-default:prm-pathbased-requested`
- `auth/metadata-default:authorization-server-metadata`
- `auth/metadata-default:client-registration`
- `auth/metadata-default:authorization-request`
- `auth/metadata-default:token-request`
- `auth/metadata-var1:prm-pathbased-requested`
- `auth/metadata-var1:authorization-server-metadata`
- `auth/metadata-var1:client-registration`
- `auth/metadata-var1:authorization-request`
- `auth/metadata-var1:token-request`
- `auth/metadata-var2:authorization-server-metadata`
- `auth/metadata-var2:client-registration`
- `auth/metadata-var2:authorization-request`
- `auth/metadata-var2:token-request`
- `auth/metadata-var3:authorization-server-metadata`
- `auth/metadata-var3:client-registration`
- `auth/metadata-var3:authorization-request`
- `auth/metadata-var3:token-request`
- `auth/basic-cimd:cimd-client-id-used`
- `auth/scope-from-www-authenticate:scope-from-www-authenticate`
- `auth/scope-from-scopes-supported:scope-from-scopes-supported`
- `auth/scope-omitted-when-undefined:scope-omitted-when-undefined`
- `auth/scope-step-up:scope-step-up-initial`
- `auth/scope-step-up:scope-step-up-escalation`
- `auth/scope-step-up:sep-2350-scope-union-on-reauth`
- `auth/scope-retry-limit:scope-retry-limit`
- `auth/token-endpoint-auth-basic:token-endpoint-auth-method`
- `auth/token-endpoint-auth-basic:resource-parameter-in-authorization`
- `auth/token-endpoint-auth-basic:resource-parameter-in-token`
- `auth/token-endpoint-auth-post:token-endpoint-auth-method`
- `auth/token-endpoint-auth-post:resource-parameter-in-authorization`
- `auth/token-endpoint-auth-post:resource-parameter-in-token`
- `auth/token-endpoint-auth-none:token-endpoint-auth-method`
- `auth/token-endpoint-auth-none:resource-parameter-in-authorization`
- `auth/token-endpoint-auth-none:resource-parameter-in-token`
- `auth/pre-registration:pre-registration-auth`
- `auth/offline-access-scope:sep-2207-offline-access-requested`
- `auth/offline-access-not-supported:sep-2207-offline-access-not-requested`
- `auth/authorization-server-migration:sep-2352-reregister-on-as-change`
- `auth/iss-supported:sep-2468-client-compare-iss-supported`
- `auth/iss-not-advertised:sep-2468-client-proceed-no-iss`
- `auth/iss-supported-missing:sep-2468-client-reject-missing-iss`
- `auth/iss-wrong-issuer:sep-2468-client-compare-iss-supported`
- `auth/iss-unexpected:sep-2468-client-compare-iss-unadvertised`
- `auth/iss-normalized:sep-2468-client-no-normalization`
- `auth/metadata-issuer-mismatch:sep-2468-client-validate-metadata-issuer`
- `auth/client-credentials-jwt:client-credentials-jwt-verified`
- `auth/client-credentials-basic:client-credentials-basic-auth`
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
- `auth/wif-jwt-bearer:wif-assertion-verified`

## Unscored scenarios

- `auth/client-credentials-jwt` (extension): 0 success, 1 failure, 0 skipped, 0 warning, 0 info
- `auth/client-credentials-basic` (extension): 0 success, 1 failure, 0 skipped, 0 warning, 0 info
- `auth/enterprise-managed-authorization` (extension): 0 success, 2 failure, 0 skipped, 0 warning, 0 info
- `auth/dpop` (extension): 0 success, 3 failure, 0 skipped, 0 warning, 0 info
- `auth/dpop-nonce` (extension): 0 success, 5 failure, 0 skipped, 0 warning, 0 info
- `auth/wif-jwt-bearer` (extension): 0 success, 1 failure, 0 skipped, 0 warning, 0 info
- `json-schema-2020-12-preservation` (added-after-release): 9 success, 0 failure, 0 skipped, 0 warning, 0 info

## Regression policy changes needed

Unexpected failures: 0; stale failure entries: 0; unexpected exclusions: 0; stale exclusions: 0; check status/inventory changes: 0.
See the JSON companion and raw check artifacts for exact outcomes. The baseline pins every check ID and status occurrence, including unscored scenarios. Missing, new, or changed checks require review; they never increase the exercised score.
