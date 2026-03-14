use clap::{Parser, Subcommand};

/// Kuma test harness CLI.
#[derive(Debug, Parser)]
#[command(name = "harness", version, about = "Kuma test harness")]
pub struct Cli {
    #[command(subcommand)]
    pub command: Command,
}

/// Top-level commands.
#[derive(Debug, Subcommand)]
pub enum Command {
    /// Run a hook for a skill.
    Hook {
        /// Skill name (suite-runner or suite-author).
        skill: String,
        /// Hook name.
        hook_name: String,
    },
    /// Initialize a new test run.
    Init,
    /// Bootstrap the harness wrapper.
    Bootstrap,
    /// Manage cluster lifecycle.
    Cluster,
    /// Run preflight checks.
    Preflight,
    /// Capture state artifacts.
    Capture,
    /// Record a command result.
    Record,
    /// Apply manifests.
    Apply,
    /// Validate manifests.
    Validate,
    /// Run a tracked command.
    Run,
    /// Manage runner state.
    RunnerState,
    /// Close out a run.
    Closeout,
    /// Generate a report.
    Report,
    /// View diffs.
    Diff,
    /// Manage envoy admin.
    Envoy,
    /// Gateway operations.
    Gateway,
    /// Kumactl wrapper.
    Kumactl,
    /// Session start hook.
    SessionStart,
    /// Session stop hook.
    SessionStop,
    /// Pre-compact hook.
    PreCompact,
    /// Begin authoring.
    AuthoringBegin,
    /// Save authoring result.
    AuthoringSave,
    /// Show authoring state.
    AuthoringShow,
    /// Reset authoring.
    AuthoringReset,
    /// Validate authoring.
    AuthoringValidate,
    /// Begin approval flow.
    ApprovalBegin,
}

/// Parse CLI arguments and run the appropriate command.
///
/// # Errors
/// Returns `CliError` on failure.
pub fn run() -> Result<i32, crate::errors::CliError> {
    todo!()
}

#[cfg(test)]
mod tests {}
