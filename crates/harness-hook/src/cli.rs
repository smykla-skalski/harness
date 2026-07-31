//! The `harness-hook` command-line surface, shared with the docs generator.

use clap::{Args, Parser, Subcommand};
use harness_kernel::kernel::skills::SKILL_NAMES;

use crate::hooks::HookAgent;
use crate::setup::PreCompactArgs;

#[derive(Debug, Parser)]
#[command(name = "harness-hook", version, about = "Harness lifecycle hooks")]
pub struct Cli {
    /// Seconds to wait before executing the command.
    #[arg(long, default_value = "0", global = true)]
    pub delay: f64,
    #[command(subcommand)]
    pub command: Command,
}

#[derive(Debug, Subcommand)]
pub enum Command {
    ToolGuard(HookInvocationArgs),
    ToolResult(HookInvocationArgs),
    AuditTurn(AuditTurnInvocationArgs),
    SessionStart(AgentSessionArgs),
    SessionStop(AgentSessionArgs),
    PromptSubmit(AgentSessionArgs),
    PreCompact(PreCompactArgs),
}

#[derive(Debug, Args)]
pub struct HookInvocationArgs {
    /// Hook transport/agent protocol.
    #[arg(long, value_enum)]
    pub agent: HookAgent,
    /// Harness skill owning the hook.
    #[arg(long, value_parser = clap::builder::PossibleValuesParser::new(SKILL_NAMES))]
    pub skill: String,
}

#[derive(Debug, Args)]
pub struct AuditTurnInvocationArgs {
    #[command(flatten)]
    pub hook: HookInvocationArgs,
    /// Raw Codex notify payload passed as `argv[1]`.
    #[arg(hide = true)]
    pub payload: Option<String>,
}

#[derive(Debug, Clone, Args)]
pub struct AgentSessionArgs {
    /// Hook transport/agent protocol.
    #[arg(long, value_enum)]
    pub agent: HookAgent,
    /// Project directory associated with the runtime session.
    #[arg(long, env = "CLAUDE_PROJECT_DIR")]
    pub project_dir: Option<String>,
    /// Native runtime session identifier.
    #[arg(long)]
    pub session_id: Option<String>,
}
