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
// SEP-2640 skills results. The pinned core schema defines no skills messages,
// and this lane does not invent one, so each result is checked against the
// pinned generic definitions it extends: the result envelope, the cacheable
// and paginated result bases, and Resource for each directory child. The
// skill entry itself (uri, frontmatter, resources) has no pinned definition;
// only its JSON container shape is asserted here.
const extensionResults = {
  "skills/list": ["CacheableResult", "PaginatedResult"],
  "skills/get": ["CacheableResult"],
  "resources/directory/read": ["CacheableResult", "PaginatedResult"],
};
const notifications = {
  "notifications/progress": "ProgressNotification",
  "notifications/subscriptions/acknowledged": "SubscriptionsAcknowledgedNotification",
  "notifications/tools/list_changed": "ToolListChangedNotification",
  "notifications/resources/updated": "ResourceUpdatedNotification",
  "notifications/cancelled": "CancelledNotification",
};
// The InputRequest union admits any of the three embedded request kinds; the
// concrete branch is validated too, so a request that matches a sibling's
// looser shape cannot pass as the kind its method names.
const inputRequests = {
  "elicitation/create": "ElicitRequest",
  "sampling/createMessage": "CreateMessageRequest",
  "roots/list": "ListRootsRequest",
};
// Named error definitions. The MCP-specific ones are whole responses, whose
// `data` shape matters (requiredCapabilities is a ClientCapabilities object);
// the JSON-RPC ones describe only the error member.
const errors = {
  [-32020]: { definition: "HeaderMismatchError", envelope: true },
  [-32021]: { definition: "MissingRequiredClientCapabilityError", envelope: true },
  [-32022]: { definition: "UnsupportedProtocolVersionError", envelope: true },
  [-32600]: { definition: "InvalidRequestError", envelope: false },
  [-32601]: { definition: "MethodNotFoundError", envelope: false },
  [-32602]: { definition: "InvalidParamsError", envelope: false },
  [-32603]: { definition: "InternalError", envelope: false },
  [-32700]: { definition: "ParseError", envelope: false },
};

function validateExtensionResult(method, message) {
  validate("JSONRPCResultResponse", message);
  assert.equal(message.result.resultType, "complete", "unexpected resultType");
  const names = ["JSONRPCResultResponse"];
  for (const definition of extensionResults[method]) {
    validate(definition, message.result);
    names.push(definition);
  }
  const object = (value) => value !== null && typeof value === "object" && !Array.isArray(value);
  const entry = (skill) => {
    assert.ok(object(skill) && typeof skill.uri === "string" && object(skill.frontmatter), "malformed skill entry");
    assert.ok(skill.resources === "dynamic" || Array.isArray(skill.resources), "malformed skill resources");
  };
  if (method === "skills/list") {
    assert.ok(Array.isArray(message.result.skills), "skills/list result needs a skills array");
    message.result.skills.forEach(entry);
  } else if (method === "skills/get") {
    entry(message.result.skill);
    assert.equal(message.result.nextCursor, undefined, "skills/get carries no cursor");
  } else {
    assert.ok(Array.isArray(message.result.resources), "directory read needs a resources array");
    for (const child of message.result.resources) validate("Resource", child);
    names.push("Resource");
  }
  return names;
}

export function validateEmission(method, message) {
  if (Object.hasOwn(message, "method")) {
    assert.ok(notifications[message.method], `unmapped notification ${message.method}`);
    validate(notifications[message.method], message);
    return [notifications[message.method]];
  }
  if (Object.hasOwn(message, "error")) {
    validate("JSONRPCErrorResponse", message);
    const concrete = errors[message.error?.code];
    if (!concrete) return ["JSONRPCErrorResponse"];
    validate(concrete.definition, concrete.envelope ? message : message.error);
    return ["JSONRPCErrorResponse", concrete.definition];
  }
  if (extensionResults[method]) return validateExtensionResult(method, message);
  assert.ok(results[method], `unmapped response method ${method}`);
  const [response, complete] = results[method];
  validate(response, message);
  // Several official response anyOf branches admit {resultType:string} as
  // InputRequiredResult. Validate the actual branch too, or malformed complete
  // results could pass through that more permissive alternative.
  const payload = message.result.resultType === "input_required" ? "InputRequiredResult" : complete;
  assert.ok(["input_required", "complete"].includes(message.result.resultType), "unexpected resultType");
  validate(payload, message.result);
  const names = [response, payload];
  if (payload === "InputRequiredResult") {
    for (const request of Object.values(message.result.inputRequests ?? {})) {
      const definition = inputRequests[request?.method];
      assert.ok(definition, `unmapped input request ${request?.method}`);
      validate(definition, request);
      if (!names.includes(definition)) names.push(definition);
    }
  }
  return names;
}
