use crate::errors::{self, CliError};
use crate::hook::HookResult;
use crate::hook_payloads::HookContext;

/// Execute the enrich-failure hook.
///
/// For suite-runner, emits run verdict info after a tool failure.
/// Full implementation would record failure artifacts and trigger triage
/// transitions; this version emits the verdict info when a run dir is
/// available, and allows otherwise.
///
/// # Errors
/// Returns `CliError` on failure.
pub fn execute(ctx: &HookContext) -> Result<HookResult, CliError> {
    if ctx.skill != "suite-runner" {
        return Ok(HookResult::allow());
    }
    if !ctx.skill_active {
        return Ok(HookResult::allow());
    }
    // Full implementation needs RunContext to read run status and runner
    // workflow state. Without that infrastructure, emit a generic info
    // message noting the failure hook fired.
    Ok(errors::hook_msg(
        &errors::INFO_RUN_VERDICT,
        &[("verdict", "pending")],
    ))
}
