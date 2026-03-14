use crate::errors::CliError;
use crate::hook::HookResult;
use crate::hook_payloads::HookContext;

/// Execute the audit hook.
///
/// Logs suite-author hook debug info without affecting the main hook decision.
/// For suite-runner or inactive contexts, allow unconditionally.
///
/// # Errors
/// Returns `CliError` on failure.
pub fn execute(ctx: &HookContext) -> Result<HookResult, CliError> {
    if !ctx.skill_active {
        return Ok(HookResult::allow());
    }
    if ctx.skill == "suite-author" {
        // In the full implementation this would append debug info to the
        // authoring debug log. For now, just allow.
        return Ok(HookResult::allow());
    }
    Ok(HookResult::allow())
}
