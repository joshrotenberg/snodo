import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import Ajv2020 from "ajv/dist/2020.js";

export const provenance = JSON.parse(readFileSync(new URL("provenance.json", import.meta.url)));
const bytes = readFileSync(new URL("schema.json", import.meta.url));
const license = readFileSync(new URL("SCHEMA_LICENSE", import.meta.url));
const digest = (value) => createHash("sha256").update(value).digest("hex");
assert.equal(digest(bytes), provenance.sha256, "vendored schema digest changed");
assert.equal(digest(license), provenance.licenseSha256, "vendored license digest changed");
export const schema = JSON.parse(bytes);

// Do not mutate input or load remote references. Formats are annotations in
// this lane; lifecycle and application-schema validation are separate lanes.
const ajv = new Ajv2020({
  allErrors: true,
  strict: false,
  validateFormats: false,
  useDefaults: false,
  coerceTypes: false,
  removeAdditional: false,
});
const schemaId = `urn:snodo:pinned-wire-schema:${provenance.commit}`;
ajv.addSchema(schema, schemaId);

export function validator(definition) {
  assert.ok(Object.hasOwn(schema.$defs, definition), `unknown named definition: ${definition}`);
  return ajv.getSchema(`${schemaId}#/$defs/${definition}`);
}

export function validate(definition, value) {
  const check = validator(definition);
  const before = JSON.stringify(value);
  assert.ok(check(value), `${definition}: ${ajv.errorsText(check.errors, { separator: "; " })}`);
  assert.equal(JSON.stringify(value), before, "validation mutated the wire value");
}

const results = {
  "server/discover": ["DiscoverResultResponse", "DiscoverResult"],
  "tools/list": ["ListToolsResultResponse", "ListToolsResult"],
  "tools/call": ["CallToolResultResponse", "CallToolResult"],
  "resources/list": ["ListResourcesResultResponse", "ListResourcesResult"],
  "resources/templates/list": ["ListResourceTemplatesResultResponse", "ListResourceTemplatesResult"],
  "resources/read": ["ReadResourceResultResponse", "ReadResourceResult"],
  "prompts/list": ["ListPromptsResultResponse", "ListPromptsResult"],
  "prompts/get": ["GetPromptResultResponse", "GetPromptResult"],
  "completion/complete": ["CompleteResultResponse", "CompleteResult"],
  "subscriptions/listen": ["SubscriptionsListenResultResponse", "SubscriptionsListenResult"],
};
const notifications = {
  "notifications/progress": "ProgressNotification",
  "notifications/subscriptions/acknowledged": "SubscriptionsAcknowledgedNotification",
  "notifications/tools/list_changed": "ToolListChangedNotification",
  "notifications/resources/updated": "ResourceUpdatedNotification",
  "notifications/cancelled": "CancelledNotification",
};

export function validateEmission(method, message) {
  if (Object.hasOwn(message, "method")) {
    assert.ok(notifications[message.method], `unmapped notification ${message.method}`);
    validate(notifications[message.method], message);
    return [notifications[message.method]];
  }
  if (Object.hasOwn(message, "error")) {
    validate("JSONRPCErrorResponse", message);
    return ["JSONRPCErrorResponse"];
  }
  assert.ok(results[method], `unmapped response method ${method}`);
  const [response, complete] = results[method];
  validate(response, message);
  // Several official response anyOf branches admit {resultType:string} as
  // InputRequiredResult. Validate the actual branch too, or malformed complete
  // results could pass through that more permissive alternative.
  const payload = message.result.resultType === "input_required" ? "InputRequiredResult" : complete;
  assert.ok(["input_required", "complete"].includes(message.result.resultType), "unexpected resultType");
  validate(payload, message.result);
  return [response, payload];
}
