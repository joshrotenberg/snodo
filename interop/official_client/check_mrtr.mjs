import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { once } from "node:events";
import path from "node:path";
import { createInterface } from "node:readline";
import { fileURLToPath } from "node:url";

import { Client, StreamableHTTPClientTransport } from "@modelcontextprotocol/client";
import { StdioClientTransport } from "@modelcontextprotocol/client/stdio";

// The pinned official client validates incoming MRTR and embedded elicitation
// with its own modern-era schemas, calls our registered input handler, and
// retries automatically. This harness observes, but never rewrites, wire data.
const here = path.dirname(fileURLToPath(import.meta.url));
const project = path.resolve(here, "../..");
const fixture = path.join(here, "mrtr_fixture.exs");
const elixir = process.env.SNODO_ELIXIR ?? "elixir";
const protocol = "2026-07-28";
const options = () => ({ signal: AbortSignal.timeout(30_000) });

const sampled = { role: "assistant", content: { type: "text", text: "one-line preview" },
  model: "acceptance-model", stopReason: "endTurn" };
const roots = { roots: [{ uri: "file:///acceptance", name: "acceptance" }] };

function newClient() {
  const callbacks = [];
  const embedded = { sampling: [], roots: [] };
  const client = new Client(
    { name: "snodo-mrtr-acceptance", version: "1.0.0" },
    {
      versionNegotiation: { mode: { pin: protocol } },
      capabilities: { elicitation: { form: {}, url: {} }, sampling: {}, roots: {} },
      inputRequired: { autoFulfill: true, maxRounds: 6 },
    },
  );
  // SEP-2577 deprecates the embedded sampling and roots requests; the pinned
  // client still validates them and dispatches them to these handlers. No
  // model runs and no file system is read: both answers are fixed.
  client.setRequestHandler("sampling/createMessage", async (request) => {
    embedded.sampling.push(structuredClone(request.params));
    assert.equal(request.params.maxTokens, 32);
    assert.equal(request.params.systemPrompt, "Answer in one sentence");
    assert.deepEqual(request.params.messages, [
      { role: "user", content: { type: "text", text: "Summarize the preview in one line" } },
    ]);
    return structuredClone(sampled);
  });
  client.setRequestHandler("roots/list", async (request) => {
    embedded.roots.push(structuredClone(request.params ?? {}));
    return structuredClone(roots);
  });
  client.setRequestHandler("elicitation/create", async (request) => {
    callbacks.push(structuredClone(request.params));
    if (request.params.mode === "url") {
      assert.equal(request.params.url, "https://example.invalid/preferences");
      assert.equal(Object.hasOwn(request.params, "elicitationId"), false);
      // Simulated consent only: never fetch/open the URL or supply credentials.
      return { action: "accept" };
    }
    const [field] = request.params.requestedSchema.required;
    const values = { color: "blue", style: "compact", label: "fresh" };
    assert.ok(Object.hasOwn(values, field));
    return { action: "accept", content: { [field]: values[field] } };
  });
  return { client, callbacks, embedded };
}

function observe(transport) {
  const sent = [];
  const send = transport.send.bind(transport);
  transport.send = async (message, ...args) => {
    sent.push(structuredClone(message));
    return send(message, ...args);
  };
  return sent;
}

function toolData(result) {
  assert.notEqual(result.isError, true);
  assert.equal(result.content[0].type, "text");
  return JSON.parse(result.content[0].text);
}

function assertPreferenceLegs(legs) {
  assert.equal(legs.length, 3, "initial call plus two automatic retries");
  assert.equal(new Set(legs.map((leg) => leg.id)).size, legs.length);
  assert.equal(Object.hasOwn(legs[0].params, "requestState"), false);
  assert.equal(typeof legs[1].params.requestState, "string");
  assert.equal(typeof legs[2].params.requestState, "string");
  assert.notEqual(legs[1].params.requestState, legs[2].params.requestState);
  assert.deepEqual(Object.keys(legs[1].params.inputResponses), ["color"]);
  assert.deepEqual(Object.keys(legs[2].params.inputResponses), ["style"]);
  for (const leg of legs) {
    assert.equal(leg.params._meta["io.modelcontextprotocol/protocolVersion"], protocol);
    assert.deepEqual(leg.params._meta["io.modelcontextprotocol/clientCapabilities"].elicitation,
      { form: {}, url: {} });
  }
}

function legsOf(sent, start, method) {
  return sent.slice(start).filter((request) => request.method === method);
}

async function exercise(client, callbacks, embedded, sent, transportName) {
  assert.equal(client.getProtocolEra(), "modern");
  const expected = { color: "blue", style: "compact", status: "preview" };

  let start = sent.length;
  const tool = await client.callTool({ name: "preference_preview", arguments: { subject: "acceptance" } }, options());
  assert.deepEqual(toolData(tool), expected);
  const toolLegs = sent.slice(start).filter((request) => request.method === "tools/call");
  assertPreferenceLegs(toolLegs);
  for (const leg of toolLegs) assert.deepEqual(leg.params.arguments, { subject: "acceptance" });

  // The server checks signed state against the original operation, not merely
  // the token signature. Reusing a captured token with changed arguments fails.
  await assert.rejects(client.callTool({
    name: "preference_preview", arguments: { subject: "different-operation" },
    requestState: toolLegs[1].params.requestState,
    inputResponses: { color: { action: "accept", content: { color: "blue" } } },
  }, options()), (error) => error.code === -32602);

  start = sent.length;
  const resource = await client.readResource({ uri: "preview://preferences" }, options());
  assert.equal(resource.contents[0].uri, "preview://preferences");
  assert.deepEqual(JSON.parse(resource.contents[0].text), expected);
  assertPreferenceLegs(sent.slice(start).filter((request) => request.method === "resources/read"));

  start = sent.length;
  const prompt = await client.getPrompt({ name: "preference_prompt" }, options());
  assert.equal(prompt.messages[0].role, "user");
  assert.deepEqual(JSON.parse(prompt.messages[0].content.text), expected);
  assertPreferenceLegs(sent.slice(start).filter((request) => request.method === "prompts/get"));

  start = sent.length;
  const reset = await client.callTool({ name: "reset_preview", arguments: {} }, options());
  assert.deepEqual(toolData(reset), { status: "accept", stateDiscarded: true });
  const resetLegs = sent.slice(start).filter((request) => request.method === "tools/call");
  assert.equal(resetLegs.length, 3);
  assert.equal(typeof resetLegs[1].params.requestState, "string");
  assert.equal(Object.hasOwn(resetLegs[2].params, "requestState"), false, "stale state must be discarded");
  assert.deepEqual(Object.keys(resetLegs[2].params.inputResponses), ["label"]);

  const url = await client.callTool({ name: "url_preview", arguments: {} }, options());
  assert.deepEqual(toolData(url), { consent: "accept", externalStatus: "pending" });
  assert.equal(callbacks.filter((request) => request.mode === "url").length, 1);
  assert.equal(callbacks.filter((request) => request.mode !== "url").length, 7);

  // The deprecated sampling and roots requests: one leg asks, the retry
  // carries the handler's result as the named input response, and the client
  // declares both capabilities on every leg.
  start = sent.length;
  const sampling = await client.callTool({ name: "sampling_preview", arguments: {} }, options());
  assert.deepEqual(toolData(sampling), { summary: "one-line preview", model: "acceptance-model" });
  const samplingLegs = legsOf(sent, start, "tools/call");
  assert.equal(samplingLegs.length, 2);
  assert.equal(Object.hasOwn(samplingLegs[1].params, "requestState"), false, "stateless workflow");
  assert.deepEqual(samplingLegs[1].params.inputResponses, { summary: sampled });
  const declared = samplingLegs[1].params._meta["io.modelcontextprotocol/clientCapabilities"];
  assert.deepEqual(declared.sampling, {});
  assert.deepEqual(declared.roots, {});

  start = sent.length;
  const listed = await client.callTool({ name: "roots_preview", arguments: {} }, options());
  assert.deepEqual(toolData(listed), { roots: ["file:///acceptance"] });
  const rootsLegs = legsOf(sent, start, "tools/call");
  assert.equal(rootsLegs.length, 2);
  assert.deepEqual(rootsLegs[1].params.inputResponses, { roots });

  // All three kinds in one result are answered in one round.
  start = sent.length;
  const mixed = await client.callTool({ name: "mixed_preview", arguments: {} }, options());
  assert.deepEqual(toolData(mixed),
    { label: "fresh", summary: "one-line preview", model: "acceptance-model", roots: ["file:///acceptance"] });
  const mixedLegs = legsOf(sent, start, "tools/call");
  assert.equal(mixedLegs.length, 2);
  assert.deepEqual(Object.keys(mixedLegs[1].params.inputResponses).sort(), ["label", "roots", "summary"]);
  assert.equal(callbacks.filter((request) => request.mode !== "url").length, 8);
  assert.equal(embedded.sampling.length, 2);
  assert.equal(embedded.roots.length, 2);

  const operations = sent.filter((request) =>
    ["tools/call", "resources/read", "prompts/get"].includes(request.method));
  assert.equal(new Set(operations.map((request) => request.id)).size, operations.length);
  return {
    transport: transportName, protocol, automaticWorkflows: 8,
    elicitationCallbacks: callbacks.length, samplingCallbacks: embedded.sampling.length,
    rootsCallbacks: embedded.roots.length, operationRequests: operations.length,
    changedArgumentsRejected: true, freshIds: true,
    replacedState: true, discardedState: true, urlConsentIsNotCompletion: true,
  };
}

async function checkStdio() {
  const { client, callbacks, embedded } = newClient();
  const transport = new StdioClientTransport({
    command: elixir, args: [fixture, "--stdio"], cwd: project,
    env: { ...process.env, ERL_FLAGS: process.env.ERL_FLAGS ?? "+S 4:4" }, stderr: "pipe",
  });
  const sent = observe(transport);
  let diagnostics = "";
  transport.stderr?.on("data", (chunk) => { diagnostics += chunk; });
  try {
    await client.connect(transport, options());
    return await exercise(client, callbacks, embedded, sent, "stdio");
  } catch (error) {
    if (diagnostics) process.stderr.write(diagnostics);
    throw error;
  } finally {
    await client.close();
  }
}

async function checkHTTP() {
  const child = spawn(elixir, [fixture, "--http"], {
    cwd: project, stdio: ["pipe", "pipe", "pipe"],
    env: { ...process.env, ERL_FLAGS: process.env.ERL_FLAGS ?? "+S 4:4" },
  });
  let diagnostics = "";
  child.stderr.on("data", (chunk) => { diagnostics += chunk; });
  const exited = once(child, "exit");
  const lines = createInterface({ input: child.stdout });
  const { client, callbacks, embedded } = newClient();
  let forcedShutdown = false;
  try {
    const readiness = await Promise.race([
      once(lines, "line", { signal: AbortSignal.timeout(15_000) }).then(([line]) => JSON.parse(line)),
      exited.then(([code]) => { throw new Error(`fixture exited before readiness: ${code}`); }),
    ]);
    const transport = new StreamableHTTPClientTransport(new URL(readiness.url));
    const sent = observe(transport);
    await client.connect(transport, options());
    const summary = await exercise(client, callbacks, embedded, sent, "http");
    assert.equal(transport.sessionId, undefined);
    return summary;
  } catch (error) {
    if (diagnostics) process.stderr.write(diagnostics);
    throw error;
  } finally {
    try {
      await client.close();
    } finally {
      lines.close();
      child.stdin.end();
      const timer = setTimeout(() => { forcedShutdown = true; child.kill("SIGKILL"); }, 5000);
      try {
        const [code] = await exited;
        assert.equal(forcedShutdown, false, "HTTP fixture failed to stop on EOF");
        assert.equal(code, 0, `HTTP fixture failed: ${diagnostics}`);
      } finally {
        clearTimeout(timer);
      }
    }
  }
}

const selected = process.argv.slice(2);
assert.ok(selected.length === 0 || (selected.length === 1 && ["--stdio", "--http"].includes(selected[0])),
  "usage: node check_mrtr.mjs [--stdio|--http]");
const checks = [];
if (selected.length === 0 || selected[0] === "--stdio") checks.push(await checkStdio());
if (selected.length === 0 || selected[0] === "--http") checks.push(await checkHTTP());
process.stdout.write(`${JSON.stringify({ mrtr: checks })}\n`);
