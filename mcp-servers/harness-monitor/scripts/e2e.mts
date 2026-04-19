// Runs end-to-end smoke tests against the harness-monitor MCP server with a
// live registry test host. Pass the socket path as the first argument.
//
//   node --experimental-strip-types scripts/e2e.mts /tmp/hm-e2e/mcp.sock
//
// The script spawns dist/server.js over stdio, talks MCP JSON-RPC via the
// official client SDK, and prints a pass/fail line per test.

import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";
import { fileURLToPath } from "node:url";
import { dirname, resolve } from "node:path";
import process from "node:process";

const here = dirname(fileURLToPath(import.meta.url));
const serverEntry = resolve(here, "..", "dist", "server.js");

const socketPath = process.argv[2];
if (socketPath === undefined || socketPath.length === 0) {
  console.error("usage: e2e.mts <socket-path>");
  process.exit(64);
}

type Check = { name: string; pass: boolean; detail?: string };
const results: Check[] = [];

function record(name: string, pass: boolean, detail?: string) {
  results.push(detail === undefined ? { name, pass } : { name, pass, detail });
  const icon = pass ? "pass" : "FAIL";
  const suffix = detail !== undefined ? ` - ${detail}` : "";
  console.log(`[${icon}] ${name}${suffix}`);
}

function readTextResult(result: unknown): string {
  const anyResult = result as { content?: Array<{ type: string; text?: string }> };
  const first = anyResult.content?.[0];
  if (first?.type === "text" && typeof first.text === "string") {
    return first.text;
  }
  throw new Error(`expected text content, got: ${JSON.stringify(result)}`);
}

const transport = new StdioClientTransport({
  command: process.execPath,
  args: [serverEntry],
  env: { ...process.env, HARNESS_MONITOR_MCP_SOCKET: socketPath },
});

const client = new Client({ name: "e2e", version: "0.0.0" });
await client.connect(transport);

try {
  const tools = await client.listTools();
  const toolNames = tools.tools.map((t) => t.name).sort();
  const expected = [
    "click",
    "click_element",
    "get_element",
    "list_elements",
    "list_windows",
    "move_mouse",
    "screenshot_window",
    "type_text",
  ];
  record(
    "tools/list exposes 8 tools",
    JSON.stringify(toolNames) === JSON.stringify(expected),
    `names=${toolNames.join(",")}`,
  );

  const windows = JSON.parse(
    readTextResult(await client.callTool({ name: "list_windows", arguments: {} })),
  ) as { windows: Array<{ id: number; title: string }> };
  record(
    "list_windows returns seeded windows",
    windows.windows.length === 2 && windows.windows[0]?.id === 1001,
    `ids=${windows.windows.map((w) => w.id).join(",")}`,
  );

  const allElements = JSON.parse(
    readTextResult(await client.callTool({ name: "list_elements", arguments: {} })),
  ) as { elements: Array<{ identifier: string }> };
  record(
    "list_elements returns all seeded elements",
    allElements.elements.length === 4,
    `count=${allElements.elements.length}`,
  );

  const buttons = JSON.parse(
    readTextResult(
      await client.callTool({
        name: "list_elements",
        arguments: { windowID: 1001, kind: "button" },
      }),
    ),
  ) as { elements: Array<{ identifier: string }> };
  const buttonIds = buttons.elements.map((e) => e.identifier).sort();
  record(
    "list_elements filters by windowID+kind",
    JSON.stringify(buttonIds) === JSON.stringify(["toolbar.refresh", "toolbar.start-daemon"]),
    `ids=${buttonIds.join(",")}`,
  );

  const single = JSON.parse(
    readTextResult(
      await client.callTool({
        name: "get_element",
        arguments: { identifier: "sidebar.search" },
      }),
    ),
  ) as { element: { identifier: string; label: string; kind: string } };
  record(
    "get_element returns the requested element",
    single.element.identifier === "sidebar.search" && single.element.kind === "textField",
    `label=${single.element.label}`,
  );

  const missing = (await client.callTool({
    name: "get_element",
    arguments: { identifier: "does-not-exist" },
  })) as { isError?: boolean; content: Array<{ text?: string }> };
  const missingText = missing.content[0]?.text ?? "";
  record(
    "get_element surfaces not-found as isError",
    missing.isError === true && missingText.includes("not-found"),
    `text=${missingText.slice(0, 80)}`,
  );

  const emptyID = (await client.callTool({
    name: "get_element",
    arguments: { identifier: " " },
  })) as { isError?: boolean; content: Array<{ text?: string }> };
  // the server's zod schema requires min(1); " " passes min but hits server-side invalid-argument.
  const emptyText = emptyID.content[0]?.text ?? "";
  record(
    "get_element rejects whitespace identifier gracefully",
    emptyID.isError === true,
    `text=${emptyText.slice(0, 80)}`,
  );
} finally {
  await client.close();
}

const passed = results.every((r) => r.pass);
console.log("");
console.log(`summary: ${results.filter((r) => r.pass).length}/${results.length} passed`);
process.exit(passed ? 0 : 1);
