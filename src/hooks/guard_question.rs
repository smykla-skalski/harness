use crate::errors::{self, CliError};
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
                return errors::hook_msg(
                    &errors::DENY_RUNNER_FLOW_REQUIRED,
                    &[
                        ("action", "ask the suite-fix gate"),
                        (
                            "details",
                            reason.unwrap_or(
                                "enter failure triage before asking how to repair the suite",
                            ),
                        ),
                    ],
                );
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
        return errors::hook_msg(
            &errors::DENY_VALIDATOR_GATE_UNEXPECTED,
            &[(
                "details",
                "The local validator is already installed or a prior decision is already saved. \
                 Do not ask the install gate again.",
            )],
        );
    }
    // Block non-install prompts if install gate is pending.
    if kubectl_validate_prompt_required() {
        return errors::hook_msg(
            &errors::DENY_VALIDATOR_GATE_REQUIRED,
            &[(
                "details",
                "Complete the local validator install decision first.",
            )],
        );
    }
    // Check canonical review gate prompts.
    if let Some(gate) = classify_canonical_gate(prompts) {
        let Some(state) = &ctx.author_state else {
            return errors::hook_msg(
                &errors::DENY_APPROVAL_STATE_INVALID,
                &[("details", "author state is missing")],
            );
        };
        if state.mode == ApprovalMode::Bypass {
            return errors::hook_msg(
                &errors::DENY_APPROVAL_STATE_INVALID,
                &[("details", "bypass mode forbids canonical review prompts")],
            );
        }
        let (allowed, reason) = can_request_gate(state, gate);
        if !allowed {
            return errors::hook_msg(
                &errors::DENY_APPROVAL_STATE_INVALID,
                &[(
                    "details",
                    reason.unwrap_or("suite-author is not ready for that review gate"),
                )],
            );
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
    if matches!(&state.phase, RunnerPhase::Triage { .. }) {
        (true, None)
    } else {
        (
            false,
            Some("enter failure triage before asking how to repair the suite"),
        )
    }
}
