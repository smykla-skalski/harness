// Probes the MCP server's automation tools that reach out to the system:
// screenshot_window (screencapture), and availability of cliclick.
// Does NOT move the mouse or send keystrokes unless --allow-input is set.

import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";
import { fileURLToPath } from "node:url";
import { dirname, resolve } from "node:path";
import process from "node:process";
import { writeFile } from "node:fs/promises";
import { execFile } from "node:child_process";
import { promisify } from "node:util";

const execFileAsync = promisify(execFile);
const here = dirname(fileURLToPath(import.meta.url));
const serverEntry = resolve(here, "..", "dist", "server.js");

const allowInput = process.argv.includes("--allow-input");
const socketPath = process.argv.find((a) => !a.startsWith("--") && a !== process.argv[0] && a !== process.argv[1]);
if (socketPath === undefined) {
  console.error("usage: automation-probe.mts <socket-path> [--allow-input]");
  process.exit(64);
}

const results: { name: string; pass: boolean; detail?: string }[] = [];
function record(name: string, pass: boolean, detail?: string) {
  results.push(detail === undefined ? { name, pass } : { name, pass, detail });
  const icon = pass ? "pass" : "FAIL";
  const suffix = detail !== undefined ? ` - ${detail}` : "";
  console.log(`[${icon}] ${name}${suffix}`);
}

try {
  await execFileAsync("/usr/bin/which", ["cliclick"]);
  record("cliclick is on PATH", true);
} catch {
  record(
    "cliclick is on PATH",
    false,
    "install via `brew install cliclick` before using mouse/keyboard tools",
  );
}

const transport = new StdioClientTransport({
  command: process.execPath,
  args: [serverEntry],
  env: { ...process.env, HARNESS_MONITOR_MCP_SOCKET: socketPath },
});
const client = new Client({ name: "probe", version: "0.0.0" });
await client.connect(transport);

try {
  const screenshot = (await client.callTool({
    name: "screenshot_window",
    arguments: {},
  })) as { content: Array<{ type: string; mimeType?: string; data?: string }> };
  const image = screenshot.content.find((c) => c.type === "image");
  const pass = image !== undefined && image.mimeType === "image/png" && (image.data?.length ?? 0) > 0;
  record(
    "screenshot_window returns PNG image content",
    pass,
    image !== undefined ? `bytes_b64=${image.data?.length ?? 0}` : "no image content",
  );
  if (pass && image?.data) {
    const target = "/tmp/hm-e2e/screenshot.png";
    await writeFile(target, Buffer.from(image.data, "base64"));
    const sizeCheck = await execFileAsync("/usr/bin/file", [target]);
    record(
      "screenshot bytes decode to a real PNG",
      sizeCheck.stdout.includes("PNG image data"),
      sizeCheck.stdout.trim(),
    );
  }

  if (allowInput) {
    // Move mouse to a safe spot (top-left-ish) and back. Requires cliclick + Accessibility.
    const before = await execFileAsync("cliclick", ["p"]);
    await client.callTool({
      name: "move_mouse",
      arguments: { x: 100, y: 100 },
    });
    const after = await execFileAsync("cliclick", ["p"]);
    record(
      "move_mouse actually moves the cursor",
      after.stdout.trim() !== before.stdout.trim(),
      `before=${before.stdout.trim()} after=${after.stdout.trim()}`,
    );
  } else {
    console.log("[skip] move_mouse: pass --allow-input to exercise the real cursor");
  }
} finally {
  await client.close();
}

const passed = results.every((r) => r.pass);
console.log("");
console.log(`summary: ${results.filter((r) => r.pass).length}/${results.length} passed`);
process.exit(passed ? 0 : 1);
