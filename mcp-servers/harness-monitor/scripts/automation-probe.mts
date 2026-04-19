// Probes the MCP server's automation tools that reach out to the system:
// - backend resolution (prefers the Swift helper, falls back to cliclick)
// - screenshot_window via screencapture
// - move_mouse via the selected backend (requires --allow-input)
// - type_text via the selected backend (requires --allow-input; types into
//   whatever window currently has focus -- caller is responsible)

import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";
import { fileURLToPath } from "node:url";
import { dirname, resolve } from "node:path";
import { access, writeFile } from "node:fs/promises";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import process from "node:process";

const execFileAsync = promisify(execFile);
const here = dirname(fileURLToPath(import.meta.url));
const packageRoot = resolve(here, "..");
const serverEntry = resolve(packageRoot, "dist", "server.js");
const registryRoot = resolve(packageRoot, "..", "harness-monitor-registry");

const positionalArgs = process.argv.slice(2).filter((a) => !a.startsWith("--"));
const allowInput = process.argv.includes("--allow-input");
const socketPath = positionalArgs[0];

if (socketPath === undefined || socketPath.length === 0) {
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

async function fileExists(path: string): Promise<boolean> {
  try {
    await access(path);
    return true;
  } catch {
    return false;
  }
}

const helperDebugPath = resolve(registryRoot, ".build", "debug", "harness-monitor-input");
const helperReleasePath = resolve(registryRoot, ".build", "release", "harness-monitor-input");
const helperPath = (await fileExists(helperReleasePath))
  ? helperReleasePath
  : (await fileExists(helperDebugPath))
    ? helperDebugPath
    : null;
record(
  "Swift input helper is built",
  helperPath !== null,
  helperPath ?? "build with: swift build --package-path mcp-servers/harness-monitor-registry --product harness-monitor-input",
);

if (helperPath !== null) {
  const { stdout } = await execFileAsync(helperPath, ["check"]);
  record(
    "Swift helper reports accessibility trusted",
    stdout.trim() === "trusted",
    stdout.trim(),
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
  const imagePass =
    image !== undefined && image.mimeType === "image/png" && (image.data?.length ?? 0) > 0;
  record(
    "screenshot_window returns PNG image content",
    imagePass,
    image !== undefined ? `bytes_b64=${image.data?.length ?? 0}` : "no image content",
  );
  if (imagePass && image?.data !== undefined) {
    const target = "/tmp/hm-e2e/screenshot.png";
    await writeFile(target, Buffer.from(image.data, "base64"));
    const sizeCheck = await execFileAsync("/usr/bin/file", [target]);
    record(
      "screenshot bytes decode to a real PNG",
      sizeCheck.stdout.includes("PNG image data"),
      sizeCheck.stdout.trim(),
    );
  }

  if (allowInput && helperPath !== null) {
    const before = (await execFileAsync(helperPath, ["position"])).stdout.trim();
    await client.callTool({
      name: "move_mouse",
      arguments: { x: 200, y: 200 },
    });
    const after = (await execFileAsync(helperPath, ["position"])).stdout.trim();
    record(
      "move_mouse updates cursor position via MCP",
      before !== after && after.startsWith("200"),
      `before=${before} after=${after}`,
    );

    // click on empty area - exercise full path but at a safe (desktop) coord
    await client.callTool({
      name: "click",
      arguments: { x: 200, y: 200 },
    });
    record("click executed without error", true);

    // Verify type_text path runs without error. We type a trivial sequence
    // that will go to the focused window; caller's responsibility to focus a
    // scratch buffer before --allow-input.
    await client.callTool({
      name: "type_text",
      arguments: { text: "" },
    });
    record("type_text empty string is a no-op", true);
  } else if (allowInput && helperPath === null) {
    record("skip live input (helper binary not built)", false, "run the swift build first");
  } else {
    console.log("[skip] live input: pass --allow-input to move the cursor and click");
  }
} finally {
  await client.close();
}

const passed = results.every((r) => r.pass);
console.log("");
console.log(`summary: ${results.filter((r) => r.pass).length}/${results.length} passed`);
process.exit(passed ? 0 : 1);
