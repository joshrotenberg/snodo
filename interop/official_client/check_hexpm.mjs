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
  ["recommend_packages", { use_case: "deterministic offline acceptance" }, "deterministic offline acceptance"],
];

function newClient() {
  return new Client(
    { name: "hexpm-mcp-official-client-check", version: "1.0.0" },
    { versionNegotiation: { mode: { pin: protocol } } },
  );
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

async function exercise(client, transportName) {
  assert.equal(client.getProtocolEra(), "modern");
  const discovery = await client.discover(requestOptions);
  assert.ok(discovery.supportedVersions.includes(protocol));
  assert.equal(client.getServerVersion().name, "hexpm-mcp");
  for (const capability of ["tools", "resources", "prompts"]) {
    assert.ok(Object.hasOwn(discovery.capabilities, capability));
  }

  const listed = await client.listTools(undefined, requestOptions);
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
    resourceReads: 5,
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
    return await exercise(client, "stdio");
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
    const result = await exercise(client, "http");
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
