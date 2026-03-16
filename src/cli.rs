use std::path::PathBuf;

use clap::builder::PossibleValuesParser;
use clap::{Args, Parser, Subcommand};
use serde_json::json;

use crate::commands::Execute;
use crate::errors::CliError;
#[cfg(test)]
use crate::errors::CliErrorKind;
use crate::hook::{Decision, HookResult};
use crate::hook_payloads::HookContext;
use crate::hooks;
use crate::rules;

// ---------------------------------------------------------------------------
// Shared argument groups
// ---------------------------------------------------------------------------

/// Run-directory resolution arguments shared by many commands.
#[derive(Debug, Clone, Args)]
pub struct RunDirArgs {
    /// Run directory path.
    #[arg(long)]
    pub run_dir: Option<PathBuf>,
    /// Run ID to resolve from session context.
    #[arg(long)]
    pub run_id: Option<String>,
    /// Parent directory containing run directories.
    #[arg(long)]
    pub run_root: Option<PathBuf>,
}

/// Arguments for `harness init`.
#[derive(Debug, Clone, Args)]
pub struct InitArgs {
    /// Suite Markdown path or name.
    #[arg(long)]
    pub suite: String,
    /// Run ID to create under the run root.
    #[arg(long)]
    pub run_id: String,
    /// Suite profile to run (e.g. single-zone or multi-zone).
    #[arg(long)]
    pub profile: String,
    /// Repo root to record in run metadata.
    #[arg(long)]
    pub repo_root: Option<String>,
    /// Parent directory to create the run in.
    #[arg(long)]
    pub run_root: Option<String>,
}

/// Arguments for `harness cluster`.
#[derive(Debug, Clone, Args)]
pub struct ClusterArgs {
    /// Cluster lifecycle mode.
    #[arg(value_parser = [
        "single-up", "single-down",
        "global-zone-up", "global-zone-down",
        "global-two-zones-up", "global-two-zones-down",
    ])]
    pub mode: String,
    /// Primary cluster name.
    pub cluster_name: String,
    /// Additional cluster or zone names required by the mode.
    pub extra_cluster_names: Vec<String>,
    /// Deployment platform: kubernetes or universal.
    #[arg(long, default_value = "kubernetes")]
    pub platform: String,
    /// Repo root to run local Kuma build and deploy targets.
    #[arg(long)]
    pub repo_root: Option<String>,
    /// Run directory to update deployment state for.
    #[arg(long)]
    pub run_dir: Option<String>,
    /// Extra Helm setting for Kuma deployment; repeat as needed.
    #[arg(long)]
    pub helm_setting: Vec<String>,
    /// Namespace whose workloads to restart after deployment; repeat as needed.
    #[arg(long)]
    pub restart_namespace: Vec<String>,
    /// Store backend for universal mode: memory or postgres.
    #[arg(long, default_value = "memory")]
    pub store: String,
    /// CP container image override for universal mode.
    #[arg(long)]
    pub image: Option<String>,
}

/// Arguments for `harness record`.
#[derive(Debug, Clone, Args)]
pub struct RecordArgs {
    /// Repo root for local command resolution.
    #[arg(long)]
    pub repo_root: Option<String>,
    /// Optional phase tag for the command artifact name.
    #[arg(long)]
    pub phase: Option<String>,
    /// Optional label tag for the command artifact name.
    #[arg(long)]
    pub label: Option<String>,
    /// Tracked cluster member name for kubectl commands.
    #[arg(long)]
    pub cluster: Option<String>,
    /// Command to execute; prefix with -- to stop flag parsing.
    #[arg(allow_hyphen_values = true)]
    pub command: Vec<String>,
    /// Run-directory resolution.
    #[command(flatten)]
    pub run_dir: RunDirArgs,
}

/// Arguments for `harness apply`.
#[derive(Debug, Clone, Args)]
pub struct ApplyArgs {
    /// Use this kubeconfig instead of the tracked run cluster.
    #[arg(long)]
    pub kubeconfig: Option<String>,
    /// Target cluster name (uses its kubeconfig instead of primary).
    #[arg(long)]
    pub cluster: Option<String>,
    /// Manifest file or directory path. Repeat to preserve explicit batch order.
    #[arg(long, required = true)]
    pub manifest: Vec<String>,
    /// Optional step label for manifest index notes.
    #[arg(long)]
    pub step: Option<String>,
    /// Run-directory resolution.
    #[command(flatten)]
    pub run_dir: RunDirArgs,
}

/// Arguments for `harness runner-state`.
#[derive(Debug, Clone, Args)]
pub struct RunnerStateArgs {
    /// Workflow event to apply; omit to print the current phase.
    #[arg(long, value_parser = [
        "cluster-prepared", "preflight-started", "preflight-captured",
        "preflight-failed", "failure-manifest",
        "manifest-fix-run-only", "manifest-fix-suite-and-run",
        "manifest-fix-skip-step", "manifest-fix-stop-run",
        "suite-fix-resumed", "abort", "suspend", "resume-run",
        "closeout-started", "run-completed",
    ])]
    pub event: Option<String>,
    /// Suite-relative manifest path for manifest-fix events.
    #[arg(long)]
    pub suite_target: Option<String>,
    /// Optional message to record on the event.
    #[arg(long)]
    pub message: Option<String>,
    /// Run-directory resolution.
    #[command(flatten)]
    pub run_dir: RunDirArgs,
}

/// Arguments for `harness authoring-begin`.
#[derive(Debug, Clone, Args)]
pub struct AuthoringBeginArgs {
    /// Managed skill to initialize.
    #[arg(long, value_parser = PossibleValuesParser::new([rules::SKILL_NEW]))]
    pub skill: String,
    /// Kuma worktree for source discovery and validation.
    #[arg(long)]
    pub repo_root: String,
    /// Feature or capability being authored.
    #[arg(long)]
    pub feature: String,
    /// Authoring mode.
    #[arg(long, value_parser = ["interactive", "bypass"])]
    pub mode: String,
    /// Suite directory for this session.
    #[arg(long)]
    pub suite_dir: String,
    /// Suite name recorded in state and defaults.
    #[arg(long)]
    pub suite_name: String,
}

/// Arguments for `harness token`.
#[derive(Debug, Clone, Args)]
pub struct TokenArgs {
    /// Token kind: dataplane, ingress, or egress.
    #[arg(value_parser = ["dataplane", "ingress", "egress"])]
    pub kind: String,
    /// Dataplane name.
    #[arg(long)]
    pub name: String,
    /// Mesh name.
    #[arg(long, default_value = "default")]
    pub mesh: String,
    /// CP API address (auto-detected from run context if omitted).
    #[arg(long)]
    pub cp_addr: Option<String>,
    /// Token validity duration.
    #[arg(long, default_value = "24h")]
    pub valid_for: String,
    /// Run-directory resolution.
    #[command(flatten)]
    pub run_dir: RunDirArgs,
}

/// Arguments for `harness service`.
#[derive(Debug, Clone, Args)]
pub struct ServiceArgs {
    /// Service action.
    #[arg(value_parser = ["up", "down", "list"])]
    pub action: String,
    /// Service name.
    pub name: Option<String>,
    /// Service image.
    #[arg(long)]
    pub image: Option<String>,
    /// Service port.
    #[arg(long)]
    pub port: Option<u16>,
    /// Mesh name.
    #[arg(long, default_value = "default")]
    pub mesh: String,
    /// Enable transparent proxy.
    #[arg(long)]
    pub transparent_proxy: bool,
    /// Custom dataplane template path.
    #[arg(long)]
    pub dataplane_template: Option<String>,
    /// Run-directory resolution.
    #[command(flatten)]
    pub run_dir: RunDirArgs,
}

// ---------------------------------------------------------------------------
// Hook subcommands
// ---------------------------------------------------------------------------

/// Available hooks.
#[derive(Debug, Clone, Subcommand)]
#[non_exhaustive]
pub enum HookCommand {
    /// Guard Bash tool usage.
    GuardBash,
    /// Guard file write operations.
    GuardWrite,
    /// Guard `AskUserQuestion` prompts.
    GuardQuestion,
    /// Guard stop and session end.
    GuardStop,
    /// Verify Bash tool results.
    VerifyBash,
    /// Verify file write results.
    VerifyWrite,
    /// Verify question answers.
    VerifyQuestion,
    /// Audit hook events.
    Audit,
    /// Enrich failure context.
    EnrichFailure,
    /// Validate subagent startup context.
    ContextAgent,
    /// Validate subagent results.
    ValidateAgent,
}

impl HookCommand {
    /// CLI name of this hook (kebab-case).
    #[must_use]
    pub const fn name(&self) -> &'static str {
        match self {
            Self::GuardBash => "guard-bash",
            Self::GuardWrite => "guard-write",
            Self::GuardQuestion => "guard-question",
            Self::GuardStop => "guard-stop",
            Self::VerifyBash => "verify-bash",
            Self::VerifyWrite => "verify-write",
            Self::VerifyQuestion => "verify-question",
            Self::Audit => "audit",
            Self::EnrichFailure => "enrich-failure",
            Self::ContextAgent => "context-agent",
            Self::ValidateAgent => "validate-agent",
        }
    }

    /// Pre-tool-use guard hook.
    #[must_use]
    pub const fn is_pre_tool_use(&self) -> bool {
        matches!(
            self,
            Self::GuardBash | Self::GuardQuestion | Self::GuardWrite
        )
    }

    /// Post-tool-use verification hook.
    #[must_use]
    pub const fn is_post_tool_use(&self) -> bool {
        matches!(
            self,
            Self::VerifyBash | Self::VerifyQuestion | Self::VerifyWrite | Self::Audit
        )
    }

    /// Post-tool-use failure enrichment hook.
    #[must_use]
    pub const fn is_post_tool_use_failure(&self) -> bool {
        matches!(self, Self::EnrichFailure)
    }

    /// Subagent start hook.
    #[must_use]
    pub const fn is_subagent_start(&self) -> bool {
        matches!(self, Self::ContextAgent)
    }

    /// Subagent stop hook.
    #[must_use]
    pub const fn is_subagent_stop(&self) -> bool {
        matches!(self, Self::ValidateAgent)
    }

    /// Blocking stop-guard hook.
    #[must_use]
    pub const fn is_blocking(&self) -> bool {
        matches!(self, Self::GuardStop)
    }

    /// Any guard variant (pre-tool-use or blocking).
    #[must_use]
    pub const fn is_guard(&self) -> bool {
        matches!(
            self,
            Self::GuardBash | Self::GuardWrite | Self::GuardQuestion | Self::GuardStop
        )
    }
}

// ---------------------------------------------------------------------------
// Envoy subcommands
// ---------------------------------------------------------------------------

/// Envoy admin operations.
#[non_exhaustive]
#[derive(Debug, Clone, Subcommand)]
pub enum EnvoyCommand {
    /// Capture a live Envoy admin payload.
    Capture {
        /// Optional phase tag for the command artifact name.
        #[arg(long)]
        phase: Option<String>,
        /// Artifact label for the captured payload.
        #[arg(long)]
        label: String,
        /// Tracked cluster member name for multi-zone captures.
        #[arg(long)]
        cluster: Option<String>,
        /// Namespace of the workload to exec into.
        #[arg(long)]
        namespace: String,
        /// kubectl exec target (e.g. deploy/demo-client).
        #[arg(long)]
        workload: String,
        /// Container name inside the workload.
        #[arg(long, default_value = "kuma-sidecar")]
        container: String,
        /// Envoy admin path to fetch.
        #[arg(long, default_value = "/config_dump")]
        admin_path: String,
        /// Envoy admin host inside the container.
        #[arg(long, default_value = "127.0.0.1")]
        admin_host: String,
        /// Envoy admin port inside the container.
        #[arg(long, default_value_t = 9901)]
        admin_port: u16,
        /// Artifact format hint.
        #[arg(long, default_value = "auto")]
        format: String,
        /// Print only config entries whose @type contains this text.
        #[arg(long)]
        type_contains: Option<String>,
        /// Print only lines containing this text after type filtering.
        #[arg(long)]
        grep: Option<String>,
        /// Run-directory resolution.
        #[command(flatten)]
        run_dir: RunDirArgs,
    },
    /// Print a matching route from an Envoy config dump.
    RouteBody {
        /// Envoy config dump JSON file; omit to capture live.
        #[arg(long)]
        file: Option<String>,
        /// Exact route path or prefix to match.
        #[arg(long, name = "match")]
        route_match: String,
        /// Optional phase tag.
        #[arg(long)]
        phase: Option<String>,
        /// Artifact label.
        #[arg(long)]
        label: Option<String>,
        /// Tracked cluster member name.
        #[arg(long)]
        cluster: Option<String>,
        /// Namespace of the workload.
        #[arg(long)]
        namespace: Option<String>,
        /// kubectl exec target.
        #[arg(long)]
        workload: Option<String>,
        /// Container name.
        #[arg(long, default_value = "kuma-sidecar")]
        container: String,
        /// Envoy admin path.
        #[arg(long, default_value = "/config_dump")]
        admin_path: String,
        /// Envoy admin host.
        #[arg(long, default_value = "127.0.0.1")]
        admin_host: String,
        /// Envoy admin port.
        #[arg(long, default_value_t = 9901)]
        admin_port: u16,
        /// Artifact format hint.
        #[arg(long, default_value = "auto")]
        format: String,
        /// Run-directory resolution.
        #[command(flatten)]
        run_dir: RunDirArgs,
    },
    /// Print the bootstrap payload from an Envoy config dump.
    Bootstrap {
        /// Bootstrap JSON file; omit to capture live.
        #[arg(long)]
        file: Option<String>,
        /// Substring filter for rendered bootstrap output.
        #[arg(long)]
        grep: Option<String>,
        /// Optional phase tag.
        #[arg(long)]
        phase: Option<String>,
        /// Artifact label.
        #[arg(long)]
        label: Option<String>,
        /// Tracked cluster member name.
        #[arg(long)]
        cluster: Option<String>,
        /// Namespace of the workload.
        #[arg(long)]
        namespace: Option<String>,
        /// kubectl exec target.
        #[arg(long)]
        workload: Option<String>,
        /// Container name.
        #[arg(long, default_value = "kuma-sidecar")]
        container: String,
        /// Envoy admin path.
        #[arg(long, default_value = "/config_dump")]
        admin_path: String,
        /// Envoy admin host.
        #[arg(long, default_value = "127.0.0.1")]
        admin_host: String,
        /// Envoy admin port.
        #[arg(long, default_value_t = 9901)]
        admin_port: u16,
        /// Artifact format hint.
        #[arg(long, default_value = "auto")]
        format: String,
        /// Run-directory resolution.
        #[command(flatten)]
        run_dir: RunDirArgs,
    },
}

// ---------------------------------------------------------------------------
// Report subcommands
// ---------------------------------------------------------------------------

#[non_exhaustive]
/// Report validation and group finalization.
#[derive(Debug, Clone, Subcommand)]
pub enum ReportCommand {
    /// Validate report compactness.
    Check {
        /// Report path; defaults to the tracked run report.
        #[arg(long)]
        report: Option<String>,
    },
    /// Finalize a completed group.
    Group {
        /// Completed group ID (e.g. g02).
        #[arg(long)]
        group_id: String,
        /// Recorded group verdict.
        #[arg(long, value_parser = ["pass", "fail", "skip"])]
        status: String,
        /// Evidence file path; repeat to record multiple artifacts.
        #[arg(long)]
        evidence: Vec<String>,
        /// Recorded evidence label to resolve to the latest matching artifact.
        #[arg(long)]
        evidence_label: Vec<String>,
        /// Optional state-capture label to snapshot pod state before finalizing.
        #[arg(long)]
        capture_label: Option<String>,
        /// Optional one-line note to include in the story result.
        #[arg(long)]
        note: Option<String>,
        /// Run-directory resolution.
        #[command(flatten)]
        run_dir: RunDirArgs,
    },
}

// ---------------------------------------------------------------------------
// Kumactl subcommands
// ---------------------------------------------------------------------------

/// Find or build kumactl.
#[derive(Debug, Clone, Subcommand)]
#[non_exhaustive]
pub enum KumactlCommand {
    /// Find an existing kumactl binary.
    Find {
        /// Repo root to search for built kumactl artifacts.
        #[arg(long)]
        repo_root: Option<String>,
    },
    /// Build kumactl from source.
    Build {
        /// Repo root to build and locate kumactl.
        #[arg(long)]
        repo_root: Option<String>,
    },
}

// ---------------------------------------------------------------------------
// Top-level CLI
// ---------------------------------------------------------------------------

/// Kuma test harness CLI.
#[derive(Debug, Parser)]
#[command(name = "harness", version, about = "Kuma test harness")]
pub struct Cli {
    /// Subcommand to execute.
    #[command(subcommand)]
    pub command: Command,
}

/// Top-level commands.
#[derive(Debug, Subcommand)]
#[non_exhaustive]
pub enum Command {
    /// Run a harness hook for a skill.
    Hook {
        /// Skill name (suite:run or suite:new).
        #[arg(value_parser = PossibleValuesParser::new(rules::SKILL_NAMES))]
        skill: String,
        /// Hook to run.
        #[command(subcommand)]
        hook: HookCommand,
    },

    /// Initialize a new test run.
    #[command(alias = "init-run")]
    Init(InitArgs),

    /// Install or refresh the repo-aware harness wrapper.
    Bootstrap {
        /// Project directory to bootstrap the wrapper for.
        #[arg(long, env = "CLAUDE_PROJECT_DIR")]
        project_dir: Option<String>,
    },

    /// Manage disposable local k3d clusters.
    Cluster(ClusterArgs),

    /// Run preflight checks and prepare suite manifests.
    Preflight {
        /// Use this kubeconfig instead of the tracked run cluster.
        #[arg(long)]
        kubeconfig: Option<String>,
        /// Repo root for prepared-suite metadata.
        #[arg(long)]
        repo_root: Option<String>,
        /// Run-directory resolution.
        #[command(flatten)]
        run_dir: RunDirArgs,
    },

    /// Capture cluster pod state for a run.
    Capture {
        /// Use this kubeconfig instead of the tracked run cluster.
        #[arg(long)]
        kubeconfig: Option<String>,
        /// Label for the saved artifact filename.
        #[arg(long)]
        label: String,
        /// Run-directory resolution.
        #[command(flatten)]
        run_dir: RunDirArgs,
    },

    /// Record a tracked command.
    #[command(alias = "run", trailing_var_arg = true)]
    Record(RecordArgs),

    /// Apply manifests to the cluster.
    Apply(ApplyArgs),

    /// Validate manifests against the cluster.
    Validate {
        /// Use this kubeconfig instead of the tracked run cluster.
        #[arg(long)]
        kubeconfig: Option<String>,
        /// Manifest path.
        #[arg(long)]
        manifest: String,
        /// Validation log path; defaults beside the manifest artifact.
        #[arg(long)]
        output: Option<String>,
    },

    /// Manage runner workflow state.
    RunnerState(RunnerStateArgs),

    /// Close out a run.
    Closeout {
        /// Run-directory resolution.
        #[command(flatten)]
        run_dir: RunDirArgs,
    },

    /// Report validation and group finalization.
    Report {
        /// Report subcommand.
        #[command(subcommand)]
        cmd: ReportCommand,
    },

    /// View diffs between payloads.
    Diff {
        /// Left file path.
        #[arg(long)]
        left: String,
        /// Right file path.
        #[arg(long)]
        right: String,
        /// Optional dotted path inside parsed JSON payloads.
        #[arg(long)]
        path: Option<String>,
    },

    /// Envoy admin operations.
    Envoy {
        /// Envoy subcommand.
        #[command(subcommand)]
        cmd: EnvoyCommand,
    },

    /// Check or install Gateway API CRDs.
    Gateway {
        /// Use this kubeconfig for the target local cluster.
        #[arg(long)]
        kubeconfig: Option<String>,
        /// Repo root to resolve the pinned Gateway API version.
        #[arg(long)]
        repo_root: Option<String>,
        /// Only check whether the Gateway API CRDs are already installed.
        #[arg(long)]
        check_only: bool,
    },

    /// Find or build kumactl.
    Kumactl {
        /// Kumactl subcommand.
        #[command(subcommand)]
        cmd: KumactlCommand,
    },

    /// Handle session start hook.
    SessionStart {
        /// Project directory to restore session state for.
        #[arg(long, env = "CLAUDE_PROJECT_DIR")]
        project_dir: Option<String>,
    },

    /// Handle session stop cleanup.
    SessionStop {
        /// Project directory to clean up.
        #[arg(long, env = "CLAUDE_PROJECT_DIR")]
        project_dir: Option<String>,
    },

    /// Save compact handoff before compaction.
    PreCompact {
        /// Project directory to save the compact handoff for.
        #[arg(long, env = "CLAUDE_PROJECT_DIR")]
        project_dir: Option<String>,
    },

    /// Begin a suite:new workspace session.
    AuthoringBegin(AuthoringBeginArgs),

    /// Save a suite:new payload.
    AuthoringSave {
        /// Suite:new payload kind.
        #[arg(long, value_parser = [
            "inventory", "coverage", "variants", "schema",
            "proposal", "edit-request",
        ])]
        kind: String,
        /// Inline JSON payload.
        #[arg(long)]
        payload: Option<String>,
        /// Read JSON from a file; use stdin only as fallback.
        #[arg(long)]
        input: Option<String>,
    },

    /// Show saved suite:new payloads.
    AuthoringShow {
        /// Saved suite:new payload kind.
        #[arg(long)]
        kind: String,
    },

    /// Reset suite:new workspace.
    AuthoringReset {
        /// Managed skill whose saved workspace should be cleared.
        #[arg(long, value_parser = PossibleValuesParser::new([rules::SKILL_NEW]))]
        skill: String,
    },

    /// Validate authored manifests against local CRDs.
    AuthoringValidate {
        /// Manifest or group Markdown path; repeat for multiple inputs.
        #[arg(long, required = true)]
        path: Vec<String>,
        /// Repo root for locating checked-in CRDs.
        #[arg(long)]
        repo_root: Option<String>,
    },

    /// Begin suite:new approval flow.
    ApprovalBegin {
        /// Managed skill to initialize.
        #[arg(long, value_parser = PossibleValuesParser::new([rules::SKILL_NEW]))]
        skill: String,
        /// Approval mode.
        #[arg(long, value_parser = ["interactive", "bypass"])]
        mode: String,
        /// Optional suite directory for the approval state.
        #[arg(long)]
        suite_dir: Option<String>,
    },

    /// Generate a dataplane token from the control plane (universal mode).
    Token(TokenArgs),

    /// Manage universal mode test service containers.
    Service(ServiceArgs),

    /// Report harness capabilities for skill planning.
    Capabilities,
}

// ---------------------------------------------------------------------------
// Hook output rendering
// ---------------------------------------------------------------------------

/// Format a hook result message with level prefix.
fn render_hook_message(result: &HookResult) -> String {
    if result.code.is_empty() {
        return result.message.clone();
    }
    let level = match result.decision {
        Decision::Warn => "WARNING",
        Decision::Info => "INFO",
        Decision::Allow | Decision::Deny => "ERROR",
    };
    if result.message.is_empty() {
        format!("{level} [{}]", result.code)
    } else {
        format!("{level} [{}] {}", result.code, result.message)
    }
}

/// Render a `PreToolUse` hook output (guard-bash, guard-write, guard-question).
fn render_pre_tool_use_output(result: &HookResult) -> String {
    if result.decision == Decision::Allow {
        return String::new();
    }
    let message = render_hook_message(result);
    serde_json::to_string(&json!({
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": message,
        }
    }))
    .expect("hand-built JSON serializes")
}

/// Render a blocking hook output (guard-stop, or any deny from unknown hooks).
fn render_blocking_hook_output(result: &HookResult) -> String {
    if result.decision == Decision::Allow {
        return String::new();
    }
    let message = render_hook_message(result);
    if result.decision == Decision::Deny {
        serde_json::to_string(&json!({"decision": "block", "reason": message}))
            .expect("hand-built JSON serializes")
    } else {
        serde_json::to_string(&json!({"systemMessage": message}))
            .expect("hand-built JSON serializes")
    }
}

/// Render a `PostToolUse`-family hook output (verify-*, audit, enrich-failure,
/// validate-agent).
fn render_post_tool_use_output(result: &HookResult, event_name: &str) -> String {
    if result.decision == Decision::Allow {
        return String::new();
    }
    let message = render_hook_message(result);
    let mut payload = json!({
        "hookSpecificOutput": {
            "hookEventName": event_name,
            "additionalContext": message,
        }
    });
    if result.decision == Decision::Deny {
        payload["decision"] = json!("block");
        payload["reason"] = json!(message);
    }
    serde_json::to_string(&payload).expect("hand-built JSON serializes")
}

/// Render an additional-context hook output (context-agent, notification).
fn render_additional_context_output(result: &HookResult, event_name: &str) -> String {
    if result.decision == Decision::Allow {
        return String::new();
    }
    serde_json::to_string(&json!({
        "hookSpecificOutput": {
            "hookEventName": event_name,
            "additionalContext": render_hook_message(result),
        }
    }))
    .expect("hand-built JSON serializes")
}

/// Transform a `HookResult` into the native Claude Code hook output format for
/// the given hook name.
#[must_use]
pub fn render_hook_output(hook: &HookCommand, result: &HookResult) -> String {
    if result.decision == Decision::Allow && result.code.is_empty() {
        return String::new();
    }
    if hook.is_pre_tool_use() {
        return render_pre_tool_use_output(result);
    }
    if hook.is_post_tool_use() {
        return render_post_tool_use_output(result, "PostToolUse");
    }
    if hook.is_post_tool_use_failure() {
        return render_post_tool_use_output(result, "PostToolUseFailure");
    }
    if hook.is_subagent_start() {
        return render_additional_context_output(result, "SubagentStart");
    }
    if hook.is_subagent_stop() {
        return render_post_tool_use_output(result, "SubagentStop");
    }
    if hook.is_blocking() {
        return render_blocking_hook_output(result);
    }
    render_additional_context_output(result, "Notification")
}

// ---------------------------------------------------------------------------
// Hook dispatch helpers
// ---------------------------------------------------------------------------

/// Dispatch to the correct hook module based on the hook command variant.
fn dispatch_hook(hook: &HookCommand, ctx: &HookContext) -> Result<HookResult, CliError> {
    match hook {
        HookCommand::GuardBash => hooks::guard_bash::execute(ctx),
        HookCommand::GuardWrite => hooks::guard_write::execute(ctx),
        HookCommand::GuardQuestion => hooks::guard_question::execute(ctx),
        HookCommand::GuardStop => hooks::guard_stop::execute(ctx),
        HookCommand::VerifyBash => hooks::verify_bash::execute(ctx),
        HookCommand::VerifyWrite => hooks::verify_write::execute(ctx),
        HookCommand::VerifyQuestion => hooks::verify_question::execute(ctx),
        HookCommand::Audit => hooks::audit::execute(ctx),
        HookCommand::EnrichFailure => hooks::enrich_failure::execute(ctx),
        HookCommand::ContextAgent => hooks::context_agent::execute(ctx),
        HookCommand::ValidateAgent => hooks::validate_agent::execute(ctx),
    }
}

/// Build a runtime `HookResult` for an error during hook execution.
/// Guard hooks produce deny; verify/other hooks produce warn.
fn hook_runtime_result(hook: &HookCommand, code: &str, message: &str) -> HookResult {
    if hook.is_guard() {
        HookResult::deny(code, message)
    } else {
        HookResult::warn(code, message)
    }
}

/// Format a `CliError` as a detail string for hook error wrapping.
fn format_hook_error_detail(hook: &HookCommand, error: &CliError) -> String {
    let hook_name = hook.name();
    let mut parts = vec![format!("`{hook_name}` failed internally: {error}")];
    if let Some(hint) = error.hint() {
        parts.push(format!("Hint: {hint}"));
    }
    if let Some(details) = error.details() {
        parts.push(format!("Details: {details}"));
    }
    parts.join(" ")
}

/// Execute a hook command: build context, dispatch, render output.
fn run_hook_command(skill: &str, hook: &HookCommand) -> i32 {
    let hook_name = hook.name();

    let ctx = match HookContext::from_stdin(skill) {
        Ok(ctx) => ctx,
        Err(e) => {
            let message = format!("`{hook_name}` received invalid hook payload: {e}");
            let result = hook_runtime_result(hook, "KSH001", &message);
            let output = render_hook_output(hook, &result);
            if !output.is_empty() {
                print!("{output}");
            }
            return 0;
        }
    };

    let result = match dispatch_hook(hook, &ctx) {
        Ok(result) => result,
        Err(e) => {
            let detail = format_hook_error_detail(hook, &e);
            hook_runtime_result(hook, "KSH002", &detail)
        }
    };

    let output = render_hook_output(hook, &result);
    if !output.is_empty() {
        print!("{output}");
    }
    0
}

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

/// Parse CLI arguments and run the appropriate command.
///
/// # Errors
/// Returns `CliError` on command failure. Hook errors are handled internally
/// and never surface as `CliError` - they are rendered as hook output JSON on
/// stdout and the function returns `Ok(0)`.
pub fn run() -> Result<i32, CliError> {
    let cli = Cli::parse();
    match cli.command {
        Command::Hook {
            ref skill,
            ref hook,
        } => Ok(run_hook_command(skill, hook)),
        other => other.execute(),
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use clap::CommandFactory;

    // --- CLI parsing tests ---

    #[test]
    fn all_expected_subcommands_registered() {
        let cmd = Cli::command();
        let names: Vec<&str> = cmd.get_subcommands().map(clap::Command::get_name).collect();
        for expected in [
            "apply",
            "approval-begin",
            "authoring-begin",
            "authoring-reset",
            "authoring-save",
            "authoring-show",
            "authoring-validate",
            "bootstrap",
            "capture",
            "closeout",
            "cluster",
            "diff",
            "envoy",
            "gateway",
            "hook",
            "init",
            "kumactl",
            "pre-compact",
            "preflight",
            "record",
            "report",
            "runner-state",
            "session-start",
            "session-stop",
            "validate",
        ] {
            assert!(names.contains(&expected), "missing subcommand: {expected}");
        }
    }

    #[test]
    fn hook_subcommand_lists_all_hooks() {
        let cmd = Cli::command();
        let hook_cmd = cmd
            .get_subcommands()
            .find(|s| s.get_name() == "hook")
            .expect("hook subcommand missing");
        let hook_names: Vec<&str> = hook_cmd
            .get_subcommands()
            .map(clap::Command::get_name)
            .collect();
        for expected in [
            "guard-bash",
            "guard-write",
            "guard-question",
            "guard-stop",
            "verify-bash",
            "verify-write",
            "verify-question",
            "audit",
            "enrich-failure",
            "context-agent",
            "validate-agent",
        ] {
            assert!(hook_names.contains(&expected), "missing hook: {expected}");
        }
    }

    #[test]
    fn parse_hook_command() {
        let cli = Cli::try_parse_from(["harness", "hook", "suite:run", "guard-bash"]).unwrap();
        match cli.command {
            Command::Hook { skill, hook } => {
                assert_eq!(skill, "suite:run");
                assert_eq!(hook.name(), "guard-bash");
            }
            _ => panic!("expected Hook command"),
        }
    }

    #[test]
    fn parse_hook_rejects_invalid_skill() {
        let result = Cli::try_parse_from(["harness", "hook", "bad-skill", "guard-bash"]);
        assert!(result.is_err());
    }

    #[test]
    fn parse_init_command() {
        let cli = Cli::try_parse_from([
            "harness",
            "init",
            "--suite",
            "suite.md",
            "--run-id",
            "r01",
            "--profile",
            "single-zone",
        ])
        .unwrap();
        match cli.command {
            Command::Init(InitArgs {
                suite,
                run_id,
                profile,
                repo_root,
                run_root,
            }) => {
                assert_eq!(suite, "suite.md");
                assert_eq!(run_id, "r01");
                assert_eq!(profile, "single-zone");
                assert!(repo_root.is_none());
                assert!(run_root.is_none());
            }
            _ => panic!("expected Init command"),
        }
    }

    #[test]
    fn parse_init_run_alias() {
        let cli = Cli::try_parse_from([
            "harness",
            "init-run",
            "--suite",
            "s.md",
            "--run-id",
            "r01",
            "--profile",
            "p",
        ])
        .unwrap();
        assert!(matches!(cli.command, Command::Init(..)));
    }

    #[test]
    fn parse_record_with_trailing_command() {
        let cli = Cli::try_parse_from([
            "harness",
            "record",
            "--label",
            "test",
            "--",
            "kubectl",
            "get",
            "pods",
            "-n",
            "kuma-system",
        ])
        .unwrap();
        match cli.command {
            Command::Record(RecordArgs { label, command, .. }) => {
                assert_eq!(label.as_deref(), Some("test"));
                assert_eq!(command, vec!["kubectl", "get", "pods", "-n", "kuma-system"]);
            }
            _ => panic!("expected Record command"),
        }
    }

    #[test]
    fn parse_run_alias_for_record() {
        let cli = Cli::try_parse_from(["harness", "run", "--label", "foo", "--", "ls"]).unwrap();
        assert!(matches!(cli.command, Command::Record(..)));
    }

    #[test]
    fn parse_cluster_with_extra_names() {
        let cli = Cli::try_parse_from([
            "harness",
            "cluster",
            "global-zone-up",
            "global",
            "zone1",
            "zone2",
        ])
        .unwrap();
        match cli.command {
            Command::Cluster(ClusterArgs {
                mode,
                cluster_name,
                extra_cluster_names,
                ..
            }) => {
                assert_eq!(mode, "global-zone-up");
                assert_eq!(cluster_name, "global");
                assert_eq!(extra_cluster_names, vec!["zone1", "zone2"]);
            }
            _ => panic!("expected Cluster command"),
        }
    }

    #[test]
    fn parse_apply_requires_manifest() {
        let result = Cli::try_parse_from(["harness", "apply"]);
        assert!(result.is_err());
    }

    #[test]
    fn parse_apply_multiple_manifests() {
        let cli = Cli::try_parse_from([
            "harness",
            "apply",
            "--manifest",
            "g14/02.yaml",
            "--manifest",
            "g14/01.yaml",
        ])
        .unwrap();
        match cli.command {
            Command::Apply(ApplyArgs { manifest, .. }) => {
                assert_eq!(manifest, vec!["g14/02.yaml", "g14/01.yaml"]);
            }
            _ => panic!("expected Apply command"),
        }
    }

    #[test]
    fn parse_envoy_capture() {
        let cli = Cli::try_parse_from([
            "harness",
            "envoy",
            "capture",
            "--namespace",
            "kuma-demo",
            "--workload",
            "deploy/demo-client",
            "--label",
            "cap1",
        ])
        .unwrap();
        match cli.command {
            Command::Envoy {
                cmd:
                    EnvoyCommand::Capture {
                        namespace,
                        workload,
                        label,
                        ..
                    },
            } => {
                assert_eq!(namespace, "kuma-demo");
                assert_eq!(workload, "deploy/demo-client");
                assert_eq!(label, "cap1");
            }
            _ => panic!("expected Envoy Capture command"),
        }
    }

    #[test]
    fn parse_report_group() {
        let cli = Cli::try_parse_from([
            "harness",
            "report",
            "group",
            "--group-id",
            "g01",
            "--status",
            "pass",
        ])
        .unwrap();
        match cli.command {
            Command::Report {
                cmd:
                    ReportCommand::Group {
                        group_id, status, ..
                    },
            } => {
                assert_eq!(group_id, "g01");
                assert_eq!(status, "pass");
            }
            _ => panic!("expected Report Group command"),
        }
    }

    #[test]
    fn parse_runner_state_without_event() {
        let cli = Cli::try_parse_from(["harness", "runner-state"]).unwrap();
        match cli.command {
            Command::RunnerState(RunnerStateArgs { event, .. }) => {
                assert!(event.is_none());
            }
            _ => panic!("expected RunnerState command"),
        }
    }

    #[test]
    fn parse_runner_state_with_event() {
        let cli = Cli::try_parse_from(["harness", "runner-state", "--event", "abort"]).unwrap();
        match cli.command {
            Command::RunnerState(RunnerStateArgs { event, .. }) => {
                assert_eq!(event.as_deref(), Some("abort"));
            }
            _ => panic!("expected RunnerState command"),
        }
    }

    #[test]
    fn parse_authoring_begin() {
        let cli = Cli::try_parse_from([
            "harness",
            "authoring-begin",
            "--skill",
            "suite:new",
            "--repo-root",
            "/repo",
            "--feature",
            "mesh-traffic",
            "--mode",
            "interactive",
            "--suite-dir",
            "/suites/mesh",
            "--suite-name",
            "mesh-suite",
        ])
        .unwrap();
        match cli.command {
            Command::AuthoringBegin(AuthoringBeginArgs {
                skill,
                feature,
                mode,
                ..
            }) => {
                assert_eq!(skill, "suite:new");
                assert_eq!(feature, "mesh-traffic");
                assert_eq!(mode, "interactive");
            }
            _ => panic!("expected AuthoringBegin command"),
        }
    }

    #[test]
    fn parse_kumactl_find() {
        let cli = Cli::try_parse_from(["harness", "kumactl", "find"]).unwrap();
        assert!(matches!(
            cli.command,
            Command::Kumactl {
                cmd: KumactlCommand::Find { .. }
            }
        ));
    }

    #[test]
    fn parse_diff() {
        let cli = Cli::try_parse_from(["harness", "diff", "--left", "a.json", "--right", "b.json"])
            .unwrap();
        match cli.command {
            Command::Diff {
                left, right, path, ..
            } => {
                assert_eq!(left, "a.json");
                assert_eq!(right, "b.json");
                assert!(path.is_none());
            }
            _ => panic!("expected Diff command"),
        }
    }

    // --- Help text tests ---

    #[test]
    fn apply_help_describes_batch_inputs() {
        let cmd = Cli::command();
        let apply_cmd = cmd
            .get_subcommands()
            .find(|s| s.get_name() == "apply")
            .expect("apply missing");
        let manifest_arg = apply_cmd
            .get_arguments()
            .find(|a| a.get_id() == "manifest")
            .expect("manifest arg missing");
        let help = manifest_arg
            .get_help()
            .map(ToString::to_string)
            .unwrap_or_default();
        assert!(
            help.contains("explicit batch order"),
            "apply --manifest help must mention explicit batch order"
        );
    }

    #[test]
    fn envoy_capture_help_has_required_args() {
        let cmd = Cli::command();
        let envoy_cmd = cmd
            .get_subcommands()
            .find(|s| s.get_name() == "envoy")
            .expect("envoy missing");
        let capture_cmd = envoy_cmd
            .get_subcommands()
            .find(|s| s.get_name() == "capture")
            .expect("capture missing");
        let arg_names: Vec<&str> = capture_cmd
            .get_arguments()
            .map(|a| a.get_id().as_str())
            .collect();
        for required in ["label", "namespace", "workload"] {
            assert!(
                arg_names.contains(&required),
                "envoy capture missing arg: {required}"
            );
        }
        for optional in ["type_contains", "grep"] {
            assert!(
                arg_names.contains(&optional),
                "envoy capture missing arg: {optional}"
            );
        }
    }

    // --- Hook rendering tests ---

    #[test]
    fn render_hook_message_deny() {
        let r = HookResult::deny("KSR005", "blocked");
        assert_eq!(render_hook_message(&r), "ERROR [KSR005] blocked");
    }

    #[test]
    fn render_hook_message_warn() {
        let r = HookResult::warn("KSR006", "caution");
        assert_eq!(render_hook_message(&r), "WARNING [KSR006] caution");
    }

    #[test]
    fn render_hook_message_info() {
        let r = HookResult::info("KSR012", "ok");
        assert_eq!(render_hook_message(&r), "INFO [KSR012] ok");
    }

    #[test]
    fn render_hook_message_empty_code() {
        let r = HookResult {
            decision: Decision::Warn,
            code: String::new(),
            message: "just a message".to_string(),
        };
        assert_eq!(render_hook_message(&r), "just a message");
    }

    #[test]
    fn render_hook_message_empty_message() {
        let r = HookResult {
            decision: Decision::Deny,
            code: "KSR005".to_string(),
            message: String::new(),
        };
        assert_eq!(render_hook_message(&r), "ERROR [KSR005]");
    }

    #[test]
    fn pre_tool_use_allow_is_empty() {
        assert!(render_pre_tool_use_output(&HookResult::allow()).is_empty());
    }

    #[test]
    fn pre_tool_use_deny_has_permission_decision() {
        let r = HookResult::deny("KSR005", "blocked");
        let output = render_pre_tool_use_output(&r);
        let v: serde_json::Value = serde_json::from_str(&output).unwrap();
        assert_eq!(v["hookSpecificOutput"]["hookEventName"], "PreToolUse");
        assert_eq!(v["hookSpecificOutput"]["permissionDecision"], "deny");
        assert!(
            v["hookSpecificOutput"]["permissionDecisionReason"]
                .as_str()
                .unwrap()
                .contains("KSR005")
        );
    }

    #[test]
    fn blocking_allow_is_empty() {
        assert!(render_blocking_hook_output(&HookResult::allow()).is_empty());
    }

    #[test]
    fn blocking_deny_has_block_decision() {
        let r = HookResult::deny("KSR007", "incomplete");
        let output = render_blocking_hook_output(&r);
        let v: serde_json::Value = serde_json::from_str(&output).unwrap();
        assert_eq!(v["decision"], "block");
        assert!(v["reason"].as_str().unwrap().contains("KSR007"));
    }

    #[test]
    fn blocking_warn_has_system_message() {
        let r = HookResult::warn("KSR006", "missing");
        let output = render_blocking_hook_output(&r);
        let v: serde_json::Value = serde_json::from_str(&output).unwrap();
        assert!(v["systemMessage"].as_str().unwrap().contains("KSR006"));
        assert!(v.get("decision").is_none());
    }

    #[test]
    fn post_tool_use_allow_is_empty() {
        assert!(render_post_tool_use_output(&HookResult::allow(), "PostToolUse").is_empty());
    }

    #[test]
    fn post_tool_use_deny_includes_block() {
        let r = HookResult::deny("KSR014", "phase");
        let output = render_post_tool_use_output(&r, "PostToolUse");
        let v: serde_json::Value = serde_json::from_str(&output).unwrap();
        assert_eq!(v["decision"], "block");
        assert_eq!(v["hookSpecificOutput"]["hookEventName"], "PostToolUse");
        assert!(
            v["hookSpecificOutput"]["additionalContext"]
                .as_str()
                .unwrap()
                .contains("KSR014")
        );
    }

    #[test]
    fn post_tool_use_warn_no_block() {
        let r = HookResult::warn("KSR006", "artifact");
        let output = render_post_tool_use_output(&r, "PostToolUse");
        let v: serde_json::Value = serde_json::from_str(&output).unwrap();
        assert!(v.get("decision").is_none());
        assert_eq!(v["hookSpecificOutput"]["hookEventName"], "PostToolUse");
    }

    #[test]
    fn additional_context_allow_is_empty() {
        assert!(render_additional_context_output(&HookResult::allow(), "SubagentStart").is_empty());
    }

    #[test]
    fn additional_context_warn_has_event_name() {
        let r = HookResult::warn("KSA006", "format");
        let output = render_additional_context_output(&r, "SubagentStart");
        let v: serde_json::Value = serde_json::from_str(&output).unwrap();
        assert_eq!(v["hookSpecificOutput"]["hookEventName"], "SubagentStart");
    }

    // --- render_hook_output routing tests ---

    #[test]
    fn hook_output_guard_bash_routes_to_pre_tool_use() {
        let r = HookResult::deny("KSR005", "blocked");
        let output = render_hook_output(&HookCommand::GuardBash, &r);
        let v: serde_json::Value = serde_json::from_str(&output).unwrap();
        assert_eq!(v["hookSpecificOutput"]["hookEventName"], "PreToolUse");
    }

    #[test]
    fn hook_output_verify_bash_routes_to_post_tool_use() {
        let r = HookResult::warn("KSR006", "missing");
        let output = render_hook_output(&HookCommand::VerifyBash, &r);
        let v: serde_json::Value = serde_json::from_str(&output).unwrap();
        assert_eq!(v["hookSpecificOutput"]["hookEventName"], "PostToolUse");
    }

    #[test]
    fn hook_output_guard_stop_routes_to_blocking() {
        let r = HookResult::deny("KSR007", "incomplete");
        let output = render_hook_output(&HookCommand::GuardStop, &r);
        let v: serde_json::Value = serde_json::from_str(&output).unwrap();
        assert_eq!(v["decision"], "block");
    }

    #[test]
    fn hook_output_enrich_failure_routes_to_post_tool_use_failure() {
        let r = HookResult::warn("KSR012", "verdict");
        let output = render_hook_output(&HookCommand::EnrichFailure, &r);
        let v: serde_json::Value = serde_json::from_str(&output).unwrap();
        assert_eq!(
            v["hookSpecificOutput"]["hookEventName"],
            "PostToolUseFailure"
        );
    }

    #[test]
    fn hook_output_context_agent_routes_to_subagent_start() {
        let r = HookResult::warn("KSA006", "format");
        let output = render_hook_output(&HookCommand::ContextAgent, &r);
        let v: serde_json::Value = serde_json::from_str(&output).unwrap();
        assert_eq!(v["hookSpecificOutput"]["hookEventName"], "SubagentStart");
    }

    #[test]
    fn hook_output_validate_agent_routes_to_subagent_stop() {
        let r = HookResult::deny("KSA007", "reply");
        let output = render_hook_output(&HookCommand::ValidateAgent, &r);
        let v: serde_json::Value = serde_json::from_str(&output).unwrap();
        assert_eq!(v["hookSpecificOutput"]["hookEventName"], "SubagentStop");
    }

    #[test]
    fn hook_output_allow_is_always_empty() {
        for hook in [
            HookCommand::GuardBash,
            HookCommand::GuardStop,
            HookCommand::VerifyBash,
            HookCommand::EnrichFailure,
            HookCommand::ContextAgent,
            HookCommand::ValidateAgent,
        ] {
            assert!(
                render_hook_output(&hook, &HookResult::allow()).is_empty(),
                "allow should be empty for {}",
                hook.name()
            );
        }
    }

    // --- Hook wrapping tests ---

    #[test]
    fn hook_runtime_result_guard_is_deny() {
        let r = hook_runtime_result(&HookCommand::GuardBash, "KSH002", "error");
        assert_eq!(r.decision, Decision::Deny);
    }

    #[test]
    fn hook_runtime_result_verify_is_warn() {
        let r = hook_runtime_result(&HookCommand::VerifyBash, "KSH002", "error");
        assert_eq!(r.decision, Decision::Warn);
    }

    #[test]
    fn hook_runtime_result_other_is_warn() {
        let r = hook_runtime_result(&HookCommand::Audit, "KSH002", "error");
        assert_eq!(r.decision, Decision::Warn);
    }

    #[test]
    fn format_error_detail_includes_code_and_message() {
        let error: CliError = CliErrorKind::MissingRunPointer.into();
        let detail = format_hook_error_detail(&HookCommand::GuardBash, &error);
        assert!(detail.contains("guard-bash"));
        assert!(detail.contains("KSRCLI005"));
        assert!(detail.contains("missing current run pointer"));
        assert!(detail.contains("Hint: Run init first."));
    }

    #[test]
    fn format_error_detail_includes_details() {
        let error = CliErrorKind::command_failed("command failed").with_details("exit code 1");
        let detail = format_hook_error_detail(&HookCommand::VerifyWrite, &error);
        assert!(detail.contains("Details: exit code 1"));
    }

    #[test]
    fn hook_command_classification_is_exhaustive() {
        let all = [
            HookCommand::GuardBash,
            HookCommand::GuardWrite,
            HookCommand::GuardQuestion,
            HookCommand::GuardStop,
            HookCommand::VerifyBash,
            HookCommand::VerifyWrite,
            HookCommand::VerifyQuestion,
            HookCommand::Audit,
            HookCommand::EnrichFailure,
            HookCommand::ContextAgent,
            HookCommand::ValidateAgent,
        ];
        for hook in &all {
            let count = [
                hook.is_pre_tool_use(),
                hook.is_post_tool_use(),
                hook.is_post_tool_use_failure(),
                hook.is_subagent_start(),
                hook.is_subagent_stop(),
                hook.is_blocking(),
            ]
            .iter()
            .filter(|&&v| v)
            .count();
            assert_eq!(
                count,
                1,
                "{} falls into {} categories, expected 1",
                hook.name(),
                count
            );
        }
    }

    // --- HookCommand name tests ---

    #[test]
    fn hook_command_names_match_cli() {
        let all = [
            HookCommand::GuardBash,
            HookCommand::GuardWrite,
            HookCommand::GuardQuestion,
            HookCommand::GuardStop,
            HookCommand::VerifyBash,
            HookCommand::VerifyWrite,
            HookCommand::VerifyQuestion,
            HookCommand::Audit,
            HookCommand::EnrichFailure,
            HookCommand::ContextAgent,
            HookCommand::ValidateAgent,
        ];
        assert_eq!(all.len(), 11);
        for hook in &all {
            assert!(!hook.name().is_empty(), "hook name must not be empty");
            assert!(
                hook.name()
                    .chars()
                    .all(|c| c.is_ascii_lowercase() || c == '-'),
                "hook name must be kebab-case: {}",
                hook.name()
            );
        }
    }
}
