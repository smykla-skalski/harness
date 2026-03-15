use crate::errors::{CliError, HookMessage};
use crate::hook::HookResult;
use crate::hook_payloads::HookContext;
use crate::schema::Verdict;
use crate::workflow::author::can_stop;

/// Execute the guard-stop hook.
///
/// # Errors
/// Returns `CliError` on failure.
pub fn execute(ctx: &HookContext) -> Result<HookResult, CliError> {
    if !ctx.skill_active {
        return Ok(HookResult::allow());
    }
    if ctx.is_suite_author() {
        return Ok(guard_suite_author_stop(ctx));
    }
    Ok(guard_suite_runner_stop(ctx))
}

fn guard_suite_author_stop(ctx: &HookContext) -> HookResult {
    let Some(state) = &ctx.author_state else {
        return HookResult::allow();
    };
    if let Err(reason) = can_stop(state) {
        return HookMessage::approval_required("stop suite:new", reason).into_result();
    }
    HookResult::allow()
}

fn guard_suite_runner_stop(ctx: &HookContext) -> HookResult {
    let Some(run) = &ctx.run else {
        return HookResult::allow();
    };
    let Some(status) = &run.status else {
        return HookResult::allow();
    };
    if status.last_state_capture.is_none() {
        return HookMessage::MissingStateCapture.into_result();
    }
    if status.overall_verdict == Verdict::Pending {
        return HookMessage::VerdictPending.into_result();
    }
    HookResult::allow()
}
