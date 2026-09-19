import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { createHash } from "node:crypto";
import { once } from "node:events";
import { mkdir, readFile, readdir, writeFile } from "node:fs/promises";
import path from "node:path";
import { createInterface } from "node:readline";
import { fileURLToPath } from "node:url";
import { parse } from "yaml";
import { renderMarkdown, summarize } from "./report.mjs";

const here = path.dirname(fileURLToPath(import.meta.url));
const project = path.resolve(here, "..");
const revision = "2026-07-28";
const sha = "ae2f4f6210fd729e2e318edd5bbfa31a43cee0bc608e48052fa26dbf1d939b57";
const runnerPackage = path.join(here, "node_modules/@modelcontextprotocol/conformance");
const bytes = await readFile(path.join(here, `requirements/${revision}.yaml`));
assert.equal(createHash("sha256").update(bytes).digest("hex"), sha, "vendored requirements changed");
assert.deepEqual(await readFile(path.join(runnerPackage, `requirements/${revision}.yaml`)), bytes,
  "installed runner requirements differ from frozen inventory");
assert.equal(JSON.parse(await readFile(path.join(runnerPackage, "package.json"))).version, "0.2.0-alpha.11");
const manifest = parse(bytes.toString());
assert.equal(manifest.server.length, 37);
const output = path.resolve(process.env.MCP_CONFORMANCE_OUTPUT ?? path.join(project, "tmp/conformance"));
// Each run gets its own directory: stale files can never supply missing results.
const runDir = path.join(output, new Date().toISOString().replaceAll(":", "-"));
await mkdir(runDir, { recursive: true });
const child = spawn("mix", ["run", "--no-compile", "--no-deps-check", "../../conformance/fixture_server.exs"], {
  cwd: path.join(project, "extensions/tasks"), stdio: ["pipe", "pipe", "pipe"],
  env: { ...process.env, MIX_ENV: "dev", ERL_FLAGS: process.env.ERL_FLAGS ?? "+S 4:4",
    MCP_PORT: "0", MCP_CONFORMANCE_MANAGED: "1" },
});
const exited = once(child, "exit");
const lines = createInterface({ input: child.stdout });
let diagnostics = "";
child.stderr.on("data", (chunk) => { diagnostics += chunk; });
let runner;
let runnerExit;
let runnerLog = "";
let report;
try {
  const readiness = await Promise.race([
    (async () => {
      for await (const line of lines) {
        try {
          const parsed = JSON.parse(line);
          if (parsed.conformanceReady === true) return parsed;
        } catch { diagnostics += `${line}\n`; }
      }
      throw new Error("fixture stdout closed before readiness");
    })(),
    exited.then(([code]) => { throw new Error(`fixture exited before readiness: ${code}`); }),
    new Promise((_, reject) => {
      const timer = setTimeout(() => reject(new Error("fixture readiness timeout")), 30_000);
      timer.unref();
    }),
  ]);
  const endpoint = new URL(readiness.url);
  assert.equal(endpoint.hostname, "127.0.0.1");
  runner = spawn(process.execPath, [path.join(runnerPackage, "dist/index.js"), "server",
    "--url", readiness.url, "--requirements", revision, "--output-dir", runDir],
  { cwd: here, stdio: ["ignore", "pipe", "pipe"] });
  runnerExit = once(runner, "exit");
  const capture = (chunk) => { runnerLog += chunk; process.stdout.write(chunk); };
  runner.stdout.on("data", capture);
  runner.stderr.on("data", capture);
  let timeout = false;
  const timer = setTimeout(() => { timeout = true; runner.kill("SIGKILL"); }, 240_000);
  let code;
  try { [code] = await runnerExit; } finally { clearTimeout(timer); }
  assert.equal(timeout, false, "external runner timed out");
  assert.ok(code === 0 || code === 1, `unexpected runner exit: ${code}`);
  const scenarios = {};
  for (const entry of await readdir(runDir, { withFileTypes: true })) {
    if (!entry.isDirectory()) continue;
    const match = /^server-(.+)-\d{4}-\d{2}-\d{2}T/.exec(entry.name);
    assert.ok(match, `unexpected artifact directory: ${entry.name}`);
    assert.ok(!Object.hasOwn(scenarios, match[1]), `duplicate scenario: ${match[1]}`);
    scenarios[match[1]] = JSON.parse(await readFile(path.join(runDir, entry.name, "checks.json")));
  }
  const baseline = JSON.parse(await readFile(path.join(here, "expected-failures.json")));
  report = {
    schemaVersion: 2, runDate: new Date().toISOString().slice(0, 10), protocolVersion: revision,
    runner: "@modelcontextprotocol/conformance@0.2.0-alpha.11", runnerExitCode: code,
    requirements: { attemptedScenarios: manifest.server.length, requiredScenarios: 37,
      requirementsAnchor: "@modelcontextprotocol/conformance@0.2.0-alpha.10",
      requirementsCommit: "c321dd32035556e6769d3724a8ee97d87c3faaac", requirementsSha256: sha },
    ...summarize(manifest, scenarios, baseline),
  };
  await writeFile(path.join(runDir, "summary.json"), `${JSON.stringify(report, null, 2)}\n`);
  await writeFile(path.join(runDir, "summary.md"), renderMarkdown(report));
  process.stdout.write(`\nEvidence: ${runDir}\n`);
  if (!report.regression.passed) process.exitCode = 1;
} finally {
  if (runner && runner.exitCode === null && runner.signalCode === null) {
    runner.kill("SIGKILL");
    await runnerExit;
  }
  await writeFile(path.join(runDir, "runner.log"), runnerLog);
  child.stdin.end();
  let forced = false;
  const timer = setTimeout(() => { forced = true; child.kill("SIGKILL"); }, 5000);
  try {
    const [code] = await exited;
    assert.equal(forced, false, "fixture failed to stop on EOF");
    assert.equal(code, 0, `fixture failed: ${diagnostics}`);
  } finally {
    clearTimeout(timer);
    lines.close();
    await writeFile(path.join(runDir, "fixture.log"), diagnostics);
  }
}
