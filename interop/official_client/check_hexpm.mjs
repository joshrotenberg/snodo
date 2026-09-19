import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { once } from "node:events";
import path from "node:path";
import { createInterface } from "node:readline";
import { fileURLToPath } from "node:url";

import { Client, StreamableHTTPClientTransport } from "@modelcontextprotocol/client";
import { StdioClientTransport } from "@modelcontextprotocol/client/stdio";

// Requires the sibling hexpm-mcp application's compiled runtime dependencies.
//   node interop/official_client/check_hexpm.mjs [--stdio|--http]
// Default: check both transports. HEXPM_MCP_BUILD_PATH selects another Mix
// build directory; MCP_EX_EBIN optionally overrides its framework dependency.
const here = path.dirname(fileURLToPath(import.meta.url));
const fixture = path.join(here, "hexpm_fixture.exs");
const project = process.env.HEXPM_MCP_PROJECT ?? path.resolve(here, "../../../hexpm-mcp");
const elixir = process.env.MCP_EX_ELIXIR ?? "elixir";
const protocol = "2026-07-28";
const requestOptions = { signal: AbortSignal.timeout(60_000) };
const elicitationCounts = new WeakMap();
const expectedTools = [
  "alternatives", "audit", "audit_mix_deps", "compare", "dep_tree", "dependencies",
  "doc_item", "docs", "downloads", "features", "health", "info", "owners", "readme",
  "release", "search", "search_docs", "toolbox_category", "toolbox_group",
  "toolbox_groups", "toolbox_search", "toolbox_trending", "upgrade_check", "versions",
].sort();
const promptCases = [
  ["analyze_package", { name: "interop_package" }, "interop_package"],
  ["compare_packages", { names: "interop_package, other" }, "interop_package, other"],
  ["evaluate_dependencies", { deps: "interop_package" }, "interop_package"],
  ["migration_guide", { from: "old_package", to: "interop_package" }, "interop_package"],
  ["package_review", { name: "interop_package", focus: "quality" }, "quality review"],
  ["recommend_packages", { use_case: "deterministic offline acceptance" }, "deterministic offline acceptance"],
];

function newClient() {
  const client = new Client(
    { name: "hexpm-mcp-official-client-check", version: "1.0.0" },
    {
      versionNegotiation: { mode: { pin: protocol } },
      capabilities: { elicitation: { form: {} } },
      inputRequired: { autoFulfill: true, maxRounds: 2 },
    },
  );
  elicitationCounts.set(client, 0);
  client.setRequestHandler("elicitation/create", async (request) => {
    elicitationCounts.set(client, elicitationCounts.get(client) + 1);
    assert.equal(request.params.mode, "form");
    assert.deepEqual(request.params.requestedSchema.properties.focus.enum, ["quality", "security", "upgrade"]);
    return { action: "accept", content: { focus: "security" } };
  });
  return client;
}

function textResult(result) {
  assert.equal(result.content?.[0]?.type, "text");
  return result.content[0].text;
}

async function jsonResource(client, uri) {
  const result = await client.readResource({ uri }, requestOptions);
  assert.equal(result.contents.length, 1);
  assert.equal(result.contents[0].uri, uri);
  assert.equal(result.contents[0].mimeType, "application/json");
  return JSON.parse(result.contents[0].text);
}

function observeToolPages(transport) {
  const ids = new Set();
  const pages = [];
  const send = transport.send.bind(transport);
  const onmessage = transport.onmessage;
  transport.send = (message, ...args) => {
    if (message.method === "tools/list") ids.add(message.id);
    return send(message, ...args);
  };
  transport.onmessage = (message, ...args) => {
    if (ids.has(message.id) && message.result) pages.push(structuredClone(message.result));
    return onmessage(message, ...args);
  };
  return pages;
}

async function exercise(client, transportName, pages) {
  assert.equal(client.getProtocolEra(), "modern");
  const discovery = await client.discover(requestOptions);
  assert.ok(discovery.supportedVersions.includes(protocol));
  assert.equal(client.getServerVersion().name, "hexpm-mcp");
  for (const capability of ["tools", "resources", "prompts", "completions"]) {
    assert.ok(Object.hasOwn(discovery.capabilities, capability));
  }

  // The official client auto-aggregates all pages when cursor is omitted.
  const listed = await client.listTools(undefined, { ...requestOptions, cacheMode: "refresh" });
  assert.equal(pages.length, 3);
  for (const page of pages) {
    assert.equal(page.tools.length, 8);
    assert.equal(page.ttlMs, 60_000);
    assert.equal(page.cacheScope, "public");
  }
  assert.equal(new Set(pages.slice(0, -1).map((page) => page.nextCursor)).size, 2);
  assert.equal(pages.at(-1).nextCursor, undefined);
  assert.deepEqual(listed.tools.map((tool) => tool.name).sort(), expectedTools);
  for (const tool of listed.tools) assert.equal(tool.inputSchema.type, "object");
  assert.deepEqual(listed.tools.find((tool) => tool.name === "info").inputSchema.required, ["name"]);
  const search = listed.tools.find((tool) => tool.name === "search");
  assert.equal(search.inputSchema.properties.page.type, "integer");
  assert.equal(search.inputSchema.properties.sort.type, "string");
  assert.deepEqual(search.inputSchema.required, ["query"]);

  const info = await client.callTool({ name: "info", arguments: { name: "interop_package" } }, requestOptions);
  assert.notEqual(info.isError, true);
  assert.match(textResult(info), /Seeded official-client acceptance package/);
  assert.match(textResult(info), /1\.2\.3/);

  const failed = await client.callTool({ name: "info", arguments: { name: "missing_interop_package" } }, requestOptions);
  assert.equal(failed.isError, true, "expected domain failure must be a tool result");
  assert.match(textResult(failed), /not found/);
  const limited = await client.callTool({ name: "info", arguments: { name: "limited_interop_package" } }, requestOptions);
  assert.equal(limited.isError, true, "upstream failure must also be a tool result");
  assert.match(textResult(limited), /rate_limited/);

  // Malformed arguments are protocol errors, distinct from the domain failure.
  await assert.rejects(
    client.callTool({ name: "info", arguments: {} }, requestOptions),
    (error) => error.code === -32602,
  );
  const groupsTool = await client.callTool({ name: "toolbox_groups", arguments: {} }, requestOptions);
  assert.notEqual(groupsTool.isError, true);
  assert.match(textResult(groupsTool), /HTTP clients/);

  const prompts = await client.listPrompts(undefined, requestOptions);
  assert.deepEqual(prompts.prompts.map((prompt) => prompt.name).sort(), promptCases.map(([name]) => name).sort());
  for (const [name, args, expectedText] of promptCases) {
    const result = await client.getPrompt({ name, arguments: args }, requestOptions);
    assert.equal(result.messages[0].role, "user");
    assert.equal(result.messages[0].content.type, "text");
    assert.ok(result.messages[0].content.text.includes(expectedText));
  }

  const review = await client.getPrompt({ name: "package_review", arguments: { name: "interop_package" } }, requestOptions);
  assert.equal(elicitationCounts.get(client), 1);
  assert.match(review.messages[0].content.text, /security review/);

  for (const ref of [
    { type: "ref/prompt", name: "analyze_package" },
    { type: "ref/resource", uri: "hex://{name}/info" },
  ]) {
    const result = await client.complete({ ref, argument: { name: "name", value: "interop" } }, requestOptions);
    assert.deepEqual(result.completion.values, ["interop_package"]);
    assert.equal(result.completion.hasMore, false);
  }

  const resources = await client.listResources(undefined, requestOptions);
  assert.deepEqual(resources.resources.map((resource) => resource.uri), ["toolbox://groups"]);
  const templates = await client.listResourceTemplates(undefined, requestOptions);
  assert.deepEqual(templates.resourceTemplates.map((template) => template.uriTemplate).sort(), [
    "hex://{name}/docs", "hex://{name}/info", "hex://{name}/readme", "toolbox://{group}/{category}",
  ]);

  const packageInfo = await jsonResource(client, "hex://interop_package/info");
  assert.equal(packageInfo.name, "interop_package");
  assert.equal(packageInfo.latest_stable_version, "1.2.3");
  assert.equal(packageInfo.downloads.all, 1234);
  const groups = await jsonResource(client, "toolbox://groups");
  assert.equal(groups.groups[0].categories[0].slug, "http-clients");
  const category = await jsonResource(client, "toolbox://web/http-clients");
  assert.equal(category.projects[0].github.stars, 42);
  const docs = await jsonResource(client, "hex://interop_package/docs");
  assert.equal(docs[0].name, "InteropPackage");
  const readme = await client.readResource({ uri: "hex://interop_package/readme" }, requestOptions);
  assert.equal(readme.contents[0].uri, "hex://interop_package/readme");
  assert.equal(readme.contents[0].mimeType, "text/markdown");
  assert.match(readme.contents[0].text, /Seeded README/);

  return {
    transport: transportName, era: client.getProtocolEra(), protocol,
    tools: listed.tools.length, successfulTools: 2, expectedToolFailures: 2,
    invalidArgumentsRejected: true, renderedPrompts: promptCases.length,
    resources: resources.resources.length, templates: templates.resourceTemplates.length,
    resourceReads: 5, toolPages: pages.length, completions: 2, automaticMRTRReviews: 1,
  };
}

async function checkStdio() {
  const client = newClient();
  const transport = new StdioClientTransport({
    command: elixir, args: [fixture, "--stdio"], cwd: project,
    env: { ...process.env }, stderr: "pipe",
  });
  let diagnostics = "";
  transport.stderr?.on("data", (chunk) => { diagnostics += chunk; });
  try {
    await client.connect(transport, requestOptions);
    return await exercise(client, "stdio", observeToolPages(transport));
  } catch (error) {
    if (diagnostics) process.stderr.write(diagnostics);
    throw error;
  } finally {
    await client.close();
  }
}

async function checkHTTP() {
  const child = spawn(elixir, [fixture, "--http"], { cwd: project, stdio: ["pipe", "pipe", "pipe"] });
  let diagnostics = "";
  child.stderr.on("data", (chunk) => { diagnostics += chunk; });
  const exited = once(child, "exit");
  const lines = createInterface({ input: child.stdout });
  const client = newClient();
  let forcedShutdown = false;
  try {
    const readiness = await Promise.race([
      once(lines, "line", {
        signal: AbortSignal.any([requestOptions.signal, AbortSignal.timeout(15_000)]),
      }).then(([line]) => JSON.parse(line)),
      exited.then(([code]) => { throw new Error(`fixture exited before readiness: ${code}`); }),
    ]);
    const transport = new StreamableHTTPClientTransport(new URL(readiness.url));
    await client.connect(transport, requestOptions);
    const result = await exercise(client, "http", observeToolPages(transport));
    assert.equal(transport.sessionId, undefined, "modern HTTP must remain stateless");
    return result;
  } catch (error) {
    if (diagnostics) process.stderr.write(diagnostics);
    throw error;
  } finally {
    try {
      await client.close();
    } finally {
      lines.close();
      child.stdin.end();
      const timer = setTimeout(() => { forcedShutdown = true; child.kill("SIGKILL"); }, 5000);
      try {
        const [code] = await exited;
        assert.equal(forcedShutdown, false, "HTTP fixture failed to stop on EOF");
        assert.equal(code, 0, `HTTP fixture exited unsuccessfully: ${diagnostics}`);
      } finally {
        clearTimeout(timer);
      }
    }
  }
}

const selected = process.argv.slice(2);
assert.ok(selected.length === 0 || (selected.length === 1 && ["--stdio", "--http"].includes(selected[0])),
  "usage: node check_hexpm.mjs [--stdio|--http]");
const summaries = [];
if (selected.length === 0 || selected[0] === "--stdio") summaries.push(await checkStdio());
if (selected.length === 0 || selected[0] === "--http") summaries.push(await checkHTTP());
process.stdout.write(`${JSON.stringify({ application: "hexpm-mcp", checks: summaries })}\n`);
