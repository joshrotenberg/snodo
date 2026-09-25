import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { once } from "node:events";
import path from "node:path";
import { createInterface } from "node:readline";
import { fileURLToPath } from "node:url";
import { Client, StreamableHTTPClientTransport } from "@modelcontextprotocol/client";
import { StdioClientTransport } from "@modelcontextprotocol/client/stdio";

const project = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const fixture = path.join(project, "interop/official_client/progress_fixture.exs");
const elixir = process.env.SNODO_ELIXIR ?? "elixir";
const env = { ...process.env, ERL_FLAGS: process.env.ERL_FLAGS ?? "+S 4:4" };
const options = () => ({ signal: AbortSignal.timeout(15_000) });

function newClient() {
  const client = new Client({ name: "snodo-progress-check", version: "1.0.0" }, {
    versionNegotiation: { mode: { pin: "2026-07-28" } },
    capabilities: { elicitation: { form: {} } },
    inputRequired: { autoFulfill: true, maxRounds: 3 },
  });
  client.setRequestHandler("elicitation/create", async () => ({ action: "accept", content: { label: "progress-mrtr-ok" } }));
  return client;
}

function observe(transport) {
  const sent = [];
  const received = [];
  const send = transport.send.bind(transport);
  transport.send = async (message, ...args) => {
    sent.push(structuredClone(message));
    return send(message, ...args);
  };
  const onmessage = transport.onmessage;
  transport.onmessage = (message, ...args) => {
    received.push(structuredClone(message));
    return onmessage(message, ...args);
  };
  return { sent, received };
}

async function exercise(client, transport, name) {
  const wire = observe(transport);
  const clientErrors = [];
  client.onerror = (error) => clientErrors.push(error.message);
  const call = (mode, opts = options(), operation) => client.callTool({ name: "progress_preview", arguments: { mode, ...(operation ? { operation } : {}) } }, opts);
  let callbacks = 0;
  let syntheticCallbacks = 0;

  for (const mode of ["normal", "domain_error", "protocol_error", "mrtr"]) {
    const progress = [];
    const start = wire.received.length;
    const sentStart = wire.sent.length;
    const operation = `gated-${mode}`;
    const acknowledgements = [];
    const opts = { ...options(), onprogress: (value) => {
      if (value.message?.startsWith("Fulfilling input required")) {
        syntheticCallbacks++;
        return;
      }
      progress.push(value);
      callbacks++;
      const ack = client.callTool({ name: "progress_ack", arguments: { operation, value: value.progress } }, options());
      ack.catch(() => {}); // The awaited collection below reports any rejection.
      acknowledgements.push(ack);
    } };
    if (mode === "protocol_error") await assert.rejects(call(mode, opts, operation), (error) => error.code === -32602);
    else {
      const result = await call(mode, opts, operation);
      // The SDK projects away resultType; assert it on the observed wire below.
      assert.equal(result.isError === true, mode === "domain_error");
      const expected = { normal: "progress-ok", domain_error: "progress-domain-error", mrtr: "progress-mrtr-ok" };
      assert.equal(result.content[0].text, expected[mode]);
    }
    await Promise.all(acknowledgements);
    const legs = wire.sent.slice(sentStart).filter((message) => message.method === "tools/call" && message.params.name === "progress_preview");
    assert.equal(legs.length, mode === "mrtr" ? 2 : 1);
    assert.deepEqual(progress.map((value) => value.progress), mode === "mrtr" ? [0, 50, 100, 0, 50, 100] : [0, 50, 100],
      `${mode} wire frames: ${JSON.stringify(wire.received.slice(start))}`);
    for (const value of progress) {
      assert.equal(value.total, 100);
      assert.equal(value.message, `Stage ${value.progress}`);
    }
    const received = wire.received.slice(start);
    for (const [index, leg] of legs.entries()) {
      const token = leg.params._meta.progressToken;
      assert.ok(typeof token === "number" || typeof token === "string");
      const relevant = received.filter((message) => message.params?.progressToken === token || message.id === leg.id);
      assert.equal(relevant.length, 4);
      assert.deepEqual(relevant.slice(0, 3).map((message) => message.method), Array(3).fill("notifications/progress"));
      assert.equal(relevant[3].id, leg.id);
      if (mode === "protocol_error") assert.equal(relevant[3].error.code, -32602);
      else assert.equal(relevant[3].result.resultType, mode === "mrtr" && index === 0 ? "input_required" : "complete");
    }
  }

  assert.equal(callbacks, 15);
  assert.equal(syntheticCallbacks, 1);
  assert.deepEqual(clientErrors, [], "controlled callback delivery must not lose progress");

  // An unpaced burst is independently asserted on the wire. SDK 2.0.0 defers
  // notifications to microtasks but synchronously deletes progress handlers on
  // terminal responses, so a same-chunk burst can lose onprogress callbacks.
  // Do not alter transport delivery or insert production delays to hide this.
  const burstStart = wire.received.length;
  const burstCallbacks = [];
  await call("normal", { ...options(), onprogress: (value) => burstCallbacks.push(value.progress) });
  const burst = wire.received.slice(burstStart);
  assert.deepEqual(burst.slice(0, 3).map((message) => message.params.progress), [0, 50, 100]);
  assert.equal(burst.length, 4);
  assert.equal(burst[3].result.resultType, "complete");
  assert.ok(burstCallbacks.every((value, index) => [0, 50, 100].includes(value) && (index === 0 || value > burstCallbacks[index - 1])));
  assert.ok(clientErrors.every((message) => message.startsWith("Received a progress notification for an unknown token:")));
  const burstUnknownTokenErrors = clientErrors.length;
  assert.equal(burstCallbacks.length + burstUnknownTokenErrors, 3);
  clientErrors.length = 0;

  const start = wire.received.length;
  const noToken = await call("normal");
  assert.equal(noToken.content[0].text, "progress-ok");
  assert.equal(wire.sent.at(-1).params._meta.progressToken, undefined);
  assert.deepEqual(wire.received.slice(start).map((message) => message.method ?? "result"), ["result"]);

  // Abort on observed progress, not after an assumed delay. The monitored
  // server worker parks after its first report; status waits for its DOWN.
  const abort = new AbortController();
  const cancellationProgress = [];
  const sentStart = wire.sent.length;
  await assert.rejects(call("slow", {
    signal: AbortSignal.any([abort.signal, AbortSignal.timeout(15_000)]),
    onprogress: (value) => {
      cancellationProgress.push(value.progress);
      abort.abort("deterministic progress cancellation");
    },
  }));
  const slow = wire.sent.slice(sentStart).find((message) => message.method === "tools/call");
  const status = await client.callTool({ name: "progress_status", arguments: {} }, options());
  assert.deepEqual(JSON.parse(status.content[0].text), { stopped: true, completed: false });
  assert.deepEqual(cancellationProgress, [0]);
  assert.equal((await call("normal")).content[0].text, "progress-ok");
  const slowFrames = wire.received.filter((message) => message.params?.progressToken === slow.params._meta.progressToken || message.id === slow.id);
  assert.equal(slowFrames.length, 1, "no late progress or final response after cancellation");
  assert.equal(slowFrames[0].params.progress, 0);
  assert.deepEqual(clientErrors, []);
  return { transport: name, controlledProgressCallbacks: callbacks, sdkMRTRCallbacks: syntheticCallbacks,
    burstProgressFrames: 3, burstCallbacksObserved: burstCallbacks, burstUnknownTokenErrors,
    cancellationProgress: 1, noTokenFrames: 0,
    normalAndErrorTerminals: true, mrtrPreserved: true, cancelledWorkerStopped: true, postCancelCall: true };
}

async function stdio() {
  const client = newClient();
  const transport = new StdioClientTransport({ command: elixir, args: [fixture, "--stdio"], cwd: project, env, stderr: "pipe" });
  let diagnostics = "";
  transport.stderr?.on("data", (chunk) => { diagnostics = (diagnostics + chunk).slice(-16_384); });
  try {
    await client.connect(transport, options());
    return await exercise(client, transport, "stdio");
  } catch (error) {
    if (diagnostics) process.stderr.write(diagnostics);
    throw error;
  } finally { await client.close(); }
}

async function http() {
  const child = spawn(elixir, [fixture, "--http"], { cwd: project, env, stdio: ["pipe", "pipe", "pipe"] });
  const exited = once(child, "exit");
  const lines = createInterface({ input: child.stdout });
  let diagnostics = "";
  child.stderr.on("data", (chunk) => { diagnostics = (diagnostics + chunk).slice(-16_384); });
  const client = newClient();
  try {
    const { url } = await Promise.race([
      once(lines, "line", { signal: AbortSignal.timeout(15_000) }).then(([line]) => JSON.parse(line)),
      exited.then(([code]) => { throw new Error(`fixture exited before readiness: ${code}`); }),
    ]);
    assert.equal(new URL(url).hostname, "127.0.0.1");
    const transport = new StreamableHTTPClientTransport(new URL(url));
    await client.connect(transport, options());
    return await exercise(client, transport, "http");
  } catch (error) {
    if (diagnostics) process.stderr.write(diagnostics);
    throw error;
  } finally {
    await client.close();
    lines.close();
    child.stdin.end();
    const timer = setTimeout(() => child.kill("SIGKILL"), 5_000);
    try {
      const [code] = await exited;
      assert.equal(code, 0, `HTTP fixture did not exit cleanly: ${diagnostics}`);
    } finally { clearTimeout(timer); }
  }
}

const modes = process.argv.slice(2);
assert.ok(modes.length === 0 || (modes.length === 1 && ["--stdio", "--http"].includes(modes[0])));
const checks = [];
if (modes.length === 0 || modes[0] === "--stdio") checks.push(await stdio());
if (modes.length === 0 || modes[0] === "--http") checks.push(await http());
process.stdout.write(JSON.stringify({ progress: checks }) + "\n");
