import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { createHash } from "node:crypto";
import { once } from "node:events";
import { appendFile, mkdir, readFile, readdir, writeFile } from "node:fs/promises";
import path from "node:path";
import { createInterface } from "node:readline";
import { fileURLToPath } from "node:url";
import { parse } from "yaml";
import { renderMarkdown, summarize } from "./report.mjs";

const here = path.dirname(fileURLToPath(import.meta.url));
const project = path.resolve(here, "..");
// Vendored requirement sets, pinned by hash. 2025-11-25 is the upstream
// reconstruction from alpha.10 (see its header), vendored from alpha.11.
const requirementSets = {
  "2026-07-28": { sha: "ae2f4f6210fd729e2e318edd5bbfa31a43cee0bc608e48052fa26dbf1d939b57",
    required: { server: 37, client: 32 }, anchor: "@modelcontextprotocol/conformance@0.2.0-alpha.10",
    commit: "c321dd32035556e6769d3724a8ee97d87c3faaac" },
  "2025-11-25": { sha: "f33a304dfa2cbd999c24026a3453a64f377bba0c8aa80addadaf05862d212371",
    required: { server: 30, client: 18 },
    anchor: "@modelcontextprotocol/conformance@0.2.0-alpha.10 (reconstructed)", commit: null },
};
// A lane runs one leg of the official runner against one requirement set and
// keeps its own reviewed baseline. Server lanes start fixture_server.exs with
// a runtime profile and a transport; the client lane runs Snodo.Client through
// client.exs against the runner's own scenario servers. 2025-06-18 has no
// frozen requirement set, so its lane runs the runner's active suite for that
// version and every scenario is unscored. The Plug lane shares the native
// server baseline, so any difference between the two listeners fails a gate.
const lanes = {
  server: { leg: "server", revision: "2026-07-28", baseline: "expected-failures.json",
    fixture: { profile: "latest", transport: "native" } },
  client: { leg: "client", revision: "2026-07-28", baseline: "expected-failures-client.json" },
  "server-plug": { leg: "server", revision: "2026-07-28", baseline: "expected-failures.json",
    fixture: { profile: "latest", transport: "plug" } },
  "server-2025-11-25": { leg: "server", revision: "2025-11-25",
    baseline: "expected-failures-2025-11-25.json", fixture: { profile: "legacy", transport: "native" } },
  "server-2025-06-18": { leg: "server", specVersion: "2025-06-18",
    baseline: "expected-failures-2025-06-18.json", fixture: { profile: "legacy", transport: "native" } },
};
const laneName = process.argv[2] ?? "server";
assert.ok(Object.hasOwn(lanes, laneName), `unknown lane: ${laneName}`);
const lane = lanes[laneName];
const { leg } = lane;
const revision = lane.revision ?? lane.specVersion;
const requirementSet = lane.revision ? requirementSets[lane.revision] : null;
const artifact = leg === "server" ? /^server-(.+)-\d{4}-\d{2}-\d{2}T/ : /^(.+)-\d{4}-\d{2}-\d{2}T/;
const pinned = "0.2.0-alpha.11";
// MCP_CONFORMANCE_RUNNER points the scheduled canary at another runner build
// (the alpha dist-tag or upstream main). The pinned lane never sets it.
const canary = process.env.MCP_CONFORMANCE_RUNNER !== undefined;
const runnerPackage = path.resolve(process.env.MCP_CONFORMANCE_RUNNER ??
  path.join(here, "node_modules/@modelcontextprotocol/conformance"));
const runnerVersion = JSON.parse(await readFile(path.join(runnerPackage, "package.json"))).version;
if (!canary) assert.equal(runnerVersion, pinned);
let manifest = null;
let requirementsSha256 = null;
if (requirementSet) {
  const bytes = await readFile(path.join(here, `requirements/${revision}.yaml`));
  assert.equal(createHash("sha256").update(bytes).digest("hex"), requirementSet.sha,
    "vendored requirements changed");
  const runnerBytes = await readFile(path.join(runnerPackage, `requirements/${revision}.yaml`));
  if (!canary) {
    assert.deepEqual(runnerBytes, bytes, "installed runner requirements differ from frozen inventory");
  }
  // A canary scores against the manifest its runner ships, so scenarios added
  // after the pin show up as missing from the baseline rather than crashing.
  const used = canary ? runnerBytes : bytes;
  manifest = parse(used.toString());
  requirementsSha256 = createHash("sha256").update(used).digest("hex");
  assert.equal(manifest[leg].length, requirementSet.required[leg]);
}
const output = path.resolve(process.env.MCP_CONFORMANCE_OUTPUT ??
  path.join(project, "tmp/conformance", laneName));
// Each run gets its own directory: stale files can never supply missing results.
const runDir = path.join(output, new Date().toISOString().replaceAll(":", "-"));
await mkdir(runDir, { recursive: true });
const erlFlags = process.env.ERL_FLAGS ?? "+S 4:4";
// Only the server leg needs the fixture; the client leg's runner starts one
// scenario server per scenario and runs the client command against it.
const child = lane.fixture
  ? spawn("mix", ["run", "--no-compile", "--no-deps-check", "../fixture_server.exs"], {
    cwd: path.join(here, "fixture"), stdio: ["pipe", "pipe", "pipe"],
    env: { ...process.env, MIX_ENV: "dev", ERL_FLAGS: erlFlags, MCP_PORT: "0", MCP_CONFORMANCE_MANAGED: "1",
      MCP_FIXTURE_PROFILE: lane.fixture.profile, MCP_FIXTURE_TRANSPORT: lane.fixture.transport },
  })
  : null;
const exited = child && once(child, "exit");
const lines = child && createInterface({ input: child.stdout });
let diagnostics = "";
child?.stderr.on("data", (chunk) => { diagnostics += chunk; });
let runner;
let runnerExit;
let runnerLog = "";
let report;
try {
  let args;
  if (leg === "server") {
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
    args = ["server", "--url", readiness.url];
  } else {
    args = ["client", "--command", "mix run --no-compile --no-deps-check conformance/client.exs"];
  }
  const selection = requirementSet
    ? ["--requirements", revision]
    : ["--spec-version", revision, "--suite", "active"];
  runner = spawn(process.execPath, [path.join(runnerPackage, "dist/index.js"), ...args,
    ...selection, "--output-dir", runDir],
  { cwd: leg === "server" ? here : project, stdio: ["ignore", "pipe", "pipe"],
    env: { ...process.env, MIX_ENV: "dev", ERL_FLAGS: erlFlags } });
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
  // Scenario names such as auth/metadata-default nest their artifact directory.
  const scenarios = {};
  for (const entry of await readdir(runDir, { recursive: true })) {
    if (path.basename(entry) !== "checks.json") continue;
    const directory = path.dirname(entry).split(path.sep).join("/");
    const match = artifact.exec(directory);
    assert.ok(match, `unexpected artifact directory: ${directory}`);
    assert.ok(!Object.hasOwn(scenarios, match[1]), `duplicate scenario: ${match[1]}`);
    scenarios[match[1]] = JSON.parse(await readFile(path.join(runDir, entry)));
  }
  const baseline = JSON.parse(await readFile(path.join(here, lane.baseline)));
  // Without a frozen set, every scenario the runner ran is unscored.
  const scored = manifest ?? { [leg]: [], not_scored: Object.keys(scenarios).sort().map((scenario) =>
    ({ scenario, leg, reason: `no frozen requirement set for ${revision}` })) };
  report = {
    schemaVersion: 2, leg, lane: laneName, runDate: new Date().toISOString().slice(0, 10),
    protocolVersion: revision, runner: `@modelcontextprotocol/conformance@${runnerVersion}`,
    runnerExitCode: code,
    requirements: requirementSet
      ? { attemptedScenarios: manifest[leg].length, requiredScenarios: requirementSet.required[leg],
        requirementsAnchor: requirementSet.anchor, requirementsCommit: requirementSet.commit,
        requirementsSha256 }
      : { attemptedScenarios: Object.keys(scenarios).length, requiredScenarios: 0,
        selection: `--spec-version ${revision} --suite active` },
    ...summarize(scored, scenarios, baseline, leg),
  };
  await writeFile(path.join(runDir, "summary.json"), `${JSON.stringify(report, null, 2)}\n`);
  const markdown = renderMarkdown(report);
  await writeFile(path.join(runDir, "summary.md"), markdown);
  if (process.env.GITHUB_STEP_SUMMARY) await appendFile(process.env.GITHUB_STEP_SUMMARY, `${markdown}\n`);
  process.stdout.write(`\nEvidence: ${runDir}\n`);
  if (!report.regression.passed) process.exitCode = 1;
} finally {
  if (runner && runner.exitCode === null && runner.signalCode === null) {
    runner.kill("SIGKILL");
    await runnerExit;
  }
  await writeFile(path.join(runDir, "runner.log"), runnerLog);
  if (child) {
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
}
