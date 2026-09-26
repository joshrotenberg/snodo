import assert from "node:assert/strict";

const statuses = ["SUCCESS", "FAILURE", "SKIPPED", "WARNING", "INFO"];

// Keep the official result, fixture coverage, and CI regression policy distinct.
// A schema-only success or warning from a missing fixture is not an exercised pass.
export function summarize(manifest, scenarios, baseline = { failures: [], exclusions: [], checkInventory: {} },
  leg = "server") {
  assert.ok(["server", "client"].includes(leg), `unknown leg: ${leg}`);
  const required = manifest[leg];
  const unscored = manifest.not_scored.filter((entry) => entry.leg === leg);
  const expected = [...required, ...unscored.map((entry) => entry.scenario)];
  assert.equal(new Set(expected).size, expected.length, "duplicate manifest scenario");
  assert.deepEqual(Object.keys(scenarios).sort(), [...expected].sort(), "missing/extra scenario results");
  const failures = [];
  const excluded = [];
  const passed = [];
  const rawPass = [];
  const checkInventory = {};
  const requiredCheckCounts = Object.fromEntries(statuses.map((status) => [status.toLowerCase(), 0]));
  for (const scenario of expected) {
    const checks = scenarios[scenario];
    assert.ok(Array.isArray(checks) && checks.length > 0, `empty checks: ${scenario}`);
    const totals = new Map();
    for (const check of checks) totals.set(check.id, (totals.get(check.id) ?? 0) + 1);
    const occurrences = new Map();
    const inventory = {};
    for (const check of checks) {
      assert.equal(typeof check.id, "string", `missing check ID: ${scenario}`);
      assert.ok(check.id.length > 0, `empty check ID: ${scenario}`);
      const occurrence = (occurrences.get(check.id) ?? 0) + 1;
      occurrences.set(check.id, occurrence);
      // alpha.11 repeats IDs for several parameterized checks. Keep each
      // occurrence, rather than dropping failures in a map keyed only by ID.
      const key = `${scenario}:${check.id}${totals.get(check.id) > 1 ? `[${occurrence}]` : ""}`;
      assert.ok(statuses.includes(check.status), `invalid status: ${scenario}:${check.id}`);
      if (!Object.hasOwn(inventory, check.id)) {
        Object.defineProperty(inventory, check.id, { value: [], enumerable: true });
      }
      inventory[check.id].push(check.status);
      if (required.includes(scenario)) requiredCheckCounts[check.status.toLowerCase()]++;
      if (check.status === "FAILURE") failures.push(key);
    }
    Object.defineProperty(checkInventory, scenario, { value: inventory, enumerable: true });
    if (!checks.some((check) => check.status === "FAILURE")) {
      const uncertain = checks.some((check) => ["SKIPPED", "WARNING"].includes(check.status));
      const semantic = checks.some((check) => check.status === "SUCCESS" && check.id !== "wire-schema-valid");
      if (required.includes(scenario)) {
        rawPass.push(scenario);
        if (uncertain || !semantic) {
          excluded.push(scenario);
        } else {
          passed.push(scenario);
        }
      }
    }
  }
  const declaredFailures = validateBaseline(baseline.failures, "failure");
  const declaredExclusions = validateBaseline(baseline.exclusions, "exclusion");
  const unexpectedFailures = failures.filter((key) => !declaredFailures.has(key));
  const staleFailures = [...declaredFailures].filter((key) => !failures.includes(key));
  const unexpectedExclusions = excluded.filter((key) => !declaredExclusions.has(key));
  const staleExclusions = [...declaredExclusions].filter((key) => !excluded.includes(key));
  const checkStatusDrift = compareInventory(checkInventory, baseline.checkInventory ?? {});
  return {
    score: {
      status: passed.length === required.length ? "complete" : "partial",
      basis: "whole required scenarios with semantic success and no FAILURE, WARNING, or SKIPPED checks",
      passedScenarios: passed.length,
      requiredScenarios: required.length,
      passedScenarioIds: passed,
    },
    requiredCheckCounts,
    rawRunnerNoFailure: {
      scenarios: rawPass.length, requiredScenarios: required.length, scenarioIds: rawPass,
      excludedFromScore: excluded.map((scenario) => ({
        scenario, reason: "warning/skipped checks or no semantic success; not an exercised whole-scenario pass",
      })),
    },
    notScored: unscored.map((entry) => ({
      ...entry,
      checks: Object.fromEntries(statuses.map((status) => [
        status.toLowerCase(), scenarios[entry.scenario].filter((check) => check.status === status).length,
      ])),
    })),
    failures,
    regression: {
      passed: [unexpectedFailures, staleFailures, unexpectedExclusions, staleExclusions, checkStatusDrift].every((items) => items.length === 0),
      unexpectedFailures, staleFailures, unexpectedExclusions, staleExclusions,
      checkStatusDrift,
      note: "A passing regression gate does not convert expected failures into conformance passes.",
    },
  };
}

function compareInventory(actual, expected) {
  assert.ok(expected && typeof expected === "object" && !Array.isArray(expected), "baseline checkInventory must be an object");
  for (const [scenario, checks] of Object.entries(expected)) {
    assert.ok(checks && typeof checks === "object" && !Array.isArray(checks), `invalid baseline check inventory: ${scenario}`);
    assert.ok(Object.keys(checks).length > 0, `empty baseline check inventory: ${scenario}`);
    for (const [id, occurrences] of Object.entries(checks)) {
      assert.ok(id.length > 0 && Array.isArray(occurrences) && occurrences.length > 0,
        `invalid baseline check occurrences: ${scenario}:${id}`);
      assert.ok(occurrences.every((status) => statuses.includes(status)), `invalid baseline check status: ${scenario}:${id}`);
    }
  }
  const drift = [];
  for (const scenario of new Set([...Object.keys(expected), ...Object.keys(actual)])) {
    const expectedChecks = Object.hasOwn(expected, scenario) ? expected[scenario] : {};
    const actualChecks = Object.hasOwn(actual, scenario) ? actual[scenario] : {};
    for (const id of new Set([...Object.keys(expectedChecks), ...Object.keys(actualChecks)])) {
      const before = Object.hasOwn(expectedChecks, id) ? expectedChecks[id] : [];
      const after = Object.hasOwn(actualChecks, id) ? actualChecks[id] : [];
      for (let index = 0; index < Math.max(before.length, after.length); index++) {
        if (before[index] !== after[index]) {
          drift.push({ scenario, id, occurrence: index + 1,
            expected: before[index] ?? null, actual: after[index] ?? null });
        }
      }
    }
  }
  return drift;
}

function validateBaseline(entries, kind) {
  assert.ok(Array.isArray(entries), `baseline ${kind} entries must be an array`);
  const keys = new Set();
  for (const entry of entries) {
    assert.equal(typeof entry.key, "string");
    assert.ok(typeof entry.reason === "string" && entry.reason.trim(), "baseline reason required");
    assert.ok(!keys.has(entry.key), `duplicate baseline ${kind}: ${entry.key}`);
    keys.add(entry.key);
  }
  return keys;
}

export function renderMarkdown(report) {
  const { score, regression } = report;
  const list = (items) => items.length ? items.map((item) => `- \`${item}\``).join("\n") : "None.";
  return `# Frozen ${report.protocolVersion} ${report.leg ?? "server"} conformance run

Run date: ${report.runDate}  
Runner: \`${report.runner}\`  
Requirements SHA-256: \`${report.requirements.requirementsSha256}\`

## Exercised score

**${score.passedScenarios}/${score.requiredScenarios}** required scenarios pass.
${score.basis}. The runner also attempts extension and pending scenarios separately.
Raw runner exit code: **${report.runnerExitCode}**. Regression gate: **${regression.passed ? "pass" : "fail"}**.
A passing regression gate does not mean full protocol conformance.

Required checks: ${Object.entries(report.requiredCheckCounts).map(([status, count]) => `${count} ${status}`).join(", ")}.

## Passing required scenarios

${list(score.passedScenarioIds)}

## Remaining failing checks (including unscored lanes)

${list(report.failures)}

## Unscored scenarios

${report.notScored.map((entry) => `- \`${entry.scenario}\` (${entry.reason}): ${Object.entries(entry.checks).map(([status, count]) => `${count} ${status}`).join(", ")}`).join("\n")}

## Regression policy changes needed

Unexpected failures: ${regression.unexpectedFailures.length}; stale failure entries: ${regression.staleFailures.length}; unexpected exclusions: ${regression.unexpectedExclusions.length}; stale exclusions: ${regression.staleExclusions.length}; check status/inventory changes: ${regression.checkStatusDrift.length}.
See the JSON companion and raw check artifacts for exact outcomes. The baseline pins every check ID and status occurrence, including unscored scenarios. Missing, new, or changed checks require review; they never increase the exercised score.
`;
}
