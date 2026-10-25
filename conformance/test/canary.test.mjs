import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { chmod, mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { parse } from "yaml";

const workflow = parse(await readFile(new URL("../../.github/workflows/canary.yml", import.meta.url), "utf8"));
const { canary, report } = workflow.jobs;
const summarizeScript = canary.steps.find((step) => step.name === "Summarize differences or execution errors").run;
const reportScript = report.steps.find((step) => step.name === "Open or update one issue per lane").run;
const runners = canary.strategy.matrix.runner;
const lanes = canary.strategy.matrix.lane;
const title = (lane = "server") => `ci: conformance canary differs from pin in ${lane}`;
const matching = () => ({ runnerExitCode: 1, regression: {
  passed: true, unexpectedFailures: [], staleFailures: [], unexpectedExclusions: [],
  staleExclusions: [], checkStatusDrift: [],
} });

async function harness(t, open = []) {
  const directory = await mkdtemp(path.join(os.tmpdir(), "snodo-canary-"));
  t.after(() => rm(directory, { recursive: true, force: true }));
  const artifacts = path.join(directory, "canary");
  const bin = path.join(directory, "bin");
  await mkdir(artifacts);
  await mkdir(bin);
  const history = path.join(directory, "gh.jsonl");
  await writeFile(history, "");
  await writeFile(path.join(bin, "gh"), `#!/usr/bin/env node
import { appendFileSync, readFileSync } from "node:fs";
const args = process.argv.slice(2);
const bodyIndex = args.indexOf("--body-file");
const body = bodyIndex < 0 ? null : readFileSync(args[bodyIndex + 1], "utf8");
appendFileSync(process.env.GH_HISTORY, JSON.stringify({ args, body }) + "\\n");
if (args[1] === "list") process.stdout.write(process.env.GH_OPEN);
`);
  await chmod(path.join(bin, "gh"), 0o755);
  for (const runner of runners) {
    for (const lane of lanes) await writeFile(path.join(artifacts, `${runner}--${lane}.status`), "match\n");
  }
  const env = { ...process.env, PATH: `${bin}:${process.env.PATH}`, RUNNER_TEMP: directory,
    GITHUB_STEP_SUMMARY: path.join(directory, "step-summary.md"), PINNED: "0.2.0-alpha.12",
    RUN_URL: "https://github.com/owner/repo/actions/runs/123", GH_HISTORY: history,
    GH_OPEN: JSON.stringify(open) };
  const run = (script, extra = {}) => {
    const result = spawnSync("bash", ["--noprofile", "--norc", "-e", "-o", "pipefail", "-c", script], {
      env: { ...env, ...extra }, encoding: "utf8",
    });
    assert.equal(result.status, 0, result.stderr || result.stdout);
  };
  return {
    artifacts,
    async summarize(outcome, summary, runner = "alpha", lane = "server") {
      const output = path.join(artifacts, `${runner}--${lane}`, "results");
      await mkdir(path.join(output, "run"), { recursive: true });
      if (summary) await writeFile(path.join(output, "run/summary.json"), JSON.stringify(summary));
      await writeFile(path.join(output, "../runner.txt"), runner === "alpha"
        ? "@modelcontextprotocol/conformance@0.2.0-alpha.13\n" : "upstream main at abc123\n");
      run(summarizeScript, { RUNNER: runner, LANE: lane, OUTCOME: outcome, MCP_CONFORMANCE_OUTPUT: output });
      return readFile(path.join(artifacts, `${runner}--${lane}.status`), "utf8");
    },
    async report() {
      run(reportScript);
      const calls = (await readFile(history, "utf8")).trim();
      return calls ? calls.split("\n").map((line) => JSON.parse(line)) : [];
    },
  };
}

test("canary covers every current lane against both runners with isolated issue permissions", async () => {
  const source = await readFile(new URL("../run.mjs", import.meta.url), "utf8");
  const current = [...source.matchAll(/^  (server|client|"[^"]+"): \{ leg:/gm)]
    .map((match) => match[1].replaceAll('"', ""));
  assert.deepEqual([...lanes].sort(), current.sort());
  assert.deepEqual(runners, ["alpha", "upstream-main"]);
  assert.deepEqual(canary.permissions, { contents: "read" });
  assert.deepEqual(report.permissions, { issues: "write" });
  assert.equal(report.if, "always() && !cancelled()");
  assert.equal(workflow.concurrency["cancel-in-progress"], false);
  assert.equal(canary["continue-on-error"], undefined);
  assert.equal(canary.steps.find((step) => step.id === "run")["continue-on-error"], undefined);
});

test("matching baselines create no issue even with a raw runner exit of 1", async (t) => {
  const h = await harness(t);
  assert.equal(await h.summarize("success", matching()), "match\n");
  assert.deepEqual(await h.report(), []);
});

test("differences from both runners open one issue with exact check changes and provenance", async (t) => {
  const h = await harness(t);
  const summary = matching();
  summary.regression.passed = false;
  summary.regression.staleFailures = ["scenario:recovered"];
  summary.regression.checkStatusDrift = [
    { scenario: "one", id: "changed", occurrence: 2, expected: "SUCCESS", actual: "WARNING" },
    { scenario: "one", id: "removed", occurrence: 1, expected: "SUCCESS", actual: null },
    { scenario: "one", id: "new", occurrence: 1, expected: null, actual: "SUCCESS" },
  ];
  for (const runner of runners) assert.equal(await h.summarize("failure", summary, runner), "difference\n");
  const calls = await h.report();
  assert.equal(calls.length, 2);
  assert.deepEqual(calls[1].args.slice(0, 4), ["issue", "create", "--title", title()]);
  const { body } = calls[1];
  for (const expected of ["alpha.12", "alpha.13", "abc123", "scenario:recovered",
    "one:changed[2]: SUCCESS -> WARNING", "one:removed[1]: SUCCESS -> absent",
    "one:new[1]: absent -> SUCCESS", "conformance-canary-alpha-server",
    "conformance-canary-upstream-main-server", "https://github.com/owner/repo/actions/runs/123"]) {
    assert.ok(body.includes(expected), expected);
  }
});

test("a subsequent difference comments on the existing lane issue", async (t) => {
  const h = await harness(t, [{ number: 42, title: title("client") }, { number: 43, title: title() }]);
  await h.summarize("failure", null, "alpha", "client");
  const calls = await h.report();
  assert.deepEqual(calls[1].args.slice(0, 3), ["issue", "comment", "42"]);
  assert.ok(calls[1].body.includes("No valid baseline summary"));
});

test("setup failures and failures after a matching summary are execution errors", async (t) => {
  const h = await harness(t);
  assert.equal(await h.summarize("skipped", null), "error\n");
  assert.equal(await h.summarize("failure", matching(), "upstream-main"), "error\n");
  const calls = await h.report();
  assert.ok(calls[1].body.includes("setup failure, runner crash, or timeout"));
  assert.ok(calls[1].body.includes("lane failed after producing its summary"));
});

test("missing artifacts report the affected lane rather than silently succeeding", async (t) => {
  const h = await harness(t);
  await rm(path.join(h.artifacts, "alpha--server-plug.status"));
  const calls = await h.report();
  assert.equal(calls.length, 2);
  assert.equal(calls[1].args[3], title("server-plug"));
  assert.ok(calls[1].body.includes("no report artifact"));
});

test("large reports fit GitHub issue limits and retain the run link", async (t) => {
  const h = await harness(t);
  await h.summarize("failure", null);
  await writeFile(path.join(h.artifacts, "alpha--server.md"), "evidence\n".repeat(10000));
  const calls = await h.report();
  assert.ok(Buffer.byteLength(calls[1].body) < 65536);
  assert.ok(calls[1].body.includes("Report truncated"));
  assert.ok(calls[1].body.includes("https://github.com/owner/repo/actions/runs/123"));
});
