use crate::errors::{CliError, HookMessage};
use crate::hook::HookResult;
use crate::hook_payloads::HookContext;
use crate::rules::suite_runner as runner_rules;
use crate::workflow::runner::RunnerPhase;

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
    let is_manifest_fix = answers.iter().any(|a| {
        a.question
            .contains(runner_rules::MANIFEST_FIX_GATE.question)
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

#[cfg(test)]
mod tests {
    use super::*;
    use crate::hook::Decision;
    use crate::hook_payloads::{HookContext, HookEnvelopePayload, HookEvent};

    fn inactive_context() -> HookContext {
        HookContext {
            skill: String::new(),
            event: HookEvent {
                payload: HookEnvelopePayload::default(),
            },
            run_dir: None,
            skill_active: false,
            active_skill: None,
            inactive_reason: None,
            run: None,
            runner_state: None,
            author_state: None,
        }
    }

    #[test]
    fn inactive_skill_allows() {
        let ctx = inactive_context();
        let result = execute(&ctx).unwrap();
        assert_eq!(result.decision, Decision::Allow);
    }
}
