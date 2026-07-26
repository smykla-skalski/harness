use crate::hooks::application::GuardContext as HookContext;
use harness_kernel::errors::CliError;

use super::effects::{HookEffect, HookOutcome};

mod append;
mod summarize;
mod types;

pub use append::{append_audit_entry, build_hook_audit_request};
pub use summarize::{normalize_tool_output, summarize_tool_input};
pub use types::{AuditAppendRequest, AuditEntry};

/// Execute the audit hook.
///
/// Logs suite:create hook debug info without affecting the main hook decision.
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

#[cfg(all(test, not(feature = "standalone-worker")))]
#[path = "audit/tests.rs"]
mod tests;
