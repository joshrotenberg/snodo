import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import { parse } from "yaml";
import { skillsClientScenarios, skillsServerScenarios, withExtensions } from "../extensions.mjs";
import { summarize } from "../report.mjs";

const manifest = { server: ["one"], not_scored: [{ scenario: "optional", leg: "server", reason: "extension" }] };
const check = (id, status) => ({ id, status });
const good = () => ({ one: [check("behavior", "SUCCESS"), check("wire-schema-valid", "SUCCESS")],
  optional: [check("feature", "SUCCESS")] });

function baselineFor(results, overrides = {}) {
  const checkInventory = Object.fromEntries(Object.entries(results).map(([scenario, checks]) => {
    const entries = {};
    for (const { id, status } of checks) (entries[id] ??= []).push(status);
    return [scenario, entries];
  }));
  return { failures: [], exclusions: [], checkInventory, ...overrides };
}

test("separates required and unscored results", () => {
  const results = good();
  results.optional = [check("feature", "FAILURE")];
  const report = summarize(manifest, results);
  assert.equal(report.score.passedScenarios, 1);
  assert.equal(report.requiredCheckCounts.failure, 0);
  assert.equal(report.regression.passed, false);
});

test("baseline failures remain failures; unexpected and stale entries fail", () => {
  const results = good();
  results.one[0].status = "FAILURE";
  const baseline = baselineFor(results, { failures: [{ key: "one:behavior", reason: "known gap" }] });
  assert.equal(summarize(manifest, results, baseline).regression.passed, true);
  assert.equal(summarize(manifest, results, baseline).score.passedScenarios, 0);
  assert.deepEqual(summarize(manifest, good(), baseline).regression.staleFailures, ["one:behavior"]);
  results.one.push(check("new", "FAILURE"));
  assert.deepEqual(summarize(manifest, results, baseline).regression.unexpectedFailures, ["one:new"]);
});

test("missing fixtures and schema-only successes cannot inflate score", () => {
  for (const checks of [[check("wire-schema-valid", "SUCCESS")],
    [check("behavior", "SUCCESS"), check("not-tested", "WARNING")],
    [check("behavior", "SUCCESS"), check("not-tested", "SKIPPED")]]) {
    const results = { ...good(), one: checks };
    const report = summarize(manifest, results);
    assert.equal(report.score.passedScenarios, 0);
    assert.equal(report.rawRunnerNoFailure.scenarios, 1);
    assert.deepEqual(report.regression.unexpectedExclusions, ["one"]);
  }
});

test("missing, empty, unknown results and invalid baseline are rejected", () => {
  assert.throws(() => summarize(manifest, { one: good().one }));
  assert.throws(() => summarize(manifest, { ...good(), extra: good().one }));
  assert.throws(() => summarize(manifest, { ...good(), one: [] }));
  assert.throws(() => summarize(manifest, { ...good(), one: [check("a", "UNKNOWN")] }));
  assert.throws(() => summarize(manifest, good(), { failures: [{ key: "x" }], exclusions: [] }));
});

test("repeated upstream check IDs preserve individual failure occurrences", () => {
  const report = summarize(manifest, { ...good(), one: [check("a", "SUCCESS"), check("a", "FAILURE")] });
  assert.deepEqual(report.failures, ["one:a[2]"]);
  assert.equal(report.requiredCheckCounts.failure, 1);
});

test("stale exclusions cannot hide recovered coverage", () => {
  const report = summarize(manifest, good(), { failures: [], exclusions: [{ key: "one", reason: "fixture absent" }] });
  assert.equal(report.regression.passed, false);
  assert.deepEqual(report.regression.staleExclusions, ["one"]);
});

test("dropping a successful check fails even when the whole scenario still scores as passing", () => {
  const results = good();
  results.one.push(check("other-behavior", "SUCCESS"));
  const baseline = baselineFor(results);
  results.one.shift();
  const report = summarize(manifest, results, baseline);
  assert.equal(report.score.passedScenarios, 1);
  assert.equal(report.regression.passed, false);
  assert.deepEqual(report.regression.checkStatusDrift, [
    { scenario: "one", id: "behavior", occurrence: 1, expected: "SUCCESS", actual: null },
  ]);
});

test("new skips and warnings in an already-failing required scenario fail the gate", () => {
  for (const status of ["SKIPPED", "WARNING"]) {
    const results = good();
    results.one.push(check("known-gap", "FAILURE"));
    const baseline = baselineFor(results, { failures: [{ key: "one:known-gap", reason: "known" }] });
    results.one[0].status = status;
    const report = summarize(manifest, results, baseline);
    assert.deepEqual(report.regression.unexpectedFailures, []);
    assert.deepEqual(report.regression.unexpectedExclusions, []);
    assert.equal(report.regression.passed, false);
    assert.equal(report.regression.checkStatusDrift[0].actual, status);
  }
});

test("repeated check IDs retain exact ordered status occurrences", () => {
  const results = { ...good(), one: [check("repeated", "SUCCESS"), check("repeated", "FAILURE")] };
  const baseline = baselineFor(results, { failures: [{ key: "one:repeated[2]", reason: "known" }] });
  assert.equal(summarize(manifest, results, baseline).regression.passed, true);
  const changed = structuredClone(results);
  changed.one[0].status = "SKIPPED";
  assert.deepEqual(summarize(manifest, changed, baseline).regression.checkStatusDrift, [
    { scenario: "one", id: "repeated", occurrence: 1, expected: "SUCCESS", actual: "SKIPPED" },
  ]);
  changed.one = [check("repeated", "SUCCESS")];
  assert.deepEqual(summarize(manifest, changed, baseline).regression.checkStatusDrift, [
    { scenario: "one", id: "repeated", occurrence: 2, expected: "FAILURE", actual: null },
  ]);
  changed.one = [...results.one, check("repeated", "SUCCESS")];
  assert.deepEqual(summarize(manifest, changed, baseline).regression.checkStatusDrift, [
    { scenario: "one", id: "repeated", occurrence: 3, expected: null, actual: "SUCCESS" },
  ]);
});

test("missing inventory cannot silently opt out and malformed inventory is rejected", () => {
  assert.equal(summarize(manifest, good(), { failures: [], exclusions: [] }).regression.passed, false);
  for (const checkInventory of [[], { one: [] }, { one: {} }, { one: { behavior: [] } },
    { one: { behavior: ["UNKNOWN"] } }]) {
    assert.throws(() => summarize(manifest, good(), { failures: [], exclusions: [], checkInventory }));
  }
});

test("the client leg scores only its own required and unscored scenarios", () => {
  const legs = { server: ["one"], client: ["call"],
    not_scored: [{ scenario: "optional", leg: "server", reason: "extension" },
      { scenario: "auth/optional", leg: "client", reason: "extension" }] };
  const results = { call: [check("behavior", "SUCCESS")], "auth/optional": [check("token", "FAILURE")] };
  const baseline = baselineFor(results, { failures: [{ key: "auth/optional:token", reason: "no OAuth" }] });
  const report = summarize(legs, results, baseline, "client");
  assert.equal(report.score.requiredScenarios, 1);
  assert.equal(report.score.passedScenarios, 1);
  assert.equal(report.regression.passed, true);
  assert.throws(() => summarize(legs, results, baseline, "server"));
  assert.throws(() => summarize(legs, results, baseline, "authorization"));
});

async function frozenEvidence(results = "2026-10-22-alpha.12-checks.json", baseline = "expected-failures.json",
  revision = "2026-07-28") {
  const json = async (file) => JSON.parse(await readFile(new URL(file, import.meta.url), "utf8"));
  return {
    manifest: parse(await readFile(new URL(`../requirements/${revision}.yaml`, import.meta.url), "utf8")),
    results: await json(`../results/${results}`),
    baseline: await json(`../${baseline}`),
  };
}

// The 2026-07-28 lanes also run the SEP-2640 extension scenarios, so their
// retained evidence is scored with the same unscored entries run.mjs adds.
const lanes2026 = {
  server: ["2026-11-12-alpha.12-checks.json", "expected-failures.json", skillsServerScenarios],
  client: ["2026-11-12-client-alpha.12-checks.json", "expected-failures-client.json", skillsClientScenarios],
};

async function laneEvidence(leg) {
  const [results, baseline, extensions] = lanes2026[leg];
  const evidence = await frozenEvidence(results, baseline);
  return { ...evidence, manifest: withExtensions(evidence.manifest, leg, extensions) };
}

// The server checks that fail because the runner does not declare the skills
// extension (option B on #398). They are the only expected server failures.
const optionBFailures = [
  "sep-2640-skills-directory:sep-2640-directory-read-invalid-params",
  "sep-2640-skills-directory:sep-2640-directory-read-method-registered",
  "sep-2640-skills-directory:sep-2640-directory-read-pagination",
  "sep-2640-skills-directory:sep-2640-directory-read-result-resources-shape",
  "sep-2640-skills-directory:sep-2640-directory-read-subdir-mimetype",
  "sep-2640-skills-enumeration:sep-2640-capability-commits-to-methods",
  "sep-2640-skills-enumeration:sep-2640-skills-list-implemented",
];

test("the complete frozen check inventory passes and its score is the runner's, not a waiver", async () => {
  const evidence = await laneEvidence("server");
  assert.equal(Object.keys(evidence.baseline.checkInventory).length, 53);
  const report = summarize(evidence.manifest, evidence.results, evidence.baseline);
  assert.equal(report.regression.passed, true);
  assert.deepEqual(report.regression.checkStatusDrift, []);
  assert.equal(report.score.passedScenarios, 37);
  assert.equal(report.score.status, "complete");
  assert.equal(report.regression.unexpectedFailures.length, 0);
  // No required scenario has an expected failure; the only ones are option B,
  // in unscored extension scenarios.
  assert.deepEqual(evidence.baseline.failures.map((entry) => entry.key).sort(), optionBFailures);
  assert.deepEqual([...report.failures].sort(), optionBFailures);
  const skills = report.notScored.filter((entry) => skillsServerScenarios.includes(entry.scenario));
  assert.deepEqual(skills.map((entry) => entry.reason), ["extension", "extension", "extension"]);
});

test("the option-B skills failures do not mask a skills regression on either leg", async () => {
  const server = await laneEvidence("server");
  for (const check of server.results["sep-2640-skills-manifest"]) {
    if (check.id === "sep-2640-skillmd-mimetype") check.status = "FAILURE";
  }
  const serverReport = summarize(server.manifest, server.results, server.baseline);
  assert.equal(serverReport.regression.passed, false);
  assert.deepEqual(serverReport.regression.unexpectedFailures,
    ["sep-2640-skills-manifest:sep-2640-skillmd-mimetype"]);
  assert.deepEqual(serverReport.regression.staleFailures, []);
  assert.equal(serverReport.score.passedScenarios, 37);

  const client = await laneEvidence("client");
  client.results["sep-2640-client-verify-digest"][0].status = "FAILURE";
  const clientReport = summarize(client.manifest, client.results, client.baseline, "client");
  assert.equal(clientReport.regression.passed, false);
  assert.deepEqual(clientReport.regression.unexpectedFailures,
    ["sep-2640-client-verify-digest:sep-2640-host-verify-digest"]);
  assert.equal(clientReport.score.passedScenarios, 31);
});

test("the Tasks lifecycle success-to-skipped regression is caught though the scenario is unscored", async () => {
  const evidence = await laneEvidence("server");
  for (const check of evidence.results["tasks-lifecycle"]) {
    if (check.status === "SUCCESS") check.status = "SKIPPED";
  }
  const report = summarize(evidence.manifest, evidence.results, evidence.baseline);
  assert.equal(report.regression.passed, false);
  assert.deepEqual(report.regression.unexpectedFailures, []);
  assert.equal(report.regression.checkStatusDrift.length, 9);
  assert.equal(report.score.passedScenarios, 37);
});

test("a sampling or roots check that fails again is a new failure, not a stale baseline entry", async () => {
  const evidence = await laneEvidence("server");
  const regressed = ["input-required-result-basic-sampling", "input-required-result-basic-list-roots",
    "input-required-result-multiple-input-requests", "input-required-result-capability-check"];
  for (const scenario of regressed) evidence.results[scenario][0].status = "FAILURE";
  for (const check of evidence.results["server-stateless"]) {
    if (check.id === "sep-2575-server-rejects-undeclared-capability") check.status = "FAILURE";
  }
  const report = summarize(evidence.manifest, evidence.results, evidence.baseline);
  assert.equal(report.regression.passed, false);
  assert.equal(report.regression.unexpectedFailures.length, 5);
  assert.ok(report.regression.unexpectedFailures.every((key) => !key.startsWith("sep-2640-")));
  assert.deepEqual(report.regression.staleFailures, []);
  assert.equal(report.score.passedScenarios, 32);
  assert.equal(report.score.status, "partial");
});

test("the frozen client check inventory passes without waiving its partial score", async () => {
  const evidence = await laneEvidence("client");
  assert.equal(Object.keys(evidence.baseline.checkInventory).length, 43);
  const report = summarize(evidence.manifest, evidence.results, evidence.baseline, "client");
  assert.equal(report.regression.passed, true);
  assert.deepEqual(report.regression.checkStatusDrift, []);
  assert.deepEqual(report.regression.staleExclusions, []);
  assert.equal(report.score.passedScenarios, 31);
  assert.equal(report.score.status, "partial");
  assert.ok(report.score.passedScenarioIds.includes("request-metadata"));
  assert.equal(evidence.baseline.failures.length, 11);
});

test("a regression in the Mcp-Param checks fails the client gate", async () => {
  const evidence = await laneEvidence("client");
  for (const check of evidence.results["http-custom-headers"]) {
    if (check.id !== "sep-2243-client-omit-null") check.status = "FAILURE";
  }
  const report = summarize(evidence.manifest, evidence.results, evidence.baseline, "client");
  assert.equal(report.regression.passed, false);
  assert.equal(report.regression.unexpectedFailures.length, 17);
  assert.equal(report.score.passedScenarios, 30);
});

test("a client that stops declaring sampling or roots is drift, not an allowed skip", async () => {
  const evidence = await laneEvidence("client");
  for (const check of evidence.results["request-metadata"]) {
    if (check.id.startsWith("sep-2575-client-declares-")) check.status = "SKIPPED";
  }
  const report = summarize(evidence.manifest, evidence.results, evidence.baseline, "client");
  assert.equal(report.regression.passed, false);
  assert.equal(report.regression.checkStatusDrift.length, 3);
  assert.deepEqual(report.regression.unexpectedFailures, []);
  assert.equal(report.score.passedScenarios, 30);
});

test("an auth check that regresses to a warning fails the client gate", async () => {
  const evidence = await laneEvidence("client");
  for (const check of evidence.results["auth/scope-step-up"]) {
    if (check.id === "sep-2350-scope-union-on-reauth") check.status = "WARNING";
  }
  const report = summarize(evidence.manifest, evidence.results, evidence.baseline, "client");
  assert.equal(report.regression.passed, false);
  assert.deepEqual(report.regression.unexpectedFailures, []);
  assert.equal(report.regression.checkStatusDrift.length, 1);
  assert.equal(report.score.passedScenarios, 30);
});

test("the frozen 2025-11-25 sessionless lane inventory passes without waiving its partial score", async () => {
  const evidence = await frozenEvidence("2026-10-29-2025-11-25-sessionless-alpha.12-checks.json",
    "expected-failures-2025-11-25-sessionless.json", "2025-11-25");
  const report = summarize(evidence.manifest, evidence.results, evidence.baseline);
  assert.equal(report.regression.passed, true);
  assert.equal(report.score.requiredScenarios, 30);
  assert.equal(report.score.passedScenarios, 23);
  assert.equal(report.score.status, "partial");
});

test("the frozen 2025-11-25 session lane passes every required scenario", async () => {
  const evidence = await frozenEvidence("2026-10-29-2025-11-25-alpha.12-checks.json",
    "expected-failures-2025-11-25.json", "2025-11-25");
  const report = summarize(evidence.manifest, evidence.results, evidence.baseline);
  assert.equal(report.regression.passed, true);
  assert.equal(report.score.passedScenarios, 30);
  assert.equal(report.score.status, "complete");
  // The sessionless evidence does not satisfy the session lane's baseline.
  const sessionless = await frozenEvidence("2026-10-29-2025-11-25-sessionless-alpha.12-checks.json",
    "expected-failures-2025-11-25.json", "2025-11-25");
  assert.equal(summarize(sessionless.manifest, sessionless.results, sessionless.baseline).regression.passed,
    false);
});

test("the 2025-06-18 lane scores nothing, and its inventory still gates", async () => {
  const json = async (file) => JSON.parse(await readFile(new URL(file, import.meta.url), "utf8"));
  const results = await json("../results/2026-10-29-2025-06-18-alpha.12-checks.json");
  const baseline = await json("../expected-failures-2025-06-18.json");
  const manifest = { server: [], not_scored: Object.keys(results).map((scenario) =>
    ({ scenario, leg: "server", reason: "no frozen requirement set for 2025-06-18" })) };
  const report = summarize(manifest, results, baseline);
  assert.equal(report.regression.passed, true);
  assert.equal(report.score.requiredScenarios, 0);
  assert.equal(report.notScored.length, 27);
  results["tools-list"][0].status = "FAILURE";
  assert.equal(summarize(manifest, results, baseline).regression.passed, false);
});
