use clap::{Args, Subcommand};

use crate::kernel::skills::SKILL_NAMES;

use super::adapters::HookAgent;
use super::catalog::{
    CONTEXT_AGENT_HOOK, GUARD_STOP_HOOK, TOOL_FAILURE_HOOK, TOOL_GUARD_HOOK, TOOL_RESULT_HOOK,
    VALIDATE_AGENT_HOOK,
};
use super::registry::Hook;

/// Hook lifecycle categories.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HookType {
    PreToolUse,
    PostToolUse,
    PostToolUseFailure,
    SubagentStart,
    SubagentStop,
    Blocking,
}

impl HookType {
    #[must_use]
    pub const fn is_guard(self) -> bool {
        matches!(self, Self::PreToolUse | Self::Blocking)
    }
}

/// Available hooks.
#[derive(Debug, Clone, Subcommand)]
#[non_exhaustive]
pub enum HookCommand {
    /// Guard tool usage before execution.
    ToolGuard,
    /// Guard stop and session end.
    GuardStop,
    /// Process tool results after execution.
    ToolResult,
    /// Audit a Codex turn-complete notification.
    AuditTurn(AuditTurnArgs),
    /// Process tool failures after execution errors.
    ToolFailure,
    /// Validate subagent startup context.
    ContextAgent,
    /// Validate subagent results.
    ValidateAgent,
}

/// Arguments for the Codex notify-based audit shim.
#[derive(Debug, Clone, Default, Args)]
pub struct AuditTurnArgs {
    /// Raw Codex notify payload passed as `argv[1]`.
    #[arg(hide = true)]
    pub payload: Option<String>,
}

impl HookCommand {
    #[must_use]
    pub fn hook(&self) -> &'static dyn Hook {
        match self {
            Self::ToolGuard => TOOL_GUARD_HOOK,
            Self::GuardStop => GUARD_STOP_HOOK,
            Self::ToolResult | Self::AuditTurn(_) => TOOL_RESULT_HOOK,
            Self::ToolFailure => TOOL_FAILURE_HOOK,
            Self::ContextAgent => CONTEXT_AGENT_HOOK,
            Self::ValidateAgent => VALIDATE_AGENT_HOOK,
        }
    }

    #[must_use]
    pub fn name(&self) -> &'static str {
        match self {
            Self::AuditTurn(_) => "audit-turn",
            _ => self.hook().name(),
        }
    }

    #[must_use]
    pub fn hook_type(&self) -> HookType {
        self.hook().hook_type()
    }

    #[must_use]
    pub(crate) fn inline_payload(&self) -> Option<&str> {
        match self {
            Self::AuditTurn(args) => args.payload.as_deref(),
            _ => None,
        }
    }
}

/// Arguments for `harness hook`.
#[derive(Debug, Clone, Args)]
pub struct HookArgs {
    /// Hook transport/agent protocol.
    #[arg(long, value_enum, default_value_t = HookAgent::Claude)]
    pub agent: HookAgent,
    /// Skill name (suite:run or suite:create).
    #[arg(value_parser = clap::builder::PossibleValuesParser::new(SKILL_NAMES))]
    pub skill: String,
    /// Hook to run.
    #[command(subcommand)]
    pub hook: HookCommand,
}
