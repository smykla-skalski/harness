use crate::errors::{self, CliError};
use crate::hook::HookResult;
use crate::hook_payloads::HookContext;

/// Execute the context-agent hook.
///
/// For suite-author, emits a format warning reminding workers to save
/// structured results through `harness authoring-save`.
/// For suite-runner, validates that the preflight worker can start.
/// Full runner validation needs workflow state; this version allows
/// when the infrastructure is not yet available.
///
/// # Errors
/// Returns `CliError` on failure.
pub fn execute(ctx: &HookContext) -> Result<HookResult, CliError> {
    if !ctx.skill_active {
        return Ok(HookResult::allow());
    }
    if ctx.skill == "suite-author" {
        return Ok(errors::hook_msg(&errors::WARN_CODE_READER_FORMAT, &[]));
    }
    // suite-runner: full implementation checks can_start_preflight_worker
    // against runner workflow state. Without RunContext, allow.
    Ok(HookResult::allow())
}
