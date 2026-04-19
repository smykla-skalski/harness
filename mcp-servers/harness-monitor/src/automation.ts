import { execFile } from "node:child_process";
import { access, mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { promisify } from "node:util";

const execFileAsync = promisify(execFile);

export class AutomationError extends Error {
  constructor(
    readonly code: string,
    message: string,
  ) {
    super(message);
    this.name = "AutomationError";
  }
}

export type MouseButton = "left" | "right" | "middle";

async function haveCliclick(): Promise<boolean> {
  try {
    await execFileAsync("/usr/bin/which", ["cliclick"]);
    return true;
  } catch {
    return false;
  }
}

function requireCliclick(): Promise<void> {
  return haveCliclick().then((ok) => {
    if (!ok) {
      throw new AutomationError(
        "cliclick-missing",
        "cliclick is required for mouse control. Install via `brew install cliclick` and grant Accessibility permission to the process running this MCP server.",
      );
    }
  });
}

export async function moveMouse(x: number, y: number): Promise<void> {
  await requireCliclick();
  await execFileAsync("cliclick", [`m:${Math.round(x)},${Math.round(y)}`]);
}

export async function click(
  x: number,
  y: number,
  button: MouseButton = "left",
  doubleClick = false,
): Promise<void> {
  await requireCliclick();
  const coord = `${Math.round(x)},${Math.round(y)}`;
  if (doubleClick) {
    await execFileAsync("cliclick", [`dc:${coord}`]);
    return;
  }
  switch (button) {
    case "left":
      await execFileAsync("cliclick", [`c:${coord}`]);
      return;
    case "right":
      await execFileAsync("cliclick", [`rc:${coord}`]);
      return;
    case "middle":
      throw new AutomationError(
        "unsupported-button",
        "cliclick does not support middle-button clicks.",
      );
  }
}

export async function typeText(text: string): Promise<void> {
  if (text.length === 0) {
    return;
  }
  if (await haveCliclick()) {
    await execFileAsync("cliclick", ["-w", "20", `t:${text}`]);
    return;
  }
  const script = `tell application "System Events" to keystroke ${JSON.stringify(text)}`;
  await execFileAsync("/usr/bin/osascript", ["-e", script]);
}

export interface ScreenshotOptions {
  windowID?: number;
  displayID?: number;
  includeCursor?: boolean;
}

export async function screenshot(
  options: ScreenshotOptions = {},
): Promise<{ path: string; bytes: Buffer }> {
  const dir = await mkdtemp(join(tmpdir(), "harness-monitor-mcp-"));
  const path = join(dir, "screenshot.png");
  const args = ["-x", "-t", "png"];
  if (options.windowID !== undefined) {
    args.push("-l", String(options.windowID));
  } else if (options.displayID !== undefined) {
    args.push("-D", String(options.displayID));
  }
  if (options.includeCursor === true) {
    args.push("-C");
  }
  args.push(path);
  try {
    await execFileAsync("/usr/sbin/screencapture", args);
    await access(path);
    const bytes = await readFile(path);
    return { path, bytes };
  } catch (err) {
    await rm(dir, { recursive: true, force: true }).catch(() => {});
    const message = err instanceof Error ? err.message : String(err);
    throw new AutomationError("screencapture-failed", `screencapture failed: ${message}`);
  }
}
