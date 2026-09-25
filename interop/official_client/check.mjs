import path from "node:path";
import { fileURLToPath } from "node:url";

import { Client } from "@modelcontextprotocol/client";
import { StdioClientTransport } from "@modelcontextprotocol/client/stdio";

const here = path.dirname(fileURLToPath(import.meta.url));
const project = path.resolve(here, "../..");
const elixir = process.env.SNODO_ELIXIR ?? "elixir";
const ebin =
  process.env.SNODO_EBIN ?? path.join(project, "_build/dev/lib/snodo/ebin");

const client = new Client(
  { name: "snodo-official-client-check", version: "1.0.0" },
  { versionNegotiation: { mode: { pin: "2026-07-28" } } },
);

const transport = new StdioClientTransport({
  command: elixir,
  args: [
    "-pa",
    ebin,
    path.join(project, "examples/stdio_echo.exs"),
  ],
  cwd: project,
  stderr: "pipe",
});

try {
  await client.connect(transport);

  if (client.getProtocolEra() !== "modern") {
    throw new Error(`expected modern era, got ${client.getProtocolEra()}`);
  }

  const listed = await client.listTools();
  const echo = listed.tools.find((tool) => tool.name === "echo");

  if (!echo || echo.inputSchema?.type !== "object") {
    throw new Error("official client did not decode the echo tool definition");
  }

  const called = await client.callTool({
    name: "echo",
    arguments: { text: "official-client-ok" },
  });
  const first = called.content?.[0];

  if (first?.type !== "text" || first.text !== "official-client-ok") {
    throw new Error(`unexpected tool result: ${JSON.stringify(called)}`);
  }

  const nonAscii = "h\u00e9llo \u65e5\u672c \u{1F600} line\u2028separator";
  const unicode = await client.callTool({ name: "echo", arguments: { text: nonAscii } });

  if (unicode.content?.[0]?.text !== nonAscii) {
    throw new Error(`non-ASCII text did not round-trip: ${JSON.stringify(unicode)}`);
  }

  const controller = new AbortController();
  const pending = client.callTool(
    {
      name: "echo",
      arguments: { text: "must-not-arrive", delayMs: 10_000 },
    },
    { signal: controller.signal },
  );

  setTimeout(() => controller.abort("official cancellation check"), 100);

  let cancelled = false;

  try {
    await pending;
  } catch {
    cancelled = true;
  }

  if (!cancelled) {
    throw new Error("official client cancellation unexpectedly completed");
  }

  const afterCancel = await client.callTool({
    name: "echo",
    arguments: { text: "after-cancel" },
  });
  const afterFirst = afterCancel.content?.[0];

  if (afterFirst?.type !== "text" || afterFirst.text !== "after-cancel") {
    throw new Error(
      `server did not remain usable after cancellation: ${JSON.stringify(afterCancel)}`,
    );
  }

  process.stdout.write(
    `${JSON.stringify({
      era: client.getProtocolEra(),
      tools: listed.tools.length,
      text: first.text,
      nonAsciiRoundTrip: true,
      cancelled,
      afterCancel: afterFirst.text,
    })}\n`,
  );
} finally {
  await client.close();
}
