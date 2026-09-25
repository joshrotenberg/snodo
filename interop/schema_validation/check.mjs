import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { createInterface } from "node:readline";
import { fileURLToPath } from "node:url";
import path from "node:path";
import { provenance, validateEmission } from "./validator.mjs";

const here = path.dirname(fileURLToPath(import.meta.url));
const project = path.resolve(here, "../..");
const version = provenance.protocolVersion;
const subscriptionKey = "io.modelcontextprotocol/subscriptionId";
let nextId = 1;

function request(method, params = {}) {
  return { jsonrpc: "2.0", id: nextId++, method, params: { ...params, _meta: {
    "io.modelcontextprotocol/protocolVersion": version,
    "io.modelcontextprotocol/clientCapabilities": { elicitation: { form: {} } },
    "io.modelcontextprotocol/clientInfo": { name: "snodo-wire-schema-check", version: "1.0.0" },
    ...params._meta,
  } } };
}

async function deadline(promise, label, ms = 8_000) {
  let timer;
  try {
    return await Promise.race([promise, new Promise((_, reject) => {
      timer = setTimeout(() => reject(new Error(`${label} timed out`)), ms);
    })]);
  } finally { clearTimeout(timer); }
}

function start(mode) {
  const child = spawn(process.env.SNODO_ELIXIR ?? "elixir", [path.join(here, "fixture.exs"), `--${mode}`], {
    cwd: project,
    env: { ...process.env, ERL_FLAGS: process.env.ERL_FLAGS ?? "+S 4:4" },
    stdio: ["pipe", "pipe", "pipe"],
  });
  const queue = [];
  let waiter;
  let closed = false;
  let stderr = "";
  let spawnError;
  child.on("error", (error) => { spawnError = error; });
  child.stderr.on("data", (data) => { stderr = (stderr + data).slice(-16_384); });
  const reader = createInterface({ input: child.stdout, crlfDelay: Infinity });
  reader.on("line", (line) => {
    if (line.length > 1_048_576 || queue.length > 100) {
      child.kill("SIGKILL");
      return;
    }
    if (waiter) { const resolve = waiter; waiter = undefined; resolve(line); }
    else queue.push(line);
  });
  const exited = new Promise((resolve) => child.on("close", (code, signal) => {
    closed = true;
    if (waiter) { waiter(undefined); waiter = undefined; }
    resolve({ code, signal });
  }));
  // Bound the fixture even if a protocol path or cleanup regresses.
  const lifetime = setTimeout(() => child.kill("SIGKILL"), 45_000);

  async function line() {
    const value = queue.length ? queue.shift() : closed ? undefined : await deadline(new Promise((resolve) => { waiter = resolve; }), `${mode} response`);
    assert.notEqual(value, undefined, `${mode} fixture closed: ${spawnError ?? stderr}`);
    return value;
  }

  return {
    async initialize() {
      if (mode === "http") {
        this.url = JSON.parse(await line()).url;
        assert.equal(new URL(this.url).hostname, "127.0.0.1");
      }
    },
    async call(raw) {
      if (mode === "http") {
        const headers = { "content-type": "application/json", accept: "application/json, text/event-stream", "MCP-Protocol-Version": version, "Mcp-Method": raw.method };
        const name = raw.params.name ?? raw.params.uri;
        if (name) headers["Mcp-Name"] = name;
        const response = await fetch(this.url, {
          method: "POST", headers, body: JSON.stringify(raw), signal: AbortSignal.timeout(8_000),
        });
        const body = await response.text();
        assert.ok(body.length <= 1_048_576, "HTTP body exceeds fixture limit");
        const messages = response.headers.get("content-type")?.includes("text/event-stream")
          ? body.split(/\r?\n/).filter((line) => line.startsWith("data:")).map((line) => JSON.parse(line.slice(5).trim()))
          : [JSON.parse(body)];
        assert.equal(response.status, messages.some((message) => message.error) ? 400 : 200);
        return messages;
      }
      child.stdin.write(JSON.stringify(raw) + "\n");
      const messages = [];
      do {
        messages.push(JSON.parse(await line()));
      } while (messages.at(-1).id !== raw.id);
      return messages;
    },
    async close() {
      try {
        child.stdin.end();
        const result = await deadline(exited, `${mode} fixture shutdown`, 5_000);
        assert.equal(result.code, 0, `${mode} fixture failed: ${stderr}`);
      } finally {
        clearTimeout(lifetime);
        if (!closed) child.kill("SIGKILL");
        reader.close();
      }
    },
  };
}

async function exercise(mode) {
  const peer = start(mode);
  const definitions = new Set();
  let operations = 0;
  let emissions = 0;
  let negativeControls = 0;

  async function call(method, params, expected = "complete") {
    const raw = request(method, params);
    const messages = await peer.call(raw);
    assert.ok(messages.length > 0);
    for (const message of messages) {
      for (const name of validateEmission(method, message)) definitions.add(name);
      emissions++;
      // Mutate each real emission, proving its named schema was attached.
      const invalid = structuredClone(message);
      invalid.jsonrpc = "1.0";
      assert.throws(() => validateEmission(method, invalid));
      negativeControls++;
      if (message.method === "notifications/progress") assert.equal(message.params.progressToken, raw.params._meta.progressToken);
      else if (message.method) assert.equal(message.params?._meta?.[subscriptionKey], raw.id);
      else assert.equal(message.id, raw.id);
    }
    const final = messages.at(-1);
    if (expected === "error") assert.ok(final.error, `${method} expected a protocol error`);
    else assert.equal(final.result?.resultType, expected, `${method} unexpected outcome`);
    operations++;
    return { messages, final, id: raw.id };
  }

  try {
    await peer.initialize();
    await call("server/discover", {});
    await call("tools/list", {});
    const normal = await call("tools/call", { name: "schema_preview", arguments: {} });
    assert.equal(normal.final.result.content[0].text, "schema-preview-ok");
    const progress = await call("tools/call", {
      name: "schema_preview", arguments: { mode: "progress" }, _meta: { progressToken: "schema-progress" },
    });
    assert.deepEqual(progress.messages.slice(0, 3).map((message) => message.params.progress), [0, 50, 100]);
    assert.equal(progress.final.result.content[0].text, "schema-progress-ok");
    const domain = await call("tools/call", { name: "schema_preview", arguments: { mode: "domain_error" } });
    assert.equal(domain.final.result.isError, true);
    const error = await call("tools/call", { name: "schema_preview", arguments: { mode: "protocol_error" } }, "error");
    assert.equal(error.final.error.code, -32602);
    await call("resources/list", {});
    await call("resources/templates/list", {});
    await call("resources/read", { uri: "schema://text" });
    await call("resources/read", { uri: "schema://item/example" });
    await call("prompts/list", {});
    await call("prompts/get", { name: "schema_prompt" });
    const completion = await call("completion/complete", {
      ref: { type: "ref/prompt", name: "schema_prompt" }, argument: { name: "mode", value: "m" },
    });
    assert.deepEqual(completion.final.result.completion.values, ["mrtr"]);

    for (const [method, params] of [
      ["tools/call", { name: "schema_preview", arguments: { mode: "mrtr" } }],
      ["resources/read", { uri: "schema://input" }],
      ["prompts/get", { name: "schema_prompt", arguments: { mode: "mrtr" } }],
    ]) {
      const initial = await call(method, params, "input_required");
      assert.deepEqual(Object.keys(initial.final.result.inputRequests), ["label"]);
      const retry = await call(method, { ...params, inputResponses: { label: { action: "accept", content: { label: "validated-retry" } } } });
      assert.notEqual(initial.id, retry.id);
      assert.ok(JSON.stringify(retry.final.result).includes("validated-retry"));
    }

    const subscription = await call("subscriptions/listen", {
      notifications: { toolsListChanged: true, resourceSubscriptions: ["schema://text"] },
    });
    assert.deepEqual(subscription.messages.map((message) => message.method ?? "terminal"), [
      "notifications/subscriptions/acknowledged", "notifications/tools/list_changed",
      "notifications/resources/updated", "terminal",
    ]);
    assert.equal(subscription.final.result._meta[subscriptionKey], subscription.id);
    assert.equal(emissions, 26);
    assert.equal(operations, 20);
    return { transport: mode, operations, emissions, negativeControls, definitions: [...definitions].sort() };
  } finally { await peer.close(); }
}

const transports = [];
for (const mode of ["direct", "stdio", "http"]) transports.push(await exercise(mode));
process.stdout.write(JSON.stringify({
  schemaCommit: provenance.commit, schemaSha256: provenance.sha256,
  formatPolicy: "annotation-only", transports,
}) + "\n");
