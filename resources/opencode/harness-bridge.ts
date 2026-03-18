import type { Hooks, Plugin } from "@opencode-ai/plugin";
import { tool } from "@opencode-ai/plugin";
import { spawnSync } from "node:child_process";

// --- Types ---

interface HookSpecificOutput {
  additionalContext?: string;
  updatedInput?: Record<string, unknown>;
  permissionDecision?: string;
  permissionDecisionReason?: string;
  [key: string]: unknown;
}

interface HarnessResult {
  decision?: string;
  reason?: string;
  message?: string;
  additionalContext?: string;
  updatedInput?: Record<string, unknown>;
  hookSpecificOutput?: HookSpecificOutput;
}

// --- Injected by harness at bootstrap time ---

const DENIED_BINARY_HINTS = __DENIED_BINARY_HINTS__;
const TOOL_GUARDS: Record<string, string> = __TOOL_GUARDS__;
const TOOL_VERIFIERS: Record<string, string> = __TOOL_VERIFIERS__;

// --- Harness IPC ---

function invokeHarnessCommand(
  args: string[],
  input?: Record<string, unknown>,
): HarnessResult | null {
  const result = spawnSync("harness", args, {
    input: input ? JSON.stringify(input) : undefined,
    encoding: "utf-8",
    env: { ...process.env },
  });

  if (result.error) {
    throw new Error(`harness not found: ${result.error.message}`);
  }

  if (result.status === 2) {
    throw new Error(result.stderr?.trim() || "Blocked by harness");
  }

  if (result.status !== 0) {
    throw new Error(
      result.stderr?.trim() || `harness failed with status ${result.status}`,
    );
  }

  const stdout = result.stdout?.trim();
  if (!stdout) {
    return null;
  }

  return JSON.parse(stdout) as HarnessResult;
}

function invokeHarnessHook(
  hookName: string,
  payload: Record<string, unknown>,
): HarnessResult | null {
  return invokeHarnessCommand(
    ["hook", "--agent", "opencode", "suite:run", hookName],
    payload,
  );
}

// --- Result helpers ---

function additionalContext(result: HarnessResult | null): string | null {
  return (
    result?.additionalContext ??
    result?.hookSpecificOutput?.additionalContext ??
    null
  );
}

function isDenied(result: HarnessResult | null): boolean {
  return (
    result?.decision === "deny" ||
    result?.hookSpecificOutput?.permissionDecision === "deny"
  );
}

function denyReason(result: HarnessResult | null): string {
  return (
    result?.reason ||
    result?.hookSpecificOutput?.permissionDecisionReason ||
    result?.message ||
    "Blocked by harness"
  );
}

// --- Tool runner (used by LLM-facing tools; returns output rather than throwing) ---

function runHarness(args: string[], cwd: string): string {
  const result = spawnSync("harness", args, { encoding: "utf-8", cwd });
  return result.stdout || result.stderr || "";
}

// --- LLM-facing tools ---

const harnessTools = {
  harness_record: tool({
    description: "Record a tracked command during a test run",
    args: {
      command: tool.schema.string(),
      label: tool.schema.string().optional(),
      phase: tool.schema.string().optional(),
    },
    async execute(args, ctx) {
      const cmdArgs = ["record"];
      if (args.phase) cmdArgs.push("--phase", args.phase);
      if (args.label) cmdArgs.push("--label", args.label);
      cmdArgs.push("--", ...args.command.split(" "));
      return runHarness(cmdArgs, ctx.directory);
    },
  }),
  harness_apply: tool({
    description: "Apply manifests to the cluster",
    args: {
      manifest: tool.schema.string(),
      step: tool.schema.string().optional(),
    },
    async execute(args, ctx) {
      const cmdArgs = ["apply", "--manifest", args.manifest];
      if (args.step) cmdArgs.push("--step", args.step);
      return runHarness(cmdArgs, ctx.directory);
    },
  }),
  harness_status: tool({
    description: "Show current run status as JSON",
    args: {},
    async execute(_args, ctx) {
      return runHarness(["status"], ctx.directory);
    },
  }),
} satisfies NonNullable<Hooks["tool"]>;

// --- Plugin ---

export const HarnessPlugin: Plugin = async ({ directory, client }) => {
  const log = (
    level: "info" | "warn",
    message: string,
  ): ReturnType<typeof client.app.log> =>
    client.app.log({ body: { service: "harness", level, message } });

  let sessionContext: string | null = null;

  try {
    sessionContext = additionalContext(
      invokeHarnessCommand(["session-start", "--project-dir", directory]),
    );
  } catch (error) {
    await log("warn", `session-start failed: ${error}`);
  }

  if (DENIED_BINARY_HINTS.length > 0) {
    await log(
      "info",
      `harness shell guards active for: ${DENIED_BINARY_HINTS.join(", ")}`,
    );
  }

  const onToolBefore: NonNullable<Hooks["tool.execute.before"]> = async (
    input,
    output,
  ) => {
    const guardName = TOOL_GUARDS[input.tool];
    if (!guardName) {
      return;
    }

    const result = invokeHarnessHook(guardName, {
      tool_name: input.tool,
      tool_input: { ...output.args },
      cwd: directory,
      hook_event_name: "BeforeToolUse",
    });

    if (isDenied(result)) {
      throw new Error(denyReason(result));
    }

    const updated =
      result?.updatedInput ?? result?.hookSpecificOutput?.updatedInput;

    if (updated && typeof updated === "object") {
      Object.assign(output.args, updated);
    }
  };

  const onToolAfter: NonNullable<Hooks["tool.execute.after"]> = async (
    input,
    output,
  ) => {
    const payload = {
      tool_name: input.tool,
      tool_input: input.args,
      tool_response: output.output,
      cwd: directory,
      hook_event_name: "AfterToolUse",
    };

    const verifyName = TOOL_VERIFIERS[input.tool];

    if (verifyName) {
      try {
        const context = additionalContext(
          invokeHarnessHook(verifyName, payload),
        );
        if (context) {
          await log("info", context);
        }
      } catch (error) {
        await log("warn", `${verifyName}: ${error}`);
      }
    }

    try {
      invokeHarnessHook("audit", payload);
    } catch (error) {
      await log("warn", `audit: ${error}`);
    }
  };

  const onSystemTransform: NonNullable<
    Hooks["experimental.chat.system.transform"]
  > = async (_input, output) => {
    if (sessionContext) {
      output.system.push(sessionContext);
    }
  };

  const onSessionCompacting: NonNullable<
    Hooks["experimental.session.compacting"]
  > = async () => {
    try {
      invokeHarnessCommand(["pre-compact", "--project-dir", directory]);
    } catch (error) {
      await log("warn", `pre-compact: ${error}`);
    }
  };

  const onEvent: NonNullable<Hooks["event"]> = async ({ event }) => {
    if (event.type === "session.deleted") {
      try {
        invokeHarnessCommand(["session-stop", "--project-dir", directory]);
      } catch (error) {
        await log("warn", `session-stop: ${error}`);
      }
    }
  };

  return {
    "tool.execute.before": onToolBefore,
    "tool.execute.after": onToolAfter,
    "experimental.chat.system.transform": onSystemTransform,
    "experimental.session.compacting": onSessionCompacting,
    event: onEvent,
    tool: harnessTools,
  } satisfies Hooks;
};

export default HarnessPlugin;
