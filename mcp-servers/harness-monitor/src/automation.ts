import { execFile, spawn } from "node:child_process";
import { access, mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
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

// Backend discovery. The CGEvent-backed Swift helper is preferred; cliclick is
// accepted as a fallback for legacy setups; osascript covers text input when
// no helper binary is present.

type Backend =
  | { kind: "harness-input"; path: string }
  | { kind: "cliclick" }
  | { kind: "none" };

let cachedBackend: Backend | null = null;

async function resolveBackend(): Promise<Backend> {
  if (cachedBackend !== null) {
    return cachedBackend;
  }
  cachedBackend = await detectBackend();
  return cachedBackend;
}

async function detectBackend(): Promise<Backend> {
  const override = process.env.HARNESS_MONITOR_INPUT_BIN;
  if (override !== undefined && override.length > 0) {
    if (await fileExists(override)) {
      return { kind: "harness-input", path: override };
    }
  }
  for (const candidate of defaultHarnessInputPaths()) {
    if (await fileExists(candidate)) {
      return { kind: "harness-input", path: candidate };
    }
  }
  if (await onPath("cliclick")) {
    return { kind: "cliclick" };
  }
  return { kind: "none" };
}

function defaultHarnessInputPaths(): string[] {
  const here = dirname(fileURLToPath(import.meta.url));
  // src/automation.ts in dev, dist/automation.js when built. Walk up one to
  // the package root, then to the registry package.
  const packageRoot = resolve(here, "..");
  const registryRoot = resolve(packageRoot, "..", "harness-monitor-registry");
  return [
    join(registryRoot, ".build", "release", "harness-monitor-input"),
    join(registryRoot, ".build", "debug", "harness-monitor-input"),
  ];
}

async function fileExists(path: string): Promise<boolean> {
  try {
    await access(path);
    return true;
  } catch {
    return false;
  }
}

async function onPath(cmd: string): Promise<boolean> {
  try {
    await execFileAsync("/usr/bin/which", [cmd]);
    return true;
  } catch {
    return false;
  }
}

function throwNoMouseBackend(): never {
  throw new AutomationError(
    "mouse-backend-missing",
    "No mouse backend available. Build the bundled helper with " +
      "`swift build -c release --package-path mcp-servers/harness-monitor-registry --product harness-monitor-input` " +
      "or install cliclick (`brew install cliclick`). Either way, grant Accessibility permission to the process running this MCP server.",
  );
}

function mapBackendError(err: unknown): AutomationError {
  const raw = err instanceof Error ? err.message : String(err);
  if (raw.includes("Accessibility permission not granted")) {
    return new AutomationError(
      "accessibility-denied",
      "Accessibility permission not granted. Open System Settings -> Privacy & Security -> Accessibility and enable the app running this MCP server.",
    );
  }
  return new AutomationError("input-failed", raw);
}

export async function moveMouse(x: number, y: number): Promise<void> {
  const backend = await resolveBackend();
  const px = String(Math.round(x));
  const py = String(Math.round(y));
  try {
    switch (backend.kind) {
      case "harness-input":
        await execFileAsync(backend.path, ["move", px, py]);
        return;
      case "cliclick":
        await execFileAsync("cliclick", [`m:${px},${py}`]);
        return;
      case "none":
        throwNoMouseBackend();
    }
  } catch (err) {
    throw mapBackendError(err);
  }
}

export async function click(
  x: number,
  y: number,
  button: MouseButton = "left",
  doubleClick = false,
): Promise<void> {
  if (button === "middle") {
    throw new AutomationError("unsupported-button", "middle-button clicks are not supported.");
  }
  const backend = await resolveBackend();
  const px = String(Math.round(x));
  const py = String(Math.round(y));
  try {
    switch (backend.kind) {
      case "harness-input": {
        const args = ["click", px, py, "--button", button];
        if (doubleClick) args.push("--double");
        await execFileAsync(backend.path, args);
        return;
      }
      case "cliclick": {
        if (doubleClick) {
          await execFileAsync("cliclick", [`dc:${px},${py}`]);
          return;
        }
        const verb = button === "right" ? "rc" : "c";
        await execFileAsync("cliclick", [`${verb}:${px},${py}`]);
        return;
      }
      case "none":
        throwNoMouseBackend();
    }
  } catch (err) {
    throw mapBackendError(err);
  }
}

export async function typeText(text: string, delayMillis = 0): Promise<void> {
  if (text.length === 0) {
    return;
  }
  const backend = await resolveBackend();
  try {
    switch (backend.kind) {
      case "harness-input": {
        const args = ["type"];
        if (delayMillis > 0) {
          args.push("--delay", String(delayMillis));
        }
        await runWithStdin(backend.path, args, text);
        return;
      }
      case "cliclick": {
        const args = delayMillis > 0 ? ["-w", String(delayMillis), `t:${text}`] : [`t:${text}`];
        await execFileAsync("cliclick", args);
        return;
      }
      case "none": {
        const script = `tell application "System Events" to keystroke ${JSON.stringify(text)}`;
        await execFileAsync("/usr/bin/osascript", ["-e", script]);
        return;
      }
    }
  } catch (err) {
    throw mapBackendError(err);
  }
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

// Exposed for tests.
export function _resetBackendCache(): void {
  cachedBackend = null;
}

async function runWithStdin(command: string, args: string[], input: string): Promise<void> {
  await new Promise<void>((resolvePromise, reject) => {
    const child = spawn(command, args, { stdio: ["pipe", "pipe", "pipe"] });
    let stderr = "";
    child.stderr.on("data", (chunk: Buffer) => {
      stderr += chunk.toString("utf8");
    });
    child.on("error", reject);
    child.on("close", (code) => {
      if (code === 0) {
        resolvePromise();
      } else {
        reject(new Error(stderr.trim().length > 0 ? stderr.trim() : `${command} exited with code ${code}`));
      }
    });
    child.stdin.end(input, "utf8");
  });
}
