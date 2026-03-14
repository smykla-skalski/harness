use crate::errors::{self, CliError};
use crate::hook::HookResult;
use crate::hook_payloads::HookContext;
use crate::workflow::author::can_stop;

/// Execute the guard-stop hook.
///
/// # Errors
/// Returns `CliError` on failure.
pub fn execute(ctx: &HookContext) -> Result<HookResult, CliError> {
    if !ctx.skill_active {
        return Ok(HookResult::allow());
    }
    if ctx.skill == "suite-author" {
        return Ok(guard_suite_author_stop(ctx));
    }
    Ok(guard_suite_runner_stop(ctx))
}

fn guard_suite_author_stop(ctx: &HookContext) -> HookResult {
    let Some(state) = &ctx.author_state else {
        return HookResult::allow();
    };
    let (allowed, reason) = can_stop(state);
    if !allowed {
        return errors::hook_msg(
            &errors::DENY_APPROVAL_REQUIRED,
            &[
                ("action", "stop suite-author"),
                (
                    "details",
                    reason.unwrap_or("suite-author is not ready to stop yet"),
                ),
            ],
        );
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
        return errors::hook_msg(&errors::DENY_MISSING_STATE_CAPTURE, &[]);
    }
    if status.overall_verdict == "pending" {
        return errors::hook_msg(&errors::DENY_VERDICT_PENDING, &[]);
    }
    HookResult::allow()
}
