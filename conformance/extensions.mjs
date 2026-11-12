// Extension scenarios that the frozen requirement sets do not list. run.mjs
// runs each one with --scenario in the lanes that name it, and both run.mjs
// and the runner-script tests add them to the manifest as unscored, so the
// tests score retained evidence exactly as the lane does.
export const skillsServerScenarios = ["sep-2640-skills-directory", "sep-2640-skills-enumeration",
  "sep-2640-skills-manifest"];
export const skillsClientScenarios = ["sep-2640-client-no-prefetch", "sep-2640-client-verify-digest",
  "sep-2640-client-verify-size", "sep-2640-client-verify-frontmatter"];

export function withExtensions(manifest, leg, scenarios) {
  return { ...manifest, not_scored: [...manifest.not_scored, ...scenarios.map((scenario) =>
    ({ scenario, leg, reason: "extension", note: "not in the frozen requirement set; run with --scenario" }))] };
}
