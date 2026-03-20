use clap::{Args, Subcommand};

use crate::kernel::skills::SKILL_NAMES;

use super::adapters::HookAgent;
use super::catalog::{
    AUDIT_HOOK, CONTEXT_AGENT_HOOK, ENRICH_FAILURE_HOOK, GUARD_BASH_HOOK, GUARD_QUESTION_HOOK,
    GUARD_STOP_HOOK, GUARD_WRITE_HOOK, VALIDATE_AGENT_HOOK, VERIFY_BASH_HOOK, VERIFY_QUESTION_HOOK,
    VERIFY_WRITE_HOOK,
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
    /// Audit a Codex turn-complete notification.
    AuditTurn(AuditTurnArgs),
    /// Enrich failure context.
    EnrichFailure,
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
            Self::GuardBash => GUARD_BASH_HOOK,
            Self::GuardWrite => GUARD_WRITE_HOOK,
            Self::GuardQuestion => GUARD_QUESTION_HOOK,
            Self::GuardStop => GUARD_STOP_HOOK,
            Self::VerifyBash => VERIFY_BASH_HOOK,
            Self::VerifyWrite => VERIFY_WRITE_HOOK,
            Self::VerifyQuestion => VERIFY_QUESTION_HOOK,
            Self::Audit | Self::AuditTurn(_) => AUDIT_HOOK,
            Self::EnrichFailure => ENRICH_FAILURE_HOOK,
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
    #[arg(long, value_enum, default_value_t = HookAgent::ClaudeCode)]
    pub agent: HookAgent,
    /// Skill name (suite:run or suite:new).
    #[arg(value_parser = clap::builder::PossibleValuesParser::new(SKILL_NAMES))]
    pub skill: String,
    /// Hook to run.
    #[command(subcommand)]
    pub hook: HookCommand,
}
