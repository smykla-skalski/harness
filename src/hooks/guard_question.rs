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
                return HookMessage::RunnerFlowRequired {
                    action: "ask the suite-fix gate".into(),
                    details: reason
                        .unwrap_or("enter failure triage before asking how to repair the suite")
                        .into(),
                }
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
        return HookMessage::ValidatorGateUnexpected {
            details:
                "The local validator is already installed or a prior decision is already saved. \
                      Do not ask the install gate again."
                    .into(),
        }
        .into_result();
    }
    // Block non-install prompts if install gate is pending.
    if kubectl_validate_prompt_required() {
        return HookMessage::ValidatorGateRequired {
            details: "Complete the local validator install decision first.".into(),
        }
        .into_result();
    }
    // Check canonical review gate prompts.
    if let Some(gate) = classify_canonical_gate(prompts) {
        let Some(state) = &ctx.author_state else {
            return HookMessage::ApprovalStateInvalid {
                details: "author state is missing".into(),
            }
            .into_result();
        };
        if state.mode == ApprovalMode::Bypass {
            return HookMessage::ApprovalStateInvalid {
                details: "bypass mode forbids canonical review prompts".into(),
            }
            .into_result();
        }
        if let Err(reason) = can_request_gate(state, gate) {
            return HookMessage::ApprovalStateInvalid {
                details: reason.into(),
            }
            .into_result();
        }
        return HookResult::allow();
    }
    HookResult::allow()
}

fn is_manifest_fix_prompt(prompt: &AskUserQuestionPrompt) -> bool {
    let head = prompt.question_head();
    if head != runner_rules::MANIFEST_FIX_GATE_QUESTION {
        return false;
    }
    let labels = prompt.option_labels();
    labels.len() == runner_rules::MANIFEST_FIX_GATE_OPTIONS.len()
        && labels
            .iter()
            .zip(runner_rules::MANIFEST_FIX_GATE_OPTIONS.iter())
            .all(|(a, b)| a == b)
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
        if head == author_rules::PREWRITE_GATE_QUESTION {
            return Some(ReviewGate::Prewrite);
        }
        if head == author_rules::POSTWRITE_GATE_QUESTION {
            return Some(ReviewGate::Postwrite);
        }
        if head == author_rules::COPY_GATE_QUESTION {
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
