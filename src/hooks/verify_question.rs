use crate::errors::{CliError, HookMessage};
use crate::hook::HookResult;
use crate::hook_payloads::HookContext;
use crate::rules::suite_runner as runner_rules;
use crate::workflow::runner::RunnerPhase;

/// Execute the verify-question hook.
///
/// Processes `AskUserQuestion` answers and validates them against workflow
/// state. For suite-runner, validates manifest-fix decisions. For
/// suite-author, validates kubectl-validate install and canonical gate
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
    let is_manifest_fix = answers.iter().any(|a| {
        a.question
            .contains(runner_rules::MANIFEST_FIX_GATE_QUESTION)
    });
    if !is_manifest_fix {
        return HookResult::allow();
    }
    if let Some(ref state) = ctx.runner_state
        && state.phase != RunnerPhase::Triage
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
        .any(|a| a.question.contains("kubectl-validate"));
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
