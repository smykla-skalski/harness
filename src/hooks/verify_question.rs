use crate::hooks::application::GuardContext as HookContext;
use crate::hooks::protocol::hook_result::HookResult;
use crate::hooks::runner_policy as runner_rules;
use harness_kernel::errors::{CliError, HookMessage};

/// Execute the verify-question hook.
///
/// Processes `AskUserQuestion` answers and validates them against workflow
/// state. For suite:create, validates kubectl-validate install and canonical
/// gate answers.
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
    if ctx.is_suite_runner() {
        return Ok(HookResult::allow());
    }
    Ok(handle_suite_author(ctx))
}

fn handle_suite_author(ctx: &HookContext) -> HookResult {
    let answers = ctx.question_answers();
    let is_install = answers
        .iter()
        .any(|a| runner_rules::matches_kubectl_validate_question(&a.question));
    if is_install {
        return HookResult::allow();
    }
    if ctx.create_state.is_none() {
        return HookMessage::approval_state_invalid(
            "create state is missing; cannot apply gate answer",
        )
        .into_result();
    }
    HookResult::allow()
}

#[cfg(test)]
mod tests;
