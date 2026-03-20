use crate::errors::{CliError, HookMessage};
use crate::hooks::application::GuardContext as HookContext;
use crate::hooks::protocol::hook_result::HookResult;
use crate::hooks::runner_policy as runner_rules;
use crate::run::workflow::RunnerPhase;

/// Execute the verify-question hook.
///
/// Processes `AskUserQuestion` answers and validates them against workflow
/// state. For suite:run, validates manifest-fix decisions. For
/// suite:new, validates kubectl-validate install and canonical gate
/// answers.
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
        return Ok(handle_suite_runner(ctx));
    }
    Ok(handle_suite_author(ctx))
}

fn handle_suite_runner(ctx: &HookContext) -> HookResult {
    let answers = ctx.question_answers();
    let is_manifest_fix = answers
        .iter()
        .any(|a| runner_rules::matches_manifest_fix_question(&a.question));
    if !is_manifest_fix {
        return HookResult::allow();
    }
    if let Some(ref state) = ctx.runner_state
        && state.phase() != RunnerPhase::Triage
    {
        return HookMessage::runner_flow_required(
            "apply the suite-fix answer",
            "manifest-fix answers are only valid during failure triage",
        )
        .into_result();
    }
    HookResult::allow()
}

fn handle_suite_author(ctx: &HookContext) -> HookResult {
    let answers = ctx.question_answers();
    let is_install = answers
        .iter()
        .any(|a| runner_rules::matches_kubectl_validate_question(&a.question));
    if is_install {
        return HookResult::allow();
    }
    if ctx.author_state.is_none() {
        return HookMessage::approval_state_invalid(
            "author state is missing; cannot apply gate answer",
        )
        .into_result();
    }
    HookResult::allow()
}

#[cfg(test)]
mod tests;
