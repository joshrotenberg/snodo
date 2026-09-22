# Progress acceptance and a pinned-client callback race

Run from the repository root after compiling the core:

```sh
ERL_FLAGS='+S 4:4' mix compile --warnings-as-errors
npm ci --prefix interop/official_client --ignore-scripts --no-audit --no-fund
npm run check:progress --prefix interop/official_client
```

`npm run check` chains baseline, MRTR, and progress acceptance. The progress script
also accepts `--stdio` or `--http`. It uses the exact lockfile client version,
`@modelcontextprotocol/client@2.0.0`, against fresh Mixless public-API fixtures.
There are no external service calls or timing sleeps.

## Separate proofs

For both stdio and native loopback HTTP the controlled workflow verifies:

- Fifteen real `onprogress` callbacks: three increasing stages each for normal,
  tool-domain-error, and typed protocol-error results, and two MRTR legs with three
  stages each. The SDK's additional synthetic MRTR-fulfillment callback is counted
  separately, not presented as a server notification.
- Every originating wire leg contains three token-correlated progress
  notifications followed by exactly one appropriate complete, error, or
  input-required terminal response. The SDK projects `resultType` away from
  decoded results, so this assertion uses passively observed raw messages.
- Without a progress token, calling the same reporting code emits no progress
  notification and returns the ordinary result.
- Cancellation is triggered by the first callback. The handler registers itself
  with a monitored fixture controller and parks, rather than sleeping. A status
  call waits for that worker's `DOWN`, verifies it never completed, and a fresh
  ordinary call succeeds. No late progress or final response is observed for the
  cancelled request.

The controlled handler awaits a separate fixture `progress_ack` call after each
reported stage. This proves actual SDK callbacks execute before releasing the
next stage; it is **test coordination**, not framework transport behavior.

An additional **unpaced burst** has no such acknowledgement. The script requires
all three real notifications (`0`, `50`, `100`) followed by the complete result
on the wire, while recording how many the unmodified SDK actually delivers to
`onprogress`. Callback loss in this separate probe is diagnostic, not suppressed
by changing the production transport or delaying notifications.

## Observed SDK 2.0.0 race

On the verified run, stdio delivered all three notifications correctly before the
terminal response, but the client callback observed only `[0]` and reported two
unknown-progress-token errors. HTTP observed `[0, 50, 100]`. Chunk boundaries and
scheduling can change these diagnostic counts; the ordered wire requirement and
controlled callback assertions are deterministic.

The pinned package's `dist/src-D_zzAWoS.mjs` explains the discrepancy:

```text
SHA-256 fb539b120913afb2a469cfdd8f233b4c6aac98d7532f3172e783258aaadef084
```

- `Protocol._onnotification` (around line 5798) defers notification-handler
  invocation through `Promise.resolve().then(...)`.
- `Protocol._onresponse` (around line 5956) synchronously deletes that request's
  progress handler while handling the terminal response.
- `Protocol._onprogress` then finds no handler when a deferred preceding
  notification executes after the same-read-chunk terminal response.

This is source evidence from the installed, lockfile-pinned official package,
not an inferred server failure. The test does not patch SDK internals or reorder
messages. It observes transport callbacks while forwarding every message
unchanged. The SDK's automatic MRTR loop separately generates its own progress
callback near `runInputRequiredDriver`, which the report distinguishes.

Independent checks reinforce the wire evidence: the frozen conformance fixture
`test_tool_with_progress` reports actual computation stages without client pacing,
literal fixture tests check string/integer-zero token correlation and invalid-token
admission, and the full wire-schema lane validates `ProgressNotification` across
direct, stdio, and native HTTP emissions.
