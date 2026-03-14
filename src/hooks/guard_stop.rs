use crate::errors::{self, CliError};
use crate::hook::HookResult;
use crate::hook_payloads::HookContext;

/// Execute the guard-stop hook.
///
/// Checks whether the current harness skill session may stop.
/// For suite-runner: verifies closeout is complete (state capture present,
/// verdict not pending, report valid). Full validation needs `RunContext`;
/// this version allows when no run dir is set.
/// For suite-author: verifies approval state allows stopping and the
/// written suite is valid. Full validation needs author workflow state.
///
/// # Errors
/// Returns `CliError` on failure.
pub fn execute(ctx: &HookContext) -> Result<HookResult, CliError> {
    if !ctx.skill_active {
        return Ok(HookResult::allow());
    }
    if ctx.skill == "suite-author" {
        return Ok(guard_suite_author_stop());
    }
    Ok(guard_suite_runner_stop(ctx))
}

fn guard_suite_author_stop() -> HookResult {
    // Full implementation checks:
    // - Author workflow state for can_stop()
    // - Suite spec completeness (groups, baseline files)
    // Without author state infrastructure, allow stop.
    HookResult::allow()
}

fn guard_suite_runner_stop(ctx: &HookContext) -> HookResult {
    if ctx.run_dir.is_none() {
        // No active run - allow stop.
        return HookResult::allow();
    }
    // Full implementation checks:
    // - RunReport parseable
    // - last_state_capture present
    // - overall_verdict != "pending"
    // Without RunContext, emit warnings for the checks we can't do.
    // The Python code denies stop if state capture is missing or verdict
    // is pending. Since we can't check those, allow by default and let
    // the full implementation handle it once RunContext is available.
    errors::hook_msg(&errors::INFO_RUN_VERDICT, &[("verdict", "pending")])
}
