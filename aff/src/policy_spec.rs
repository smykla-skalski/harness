use std::sync::LazyLock;

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

#[cfg(test)]
pub(crate) const ENFORCEMENT_EXAMPLES: &[EnforcementExample] = &[
    EnforcementExample {
        command: "cargo test --lib cli::tests",
        replacement: "mise cargo:local -- test --lib cli::tests",
    },
    EnforcementExample {
        command: "harness setup bootstrap --agents codex",
        replacement: "mise setup:bootstrap -- --agents codex",
    },
    EnforcementExample {
        command: "./scripts/version.sh check",
        replacement: "mise version:check",
    },
    EnforcementExample {
        command: "rtk env XCODE_ONLY_TESTING=HarnessMonitorKitTests/SupervisorServiceTests bash -lc 'mise monitor:macos:test'",
        replacement: "XCODE_ONLY_TESTING=HarnessMonitorKitTests/SupervisorServiceTests mise monitor:macos:test",
    },
    EnforcementExample {
        command: "./scripts/observability.sh stop && ./scripts/observability.sh start",
        replacement: "mise observability:restart",
    },
    EnforcementExample {
        command: "./scripts/host-metrics.sh logs",
        replacement: "mise host-metrics:logs",
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
    "Repo policy: Use `mise tasks ls` to discover workflows and `mise <task>` for all logic. Run `mise` directly without wrappers. Avoid raw `cargo` or `xcodebuild`. Constraints: Triage before acting as every action carries weight. Maintain read-only posture outside the working tree unless explicitly approved by user. Git history is append-only; no rebase, amend, or force-push. Use `git commit -sS` and verify sign-off is `Bart Smykla <bartek@smykla.com>`. Run build gates (Rust: `mise harness:check` for harness, `mise aff:check` for aff, Swift: `monitor:macos:lint` + lane) before committing unless the change is docs, version-sync, or tiny noise. Investigate call sites and state flow before fixing. Break work into small chunks. For each chunk: test first, implement, verify, run gate if significant, commit `-sS`, and verify. After the last chunk, ensure all touched gates pass unless final changes were trivial noise. Do not stop until the task is fully done. Rust files must be under 520 lines with functions under 100 lines and logic at the top. Module paths must have max 2 segments (e.g., `path::Path` OK, `std::path::Path` NO); use `use`. Use descriptive names and idiomatic code without suppressions. Check for performance regressions on hot paths. If blocked by another agent for 5 minutes, ask the user. Hard stop if 1Password is unavailable"
        .to_string()
});
