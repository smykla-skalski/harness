use crate::errors::CliError;
use crate::hook::HookResult;
use crate::hook_payloads::HookContext;

/// Execute the verify-question hook.
///
/// Processes `AskUserQuestion` answers and applies them to workflow state.
/// For suite-runner: applies manifest-fix decisions. Needs runner workflow
/// state and `RunContext`.
/// For suite-author: applies kubectl-validate install answers and
/// canonical review gate answers. Needs author workflow state.
/// Without workflow state infrastructure, allow.
///
/// # Errors
/// Returns `CliError` on failure.
pub fn execute(ctx: &HookContext) -> Result<HookResult, CliError> {
    if !ctx.skill_active {
        return Ok(HookResult::allow());
    }
    let answers = ctx.question_answers();
    if answers.is_empty() {
        return Ok(HookResult::allow());
    }
    // Full implementation applies answers to runner or author workflow
    // state. This requires:
    // - For suite-runner: RunContext, runner state, manifest-fix decision
    //   application
    // - For suite-author: author state, kubectl-validate install, gate
    //   answer application
    // Without that infrastructure, allow.
    Ok(HookResult::allow())
}
