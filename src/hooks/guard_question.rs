use crate::errors::{CliError, HookMessage};
use crate::hook::HookResult;
use crate::hook_payloads::{AskUserQuestionPrompt, HookContext};
use crate::kubectl_validate::kubectl_validate_prompt_required;
use crate::rules::suite_runner as runner_rules;
use crate::workflow::author::{ApprovalMode, ReviewGate, can_request_gate};
use crate::workflow::runner::{RunnerPhase, RunnerWorkflowState};

/// Execute the guard-question hook.
///
/// # Errors
/// Returns `CliError` on failure.
pub fn execute(ctx: &HookContext) -> Result<HookResult, CliError> {
    if !ctx.skill_active {
        return Ok(HookResult::allow());
    }
    let prompts = ctx.question_prompts();
    if prompts.is_empty() {
        return Ok(HookResult::allow());
    }
    if ctx.is_suite_runner() {
        return Ok(guard_suite_runner(ctx, prompts));
    }
    Ok(guard_suite_author(ctx, prompts))
}

fn guard_suite_runner(ctx: &HookContext, prompts: &[AskUserQuestionPrompt]) -> HookResult {
    for prompt in prompts {
        if !is_manifest_fix_prompt(prompt) {
            continue;
        }
        if let Some(ref state) = ctx.runner_state {
            let (allowed, reason) = can_ask_manifest_fix(state);
            if !allowed {
                return HookMessage::runner_flow_required(
                    "ask the suite-fix gate",
                    reason.unwrap_or("enter failure triage before asking how to repair the suite"),
                )
                .into_result();
            }
        }
        return HookResult::allow();
    }
    HookResult::allow()
}

fn guard_suite_author(ctx: &HookContext, prompts: &[AskUserQuestionPrompt]) -> HookResult {
    // Check kubectl-validate install gate.
    if is_install_prompt(prompts) {
        if kubectl_validate_prompt_required() {
            return HookResult::allow();
        }
        return HookMessage::validator_gate_unexpected(
            "The local validator is already installed or a prior decision is already saved. \
                      Do not ask the install gate again.",
        )
        .into_result();
    }
    // Block non-install prompts if install gate is pending.
    if kubectl_validate_prompt_required() {
        return HookMessage::validator_gate_required(
            "Complete the local validator install decision first.",
        )
        .into_result();
    }
    // Check canonical review gate prompts.
    if let Some(gate) = classify_canonical_gate(prompts) {
        let Some(state) = &ctx.author_state else {
            return HookMessage::approval_state_invalid("author state is missing").into_result();
        };
        if state.mode == ApprovalMode::Bypass {
            return HookMessage::approval_state_invalid(
                "bypass mode forbids canonical review prompts",
            )
            .into_result();
        }
        if let Err(reason) = can_request_gate(state, gate) {
            return HookMessage::approval_state_invalid(reason).into_result();
        }
        return HookResult::allow();
    }
    HookResult::allow()
}

fn is_manifest_fix_prompt(prompt: &AskUserQuestionPrompt) -> bool {
    runner_rules::MANIFEST_FIX_GATE.matches(prompt.question_head(), &prompt.option_labels())
}

fn is_install_prompt(prompts: &[AskUserQuestionPrompt]) -> bool {
    prompts
        .iter()
        .any(|p| p.question_head().contains("kubectl-validate"))
}

fn classify_canonical_gate(prompts: &[AskUserQuestionPrompt]) -> Option<ReviewGate> {
    use crate::rules::suite_author as author_rules;
    for prompt in prompts {
        let head = prompt.question_head();
        if head == author_rules::PREWRITE_GATE.question {
            return Some(ReviewGate::Prewrite);
        }
        if head == author_rules::POSTWRITE_GATE.question {
            return Some(ReviewGate::Postwrite);
        }
        if head == author_rules::COPY_GATE.question {
            return Some(ReviewGate::Copy);
        }
    }
    None
}

fn can_ask_manifest_fix(state: &RunnerWorkflowState) -> (bool, Option<&'static str>) {
    if state.phase != RunnerPhase::Triage {
        return (
            false,
            Some("enter failure triage before asking how to repair the suite"),
        );
    }
    if state.failure.is_none() {
        return (false, Some("no failure recorded for triage"));
    }
    (true, None)
}
