use std::sync::LazyLock;

pub(crate) struct TaskFamilySpec {
    pub(crate) name: &'static str,
}

#[cfg(test)]
pub(crate) struct EnforcementExample {
    pub(crate) command: &'static str,
    pub(crate) replacement: &'static str,
}

pub(crate) struct ScriptPolicy {
    pub(crate) basename: &'static str,
    pub(crate) task: &'static str,
    pub(crate) passthrough_args: bool,
}

pub(crate) struct BinaryPolicy {
    pub(crate) binary: &'static str,
    pub(crate) task: &'static str,
    pub(crate) passthrough_args: bool,
}

pub(crate) struct ExactChainPolicy {
    pub(crate) command_basename: &'static str,
    pub(crate) lhs_arg: &'static str,
    pub(crate) operator: &'static str,
    pub(crate) rhs_arg: &'static str,
    pub(crate) task: &'static str,
}

pub(crate) struct NamespaceFlagAlias {
    pub(crate) flag: &'static str,
    pub(crate) alias: &'static str,
}

pub(crate) struct NamespacePolicy {
    pub(crate) namespace: &'static str,
    pub(crate) subcommands: &'static [&'static str],
    pub(crate) flag_aliases: &'static [NamespaceFlagAlias],
}

pub(crate) struct WordRoute {
    pub(crate) path: &'static [&'static str],
    pub(crate) task: &'static str,
    pub(crate) passthrough_start: Option<usize>,
}

pub(crate) const TASK_FAMILY_SPECS: &[TaskFamilySpec] = &[
    TaskFamilySpec { name: "check" },
    TaskFamilySpec { name: "test" },
    TaskFamilySpec {
        name: "check:scripts",
    },
    TaskFamilySpec {
        name: "cargo:local",
    },
    TaskFamilySpec { name: "setup:*" },
    TaskFamilySpec { name: "version:*" },
    TaskFamilySpec {
        name: "monitor:macos:*",
    },
    TaskFamilySpec {
        name: "observability:*",
    },
    TaskFamilySpec {
        name: "host-metrics:*",
    },
    TaskFamilySpec { name: "mcp:*" },
    TaskFamilySpec { name: "preview:*" },
    TaskFamilySpec {
        name: "check:stale",
    },
    TaskFamilySpec {
        name: "clean:stale",
    },
];

#[cfg(test)]
pub(crate) const ENFORCEMENT_EXAMPLES: &[EnforcementExample] = &[
    EnforcementExample {
        command: "cargo test --lib cli::tests",
        replacement: "mise run cargo:local -- test --lib cli::tests",
    },
    EnforcementExample {
        command: "harness setup bootstrap --agents codex",
        replacement: "mise run setup:bootstrap -- --agents codex",
    },
    EnforcementExample {
        command: "./scripts/version.sh check",
        replacement: "mise run version:check",
    },
    EnforcementExample {
        command: "rtk env XCODE_ONLY_TESTING=HarnessMonitorKitTests/SupervisorServiceTests bash -lc 'mise run monitor:macos:test'",
        replacement: "XCODE_ONLY_TESTING=HarnessMonitorKitTests/SupervisorServiceTests mise run monitor:macos:test",
    },
    EnforcementExample {
        command: "./scripts/observability.sh stop && ./scripts/observability.sh start",
        replacement: "mise run observability:restart",
    },
    EnforcementExample {
        command: "./scripts/host-metrics.sh logs",
        replacement: "mise run host-metrics:logs",
    },
];

pub(crate) const SCRIPT_POLICIES: &[ScriptPolicy] = &[
    ScriptPolicy {
        basename: "check-no-stale-state.sh",
        task: "check:stale",
        passthrough_args: false,
    },
    ScriptPolicy {
        basename: "clean-stale-state.sh",
        task: "clean:stale",
        passthrough_args: false,
    },
    ScriptPolicy {
        basename: "check-scripts.sh",
        task: "check:scripts",
        passthrough_args: false,
    },
    ScriptPolicy {
        basename: "cargo-local.sh",
        task: "cargo:local",
        passthrough_args: true,
    },
    ScriptPolicy {
        basename: "post-generate.sh",
        task: "monitor:macos:generate",
        passthrough_args: false,
    },
    ScriptPolicy {
        basename: "xcodebuild-with-lock.sh",
        task: "monitor:macos:xcodebuild",
        passthrough_args: true,
    },
    ScriptPolicy {
        basename: "run-quality-gates.sh",
        task: "monitor:macos:lint",
        passthrough_args: false,
    },
    ScriptPolicy {
        basename: "test-swift.sh",
        task: "monitor:macos:test",
        passthrough_args: false,
    },
    ScriptPolicy {
        basename: "test-agents-e2e.sh",
        task: "monitor:macos:test:agents-e2e",
        passthrough_args: false,
    },
    ScriptPolicy {
        basename: "run-instruments-audit.sh",
        task: "monitor:macos:audit",
        passthrough_args: true,
    },
    ScriptPolicy {
        basename: "run-instruments-audit-from-ref.sh",
        task: "monitor:macos:audit:from-ref",
        passthrough_args: true,
    },
    ScriptPolicy {
        basename: "preview-render.sh",
        task: "preview:render",
        passthrough_args: true,
    },
    ScriptPolicy {
        basename: "preview-smoke.sh",
        task: "preview:smoke",
        passthrough_args: false,
    },
    ScriptPolicy {
        basename: "mcp-socket-path.sh",
        task: "mcp:socket-path",
        passthrough_args: false,
    },
    ScriptPolicy {
        basename: "mcp-smoke.sh",
        task: "mcp:smoke",
        passthrough_args: true,
    },
    ScriptPolicy {
        basename: "mcp-doctor.sh",
        task: "mcp:doctor",
        passthrough_args: false,
    },
    ScriptPolicy {
        basename: "mcp-register-claude.sh",
        task: "mcp:register-claude",
        passthrough_args: true,
    },
    ScriptPolicy {
        basename: "mcp-wait-socket.sh",
        task: "mcp:wait-socket",
        passthrough_args: true,
    },
    ScriptPolicy {
        basename: "mcp-launch-monitor.sh",
        task: "mcp:launch:monitor",
        passthrough_args: false,
    },
    ScriptPolicy {
        basename: "mcp-launch-dev.sh",
        task: "mcp:launch:dev",
        passthrough_args: false,
    },
];

pub(crate) const BINARY_POLICIES: &[BinaryPolicy] = &[
    BinaryPolicy {
        binary: "cargo",
        task: "cargo:local",
        passthrough_args: true,
    },
    BinaryPolicy {
        binary: "xcodebuild",
        task: "monitor:macos:xcodebuild",
        passthrough_args: true,
    },
];

/// Exact-chain shortcuts are intentional contracts, not parser cleverness.
/// Only these exact five-token stop/restart sequences collapse to a single task.
/// Nearby shapes still block, but they fall back to per-command suggestions.
pub(crate) const EXACT_CHAIN_POLICIES: &[ExactChainPolicy] = &[
    ExactChainPolicy {
        command_basename: "observability.sh",
        lhs_arg: "stop",
        operator: "&&",
        rhs_arg: "start",
        task: "observability:restart",
    },
    ExactChainPolicy {
        command_basename: "host-metrics.sh",
        lhs_arg: "stop",
        operator: "&&",
        rhs_arg: "start",
        task: "host-metrics:restart",
    },
];

pub(crate) const NAMESPACE_POLICIES: &[NamespacePolicy] = &[
    NamespacePolicy {
        namespace: "observability",
        subcommands: &[
            "start", "stop", "restart", "status", "logs", "open", "reset", "wipe", "smoke",
        ],
        flag_aliases: &[NamespaceFlagAlias {
            flag: "--restore-smoke-stack-fixture",
            alias: "restore-smoke-stack-fixture",
        }],
    },
    NamespacePolicy {
        namespace: "host-metrics",
        subcommands: &[
            "install",
            "uninstall",
            "start",
            "stop",
            "restart",
            "status",
            "metrics",
            "logs",
            "build-darwin-exporter",
        ],
        flag_aliases: &[],
    },
];

pub(crate) const VERSION_ROUTES: &[WordRoute] = &[
    WordRoute {
        path: &["show"],
        task: "version:show",
        passthrough_start: Some(1),
    },
    WordRoute {
        path: &["set"],
        task: "version:set",
        passthrough_start: Some(1),
    },
    WordRoute {
        path: &["sync"],
        task: "version:sync",
        passthrough_start: Some(1),
    },
    WordRoute {
        path: &["sync-monitor"],
        task: "version:sync:monitor",
        passthrough_start: Some(1),
    },
    WordRoute {
        path: &["check"],
        task: "version:check",
        passthrough_start: Some(1),
    },
];

pub(crate) const HARNESS_ROUTES: &[WordRoute] = &[
    WordRoute {
        path: &["setup", "agents", "generate", "--check"],
        task: "check:agent-assets",
        passthrough_start: None,
    },
    WordRoute {
        path: &["setup", "agents", "generate"],
        task: "setup:agents:generate",
        passthrough_start: Some(3),
    },
    WordRoute {
        path: &["setup", "bootstrap"],
        task: "setup:bootstrap",
        passthrough_start: Some(2),
    },
    WordRoute {
        path: &["mcp", "serve"],
        task: "mcp:serve",
        passthrough_start: None,
    },
];

pub(crate) static SESSION_START_CONTEXT: LazyLock<String> = LazyLock::new(|| {
    let task_families = TASK_FAMILY_SPECS
        .iter()
        .map(|spec| format!("`{}`", spec.name))
        .collect::<Vec<_>>()
        .join(", ");

    format!(
        "Repo policy:\n\
- Discover supported workflows with `mise tasks ls`.\n\
- Run repo-supported logic only through `mise run <task>` or `mise run <task> -- <args>`.\n\
- Run `mise` commands directly. Do not wrap them in `bash -lc`, `zsh -lc`, `rtk env`, `env`, or similar shells/wrappers.\n\
- Canonical task families here are {task_families}.\n\
- Do not run repo scripts directly. Do not run raw `cargo`, raw `xcodebuild`, or other manual command paths when a `mise` task already covers that workflow.\n\
\n\
Constraints:\n\
- Elevated permissions: every action carries weight; triage before acting.\n\
- Read-only system posture outside the working tree: before any local-machine mutation beyond repo files, stop and triage irreversible side effects.\n\
- Git history is append-only: only new forward commits. No rebase, amend, reset, force-push, checkout, restore, or stash.\n\
- Every commit uses `-sS`. After each commit, verify the signature and that the sign-off is exactly `Bart Smykla <bartek@smykla.com>`.\n\
- Before every commit, run `/council` on the intended diff and address any material findings before `git commit -sS`.\n\
- Before every commit, run the right build gate unless the change is only docs or version-sync noise: Rust -> `mise run check`; Swift -> `mise run monitor:macos:lint` plus the relevant build/test lane from `apps/harness-monitor-macos/CLAUDE.md`; cross-stack -> both gates.\n\
- Investigate the real code path before fixing: map call sites, state flow, cross-process boundaries, and existing tests.\n\
- Break work into the smallest independently committable chunks. Every chunk must leave the touched stacks buildable and test-passing.\n\
- For each chunk: write or tighten the test first and confirm red, implement the fix, confirm green, run the right gate, verify runtime behavior when it matters, commit with `-sS`, verify signature/sign-off, then continue.\n\
- After the last chunk, rerun every touched gate and resolve anything still open.\n\
- The session is not done until every part of the task is done. Do not stop early.\n\
- Use descriptive names, correct comments or none, remove dead code, keep functions under 100 lines, and keep important logic near the top of files.\n\
- Use native APIs and idiomatic code. Long-term fixes only. Do not suppress, silence, or work around the issue.\n\
- Check for performance regressions when touching hot paths, actors, async state machines, concurrency, or shared state.\n\
- Parallel agent awareness: if another agent owns a file, switch scope. If blocked for 5 minutes, ask the user and wait.\n\
- If 1Password is unavailable when commit signing is needed, hard stop and wait. Do not bypass 1Password or use a different key.\n"
    )
});
