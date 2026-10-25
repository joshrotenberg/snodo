import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { randomBytes } from "node:crypto";
import { once } from "node:events";
import path from "node:path";
import { createInterface } from "node:readline";
import { fileURLToPath } from "node:url";
import {
  Client,
  ClientCredentialsProvider,
  InsufficientScopeError,
  ProtocolError,
  StreamableHTTPClientTransport,
  UnauthorizedError,
  discoverOAuthProtectedResourceMetadata,
  extractWWWAuthenticateParams,
} from "@modelcontextprotocol/client";

const project = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const fixture = path.join(project, "interop/official_client/oauth_fixture.exs");
const elixir = process.env.SNODO_ELIXIR ?? "elixir";
const env = { ...process.env, ERL_FLAGS: process.env.ERL_FLAGS ?? "+S 4:4" };
const options = () => ({ signal: AbortSignal.timeout(15_000) });
const protocol = "2026-07-28";

function newClient() {
  return new Client({ name: "snodo-oauth-check", version: "1.0.0" }, {
    versionNegotiation: { mode: { pin: protocol } },
  });
}

// An interactive OAuthClientProvider whose user agent is fetch: it follows the
// authorization URL without redirects and keeps the callback it was sent to.
// The redirect URI is never contacted.
class InteropProvider {
  redirectUrl = "http://127.0.0.1:1/callback";
  clientMetadata = {
    client_name: "snodo-oauth-check",
    redirect_uris: [this.redirectUrl],
    grant_types: ["authorization_code"],
    response_types: ["code"],
    token_endpoint_auth_method: "none",
  };
  registered;
  saved;
  discovery;
  verifier;
  expectedState;
  authorizationUrl;
  callback;

  state() {
    this.expectedState = randomBytes(16).toString("base64url");
    return this.expectedState;
  }
  clientInformation() { return this.registered; }
  saveClientInformation(info) { this.registered = info; }
  tokens() { return this.saved; }
  saveTokens(tokens) { this.saved = tokens; }
  saveCodeVerifier(verifier) { this.verifier = verifier; }
  codeVerifier() { return this.verifier; }
  // Kept so the SDK can bind the callback leg to the discovered issuer (SEP-2352).
  saveDiscoveryState(state) { this.discovery = state; }
  discoveryState() { return this.discovery; }

  async redirectToAuthorization(url) {
    this.authorizationUrl = new URL(url);
    const response = await fetch(url, { redirect: "manual", ...options() });
    assert.equal(response.status, 302, `authorization refused: ${await response.text()}`);
    this.callback = new URL(response.headers.get("location"));
  }
}

async function post(url, body, headers = {}) {
  return fetch(url, {
    method: "POST",
    headers: {
      "content-type": "application/json",
      accept: "application/json, text/event-stream",
      "mcp-protocol-version": protocol,
      "mcp-method": body.method,
      ...headers,
    },
    body: JSON.stringify(body),
    ...options(),
  });
}

const listTools = {
  jsonrpc: "2.0",
  id: 1,
  method: "tools/list",
  params: { _meta: { "io.modelcontextprotocol/protocolVersion": protocol, "io.modelcontextprotocol/clientCapabilities": {} } },
};

async function connected(authProvider, resource) {
  const client = newClient();
  const transport = new StreamableHTTPClientTransport(new URL(resource), { authProvider });
  await client.connect(transport);
  return { client, transport };
}

async function whoami(client) {
  const result = await client.callTool({ name: "whoami", arguments: {} }, options());
  return JSON.parse(result.content[0].text);
}

async function challenge(server) {
  // The SDK's own discovery reads what the resource server publishes.
  const unauthenticated = await post(server.resource, listTools);
  assert.equal(unauthenticated.status, 401);
  const params = extractWWWAuthenticateParams(unauthenticated);
  assert.equal(params.scope, "mcp:read");
  assert.equal(params.resourceMetadataUrl?.href, new URL("/.well-known/oauth-protected-resource/mcp", server.resource).href);

  const metadata = await discoverOAuthProtectedResourceMetadata(server.resource, {
    protocolVersion: protocol,
    resourceMetadataUrl: params.resourceMetadataUrl,
  });
  assert.equal(metadata.resource, server.resource);
  assert.deepEqual(metadata.authorization_servers, [server.issuer]);
  assert.deepEqual(metadata.scopes_supported, ["mcp:read", "mcp:write"]);

  // Without a resource_metadata URL the SDK falls back to the path-aware
  // well-known location.
  const discovered = await discoverOAuthProtectedResourceMetadata(server.resource, { protocolVersion: protocol });
  assert.deepEqual(discovered, metadata);
  return { challengeScope: params.scope, resourceMetadata: true };
}

async function authorizationCode(server) {
  const provider = new InteropProvider();
  const first = newClient();
  const transport = new StreamableHTTPClientTransport(new URL(server.resource), { authProvider: provider });

  // The first request gets the 401, the SDK runs discovery and registration,
  // and stops at the redirect, as an interactive client does.
  await assert.rejects(
    (async () => {
      await first.connect(transport);
      await first.listTools(undefined, options());
    })(),
    (error) => error instanceof UnauthorizedError,
  );
  await first.close();

  assert.ok(provider.registered?.client_id?.startsWith("dcr-"), "dynamic client registration");
  const authorize = provider.authorizationUrl.searchParams;
  assert.equal(authorize.get("resource"), server.resource);
  assert.equal(authorize.get("scope"), "mcp:read");
  assert.equal(authorize.get("code_challenge_method"), "S256");
  assert.equal(provider.callback.searchParams.get("state"), provider.expectedState);
  assert.equal(provider.callback.searchParams.get("iss"), server.issuer);

  await transport.finishAuth(provider.callback.searchParams);
  assert.equal(provider.saved?.token_type?.toLowerCase(), "bearer");

  const { client } = await connected(provider, server.resource);
  try {
    if (client.getProtocolEra() !== "modern") throw new Error(`expected modern era, got ${client.getProtocolEra()}`);

    // ScopePolicy hides the tool the token's scopes do not reach.
    const listed = await client.listTools(undefined, options());
    assert.deepEqual(listed.tools.map((tool) => tool.name), ["whoami"]);
    assert.deepEqual(await whoami(client), {
      principal: "interop-user",
      client_id: provider.registered.client_id,
      scopes: ["mcp:read"],
    });

    // A call to it is refused inside an HTTP 200 with the policy's error.
    await assert.rejects(
      client.callTool({ name: "publish", arguments: {} }, options()),
      (error) => {
        assert.ok(error instanceof ProtocolError, `unexpected ${error}`);
        assert.equal(error.code, -32003);
        assert.deepEqual(error.data, { error: "insufficient_scope", scope: "mcp:write" });
        return true;
      },
    );
  } finally {
    await client.close();
  }
  return { authorizationCode: true, dynamicRegistration: true, pkce: "S256", resourceIndicator: true, policyRefusal: -32003 };
}

async function clientCredentials(server) {
  const provider = new ClientCredentialsProvider({
    clientId: server.clientId,
    clientSecret: server.clientSecret,
    expectedIssuer: server.issuer,
  });
  const { client } = await connected(provider, server.resource);
  try {
    await client.listTools(undefined, options());
    assert.deepEqual(await whoami(client), {
      principal: server.clientId,
      client_id: server.clientId,
      scopes: ["mcp:read"],
    });
  } finally {
    await client.close();
  }
  return { clientCredentials: true };
}

async function refusedToken(server) {
  const raw = await post(server.resource, listTools, { authorization: "Bearer not-a-valid-token" });
  assert.equal(raw.status, 401);
  assert.equal(extractWWWAuthenticateParams(raw).error, "invalid_token");

  const { client } = await connected({ token: async () => "not-a-valid-token" }, server.resource).catch((error) => {
    // The modern era sends nothing on connect, so a refusal may come here or on the first request.
    assert.ok(error instanceof UnauthorizedError, `unexpected ${error}`);
    return { client: undefined };
  });
  if (client) {
    await assert.rejects(client.listTools(undefined, options()), (error) => error instanceof UnauthorizedError);
    await client.close();
  }
  return { invalidToken: 401 };
}

async function underScopedToken(server) {
  const response = await fetch(new URL("/token", server.issuer), {
    method: "POST",
    headers: {
      "content-type": "application/x-www-form-urlencoded",
      authorization: `Basic ${Buffer.from(`${server.clientId}:${server.clientSecret}`).toString("base64")}`,
    },
    body: new URLSearchParams({ grant_type: "client_credentials", scope: "mcp:other", resource: server.resource }),
    ...options(),
  });
  assert.equal(response.status, 200);
  const narrow = (await response.json()).access_token;

  const raw = await post(server.resource, listTools, { authorization: `Bearer ${narrow}` });
  assert.equal(raw.status, 403);
  const params = extractWWWAuthenticateParams(raw);
  assert.equal(params.error, "insufficient_scope");
  assert.equal(params.scope, "mcp:read");

  // A plain AuthProvider cannot step up, so the SDK surfaces the challenge.
  const isInsufficient = (error) => {
    assert.ok(error instanceof InsufficientScopeError, `unexpected ${error}`);
    assert.equal(error.requiredScope, "mcp:read");
    return true;
  };
  const { client } = await connected({ token: async () => narrow }, server.resource).catch((error) => {
    isInsufficient(error);
    return { client: undefined };
  });
  if (client) {
    await assert.rejects(client.listTools(undefined, options()), isInsufficient);
    await client.close();
  }
  return { insufficientScope: 403 };
}

async function startFixture(mode) {
  const child = spawn(elixir, [fixture, mode], { cwd: project, env, stdio: ["pipe", "pipe", "inherit"] });
  const lines = createInterface({ input: child.stdout });
  const exited = once(child, "exit").then(([code]) => { throw new Error(`${mode} fixture exited with ${code}`); });
  const [line] = await Promise.race([once(lines, "line"), exited]);
  exited.catch(() => {});
  const stop = async () => {
    child.stdin.end();
    if (child.exitCode === null) await once(child, "exit");
  };
  return { ...JSON.parse(line), stop };
}

async function check(mode) {
  const server = await startFixture(mode);
  try {
    return {
      transport: mode.slice(2),
      ...(await challenge(server)),
      ...(await authorizationCode(server)),
      ...(await clientCredentials(server)),
      ...(await refusedToken(server)),
      ...(await underScopedToken(server)),
    };
  } finally {
    await server.stop();
  }
}

const selected = process.argv.slice(2);
const modes = selected.length > 0 ? selected : ["--native", "--plug"];

for (const mode of modes) {
  if (!["--native", "--plug"].includes(mode)) throw new Error(`unknown mode ${mode}`);
  process.stdout.write(`${JSON.stringify(await check(mode))}\n`);
}
