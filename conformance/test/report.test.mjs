import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import { parse } from "yaml";
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

async function frozenEvidence() {
  const json = async (file) => JSON.parse(await readFile(new URL(file, import.meta.url), "utf8"));
  return {
    manifest: parse(await readFile(new URL("../requirements/2026-07-28.yaml", import.meta.url), "utf8")),
    results: await json("../results/2026-09-26-alpha.11-checks.json"),
    baseline: await json("../expected-failures.json"),
  };
}

test("the complete frozen check inventory passes without waiving its partial conformance score", async () => {
  const evidence = await frozenEvidence();
  assert.equal(Object.keys(evidence.baseline.checkInventory).length, 50);
  const report = summarize(evidence.manifest, evidence.results, evidence.baseline);
  assert.equal(report.regression.passed, true);
  assert.deepEqual(report.regression.checkStatusDrift, []);
  assert.equal(report.score.passedScenarios, 32);
  assert.equal(report.score.status, "partial");
});

test("the Tasks lifecycle success-to-skipped regression is caught despite its expected wire failure", async () => {
  const evidence = await frozenEvidence();
  for (const check of evidence.results["tasks-lifecycle"]) {
    if (check.status === "SUCCESS") check.status = "SKIPPED";
  }
  const report = summarize(evidence.manifest, evidence.results, evidence.baseline);
  assert.equal(report.regression.passed, false);
  assert.deepEqual(report.regression.unexpectedFailures, []);
  assert.equal(report.regression.checkStatusDrift.length, 8);
  assert.equal(report.score.passedScenarios, 32);
});
