use crate::errors::CliError;
use crate::hooks::application::GuardContext as HookContext;

use super::effects::HookOutcome;
use super::tool_dispatch::{ToolDispatch, classify_tool_interaction};

/// Execute the unified post-tool hook.
///
/// # Errors
/// Returns `CliError` on failure.
pub fn execute(ctx: &HookContext) -> Result<HookOutcome, CliError> {
    let outcome = match classify_tool_interaction(ctx) {
        ToolDispatch::Question => {
            HookOutcome::from_hook_result(super::verify_question::execute(ctx)?)
        }
        ToolDispatch::Write => super::verify_write::execute(ctx)?,
        ToolDispatch::Command => HookOutcome::from_hook_result(super::verify_bash::execute(ctx)?),
        ToolDispatch::Other => HookOutcome::allow(),
    };
    let audit = super::audit::execute(ctx)?;

    Ok(outcome.append_non_decision_effects(audit.effects()))
}
