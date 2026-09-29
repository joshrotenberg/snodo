import assert from "node:assert/strict";
import test from "node:test";
import { schema, validate, validateEmission, validator } from "./validator.mjs";

test("the upstream root is definitions-only; unknown definition names fail closed", () => {
  assert.deepEqual(Object.keys(schema).sort(), ["$defs", "$schema"]);
  assert.throws(() => validator("NotARealDefinition"), /unknown named definition/);
  assert.throws(() => validate("DiscoverResultResponse", {}));
});

test("concrete complete branch rejects malformed content despite permissive MRTR union", () => {
  const message = { jsonrpc: "2.0", id: 1, result: { resultType: "complete", content: [{ type: "text", text: "ok" }] } };
  validateEmission("tools/call", message);
  message.result.content[0].text = 123;
  // Document the real upstream union behavior rather than silently overriding it.
  assert.equal(validator("CallToolResultResponse")(message), true);
  assert.throws(() => validateEmission("tools/call", message), /CallToolResult:/);
});

test("recursive MRTR request definitions are active, not only the envelope", () => {
  const message = { jsonrpc: "2.0", id: 2, result: { resultType: "input_required", inputRequests: { choice: {
    method: "elicitation/create", params: { mode: "form", message: "Choose", requestedSchema: {
      type: "object", properties: { value: { type: "boolean" } }, required: ["value"],
    } },
  } } } };
  validateEmission("tools/call", message);
  message.result.inputRequests.choice.params.requestedSchema.properties.value.type = "bogus";
  assert.throws(() => validateEmission("tools/call", message));
});

test("embedded sampling and roots requests are validated as their concrete definitions", () => {
  const message = { jsonrpc: "2.0", id: 4, result: { resultType: "input_required", inputRequests: {
    summary: { method: "sampling/createMessage", params: {
      messages: [{ role: "user", content: { type: "text", text: "Summarize" } }], maxTokens: 32,
    } },
    client_roots: { method: "roots/list", params: {} },
  } } };
  assert.deepEqual(validateEmission("tools/call", message),
    ["CallToolResultResponse", "InputRequiredResult", "CreateMessageRequest", "ListRootsRequest"]);
  const damaged = structuredClone(message);
  damaged.result.inputRequests.summary.params.maxTokens = "32";
  assert.throws(() => validateEmission("tools/call", damaged));
  assert.throws(() => validate("CreateMessageRequest", damaged.result.inputRequests.summary), /CreateMessageRequest:/);
  const unmapped = structuredClone(message);
  unmapped.result.inputRequests.summary = { method: "logging/setLevel", params: { level: "info" } };
  assert.throws(() => validateEmission("tools/call", unmapped));
});

test("the -32021 refusal validates its named response, whose requiredCapabilities is an object", () => {
  const message = { jsonrpc: "2.0", id: 5, error: { code: -32021, message: "Missing required client capability",
    data: { requiredCapabilities: { sampling: {}, roots: {} } } } };
  assert.deepEqual(validateEmission("tools/call", message), ["JSONRPCErrorResponse", "MissingRequiredClientCapabilityError"]);
  message.error.data.requiredCapabilities = ["sampling"];
  // The generic envelope accepts any data; only the named error rejects the list.
  validate("JSONRPCErrorResponse", message);
  assert.throws(() => validateEmission("tools/call", message), /MissingRequiredClientCapabilityError/);
  const unnamed = { jsonrpc: "2.0", id: 6, error: { code: -32000, message: "Application error" } };
  assert.deepEqual(validateEmission("tools/call", unnamed), ["JSONRPCErrorResponse"]);
});

test("validation never applies defaults, coerces numbers, or drops extra keys", () => {
  const message = { jsonrpc: "2.0", id: 3, error: { code: -32602, message: "Invalid", extra: true } };
  const before = structuredClone(message);
  assert.deepEqual(validateEmission("tools/call", message), ["JSONRPCErrorResponse", "InvalidParamsError"]);
  assert.deepEqual(message, before);
  message.error.code = "-32602";
  assert.throws(() => validateEmission("tools/call", message));
  assert.equal(message.error.code, "-32602");
});

test("format remains annotation-only, while actual type constraints remain active", () => {
  const content = { uri: "not-a-uri", text: "annotation-only control" };
  validate("TextResourceContents", content);
  assert.throws(() => validate("TextResourceContents", { ...content, uri: 12 }));
});

test("cache, completion, and subscription definitions reject missing required structure", () => {
  assert.throws(() => validate("ListToolsResult", { resultType: "complete", tools: [] }));
  assert.throws(() => validate("CompleteResult", { resultType: "complete", completion: { values: [12] } }));
  assert.throws(() => validate("SubscriptionsAcknowledgedNotification", { jsonrpc: "2.0", method: "notifications/subscriptions/acknowledged", params: {} }));
  assert.throws(() => validate("SubscriptionsListenResult", { resultType: "complete" }));
});

test("progress validates the named notification and numeric fields", () => {
  const message = { jsonrpc: "2.0", method: "notifications/progress", params: {
    progressToken: "schema-progress", progress: 50, total: 100, message: "Halfway",
  } };
  validateEmission("tools/call", message);
  message.params.progress = "50";
  assert.throws(() => validateEmission("tools/call", message), /ProgressNotification/);
});
