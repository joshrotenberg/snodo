# Executor load run, 2026-11-20

[Issue #440](https://github.com/joshrotenberg/snodo/issues/440) noted that
nothing measured queueing and admission through the shared
`Snodo.Server.Executor` beyond the 100-request stdio test and
`test/executor_acceptance_test.exs`. The executor has global
`:max_concurrency` and `:max_queue` limits and an execution deadline, but no
per-peer fairness, adaptive load shedding, or queue-wait deadline. This
record adds a repeatable load run, reports what it measured, and recommends
which of those three to build.

## The load run

`mix snodo.load` (`lib/mix/tasks/snodo.load.ex`, with the engine in
`lib/mix/snodo/load.ex`) sends `tools/call` requests to a tool that sleeps for
`--delay-ms` and returns the monotonic time it started. It is not part of
`mix quality`. `test/mix_load_test.exs` runs it at small scale in the normal
suite. Those tests hold handlers at a barrier to force rejection, queue wait,
unanswered requests, and a stdio server exit.

- The stdio peer runs in the same VM. `Snodo.Transport.Stdio.serve/2` reads
  from and writes to I/O device processes, as the stdio acceptance tests do,
  and the peer writes pre-encoded JSON-RPC lines. `Snodo.Client.Stdio` needs
  a subprocess, which would put the server in another VM and make send and
  start times incomparable.
- The HTTP peer is `Snodo.Client` over `Snodo.Transport.StreamableHTTP.Server`
  on loopback, with a pool as large as `--concurrency`.
- Both transports get an application-owned executor through `:executor`.
- Every transport is set up before any traffic is released. In `--shared`
  runs, `--stagger-ms` delays a transport's traffic, not its setup, and the
  report records when each transport actually sent its first request and the
  executor's counters at that moment.

Every configured request ends in one outcome: answered (completed, rejected
for capacity, or another server error response), unanswered (the peer gave
up after `--client-timeout`, or the client reported a transport error), or
unsent (the stdio server exited first). The task exits with an error when
any request is unanswered or unsent, unless `--allow-unanswered` is given.
Every run below answered all of its requests.

Measurements:

| Name | What it covers | Source |
|---|---|---|
| to start | from the peer's send boundary to handler start, for completed requests only | the handler's start time, compared in the same VM |
| end to end, rejection, error response | from the same boundary to the outcome | the peer |
| execution | dispatch inside the executor task, without queue wait | `[:snodo, :server, :dispatch, :stop]` `duration`, through an instrumentation sink |
| sampled max queued, sampled max running | executor counters | `Snodo.Server.Executor.stats/1` every 5 ms |

The send boundary differs by transport. On stdio it is the moment a
pre-encoded line is handed to the input device, so "to start" covers the
transport reading and decoding the line, admission, and queue wait. On HTTP
it is the call to `Snodo.Client.call_tool/4`, so it also covers client work,
pool checkout, and opening a connection. Because only completed requests have
a start time, "to start" describes the requests that got through, not the
ones that were rejected or timed out.

The stats calls go through the executor's mailbox, so the sampled maxima can
miss the true peaks. A sampled maximum is a lower bound. No new
instrumentation event was added.

## Machine

Intel Core i7-10710U (6 cores, 12 threads, 1.10 GHz base), 32 GB, Linux 7.2.6,
x86_64. OTP 29 (ERTS 17.1.1), Elixir 1.20.5, 12 schedulers.
`net.core.somaxconn` is 4096. The peers run in the server's VM and share its
schedulers.

## Results

Every run sent 1,000 requests per transport with 1,000 in flight, a 10 ms
handler, and the default 30,000 ms request timeout unless noted. Each row is
three runs (two for G), shown as the lowest and highest value seen.
Latencies are in milliseconds. In check runs of A and D, execution p50 was
10.6 to 10.8 ms, so the executor itself added little; time went to queue
wait and to the transports' front ends.

| Run | Transport | Completed | Rejected or error responses | To start p50 | To start p99 | Sampled max queued |
|---|---|---|---|---|---|---|
| A. defaults: 32/256, backlog 128 | stdio | 436 to 480 | 520 to 564 rejected | 69 to 80 | 144 to 158 | 256 |
| | http | 1,000 | 0 | 1,242 to 1,436 | 2,350 to 3,142 | 87 to 140 |
| B. 32/256, backlog 4096 | http | 550 to 580 | 420 to 450 rejected | 133 to 146 | 208 to 242 | 256 |
| C. 32/2000, backlog 4096 | stdio | 1,000 | 0 | 167 to 168 | 333 to 334 | 904 |
| | http | 1,000 | 0 | 193 to 209 | 345 to 370 | 702 to 730 |
| D. 1024/256, backlog 4096 | stdio | 1,000 | 0 | 35 to 39 | 68 to 79 | 0 (sampled max running 156 to 188) |
| | http | 1,000 | 0 | 83 to 90 | 120 to 135 | 0 (sampled max running 126 to 157) |
| E. shared executor, 32/256, backlog 4096 | stdio | 356 to 433 | 567 to 644 rejected | 95 to 190 | 225 to 310 | 256 |
| | http | 191 to 355 | 645 to 809 rejected | 159 to 167 | 193 to 227 | |
| F1. shared, 32/256; HTTP sends 50, released 20 ms after stdio | stdio | 392 to 579 | 421 to 608 rejected | 70 to 120 | 147 to 227 | 256 |
| | http (50) | 29 to 47 | 3 to 21 rejected | 94 to 106 | 96 to 118 | |
| F2. as F1, 32/2000 | stdio | 1,000 | 0 | 171 to 175 | 342 to 381 | 922 to 950 |
| | http (50) | 50 | 0 | 271 to 333 | 301 to 344 | |
| G. 100 ms handler, 32/2000, request timeout 1,000 ms | stdio | 1,000 | 0 | 1,533 to 1,535 | 3,050 (max 3,146) | 968 |
| | http | 320 | 680 error responses, `-32603 Request execution timed out` | 453 to 459 | 951 to 956 | 936 to 940 |

In F1 the HTTP peer's first request went out 20.4 to 21.1 ms into the run,
when the executor had 32 running and 194 to 256 queued. In F2 it went out
20.4 to 20.7 ms in, with 32 running and 691 to 757 queued. In G the 680 HTTP
error responses arrived a p50 of 1,088 to 1,100 ms and at most 1,103 to
1,121 ms after their calls; the "to start"
figures for G's HTTP row describe only the 320 that completed.

Commands, in order: `mix snodo.load`; `mix snodo.load --transport http --backlog 4096`;
`mix snodo.load --max-queue 2000 --backlog 4096`;
`mix snodo.load --max-concurrency 1024 --backlog 4096`;
`mix snodo.load --shared --backlog 4096`;
`mix snodo.load --shared --backlog 4096 --http-requests 50 --stagger-ms 20`, then with `--max-queue 2000`;
`mix snodo.load --delay-ms 100 --max-queue 2000 --request-timeout 1000 --backlog 4096`.

## Findings

1. **The HTTP listen backlog kept the load from reaching the executor.** The
   native listener's `:backlog` defaults to 128. Against a burst of 1,000
   connections on this machine, clients' connection attempts were retried
   after roughly one and three seconds (run A: to start p50 1.2 to 1.4 s,
   p99 up to 3.1 s). Retransmission is the kernel's TCP behavior, not the
   listener's, and other systems may differ. No request was rejected, so the
   queue never overflowed; the sampled maximum of 87 to 140 queued shows it
   was usually far from full, though it may have peaked higher between
   samples. With `--backlog 4096` (run B) the same load reached the executor
   and 42 to 45 percent of it was rejected there. `:backlog` was
   undocumented; this change documents it.
2. **The front ends are serial.** In run D the executor had a slot for every
   request, so nothing could queue, yet requests handed over at the same
   moment reached their handlers up to 68 to 79 ms (stdio) and 120 to
   137 ms (HTTP) later. The stdio coordinator reads, decodes, and submits one
   line at a time, and the HTTP listener accepts one connection at a time.
   The sampled maximum of about 150 to 190 running is a lower bound, not the
   true peak. Rejections wait behind the same work: stdio rejections took
   33 to 44 ms (p50) in run A.
3. **Queue wait is not bounded by a deadline on stdio.** The executor's
   deadline starts when work starts. In run G, with a 1,000 ms request
   timeout, stdio requests waited up to 3.1 s in the queue and then ran to
   completion. The native HTTP listener's `:request_timeout` covers queue
   wait plus execution, so the same load there ended 680 requests with a
   timeout error, each after about 1.1 s. The two transports apply the same
   option differently, and neither drops queued work that can no longer meet
   its deadline before the deadline passes.
4. **A heavy peer sets a light peer's latency.** The queue is one FIFO for
   every submitter. In run F1, a peer sending 50 requests into a full queue
   had 3 to 21 of them rejected, and the rest waited 94 to 118 ms for 10 ms
   of work. In run F2, arriving behind about 700 queued requests, every one
   completed but waited 271 to 344 ms. With two equally heavy peers (run E)
   the split was not even: stdio completed 356 to 433 and HTTP 191 to 355,
   depending on which front end reached the executor first.

## Recommendation

- **Queue-wait deadline: build it.** Run G shows stdio work waiting three
  times longer than its request timeout. An executor option such as
  `:max_queue_wait`, or a deadline measured from `submit/4`, would bound
  queue wait the same way on every transport and remove queued work as soon
  as it can no longer start in time, instead of after the full timeout. Its
  default and error need documenting with the other limits. An executor event
  carrying the queue wait would let applications see what this run measured.
- **Adaptive load shedding: not needed now.** The fixed queue bound already
  sheds load. In these runs the queue wait it allowed followed the queue
  length and the handler time: in run A the slowest completed stdio request
  reached its handler within 158 ms, with 256 queued ahead of 32 slots of
  10 ms work. That relationship is an observation, not a guarantee; it holds
  only while handler times are steady. A queue-wait deadline covers handler
  times that grow, with a static limit that is easy to document. Revisit if a
  deployment shows a queue-wait deadline is not enough.
- **Per-peer fairness: not now.** The effect is real (runs E and F), but it
  only applies where several peers share one executor. Stdio starts one
  executor per connection unless the application injects a shared one. The
  HTTP listener shares one executor across clients, but a 2026-07-28 request
  carries no peer identity; the executor would need one from a request gate
  or the socket address. Until an application asks for it, the existing
  guidance to rate-limit at the proxy or HTTP server applies. If it is built,
  it should be an opt-in per-key share of `:max_queue` keyed by gate
  identity.
- **Separately:** consider raising the listener's default `:backlog` toward
  `:max_connections` (1,024). On this machine a backlog far below it turned
  a connection burst into multi-second stalls before any MCP limit applied.

These numbers are from one laptop with the peers in the server's VM, and
varied by up to about 20 percent between runs. They show where time goes and
how the limits interact, not capacity figures.
