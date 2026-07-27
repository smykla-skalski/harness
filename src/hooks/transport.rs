use clap::{Args, Subcommand};

use super::catalog::{TOOL_GUARD_HOOK, TOOL_RESULT_HOOK};
use super::registry::Hook;

/// Hook lifecycle categories.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HookType {
    PreToolUse,
    PostToolUse,
}

impl HookType {
    #[must_use]
    pub const fn is_guard(self) -> bool {
        matches!(self, Self::PreToolUse)
    }
}

/// Available hooks.
#[derive(Debug, Clone, Subcommand)]
#[non_exhaustive]
pub enum HookCommand {
    /// Guard tool usage before execution.
    ToolGuard,
    /// Process tool results after execution.
    ToolResult,
    /// Process a Codex turn-complete notification.
    AuditTurn(AuditTurnArgs),
}

/// Arguments for the Codex notify shim.
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
            Self::ToolResult | Self::AuditTurn(_) => TOOL_RESULT_HOOK,
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
