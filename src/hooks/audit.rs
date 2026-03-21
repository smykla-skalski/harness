use crate::errors::CliError;
use crate::hooks::application::GuardContext as HookContext;
use crate::run::audit::build_hook_audit_request;

use super::effects::{HookEffect, HookOutcome};

/// Execute the audit hook.
///
/// Logs suite:new hook debug info without affecting the main hook decision.
/// For suite:run or inactive contexts, allow unconditionally.
///
/// # Errors
/// Returns `CliError` on failure.
pub fn execute(ctx: &HookContext) -> Result<HookOutcome, CliError> {
    super::dispatch_outcome_by_skill(
        ctx,
        |ctx| {
            if ctx.effective_run_dir().is_none() {
                return Ok(HookOutcome::allow());
            }
            let request = build_hook_audit_request(ctx)?;
            Ok(HookOutcome::allow().with_effect(HookEffect::AppendAudit(request)))
        },
        |_ctx| Ok(HookOutcome::allow()),
    )
}

#[cfg(test)]
#[path = "audit/tests.rs"]
mod tests;
