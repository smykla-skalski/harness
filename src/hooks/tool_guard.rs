use crate::errors::CliError;
use crate::hooks::application::GuardContext as HookContext;

use super::effects::HookOutcome;
use super::tool_dispatch::{ToolDispatch, classify_tool_interaction};

/// Execute the unified pre-tool hook.
///
/// # Errors
/// Returns `CliError` on failure.
pub fn execute(ctx: &HookContext) -> Result<HookOutcome, CliError> {
    let result = match classify_tool_interaction(ctx) {
        ToolDispatch::Question => super::guard_question::execute(ctx)?,
        ToolDispatch::Write => super::guard_write::execute(ctx)?,
        ToolDispatch::Command => super::guard_bash::execute(ctx)?,
        ToolDispatch::Other => return Ok(HookOutcome::allow()),
    };

    Ok(HookOutcome::from_hook_result(result))
}
