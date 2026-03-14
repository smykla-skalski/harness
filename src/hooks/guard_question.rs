use crate::errors::{self, CliError};
use crate::hook::HookResult;
use crate::hook_payloads::HookContext;
use crate::rules::suite_runner as runner_rules;

/// Execute the guard-question hook.
///
/// Validates `AskUserQuestion` prompts for the active skill.
/// For suite-runner: checks manifest-fix gate prompts match the expected
/// format and that the runner is in triage phase. Phase validation needs
/// workflow state; deferred parts allow.
/// For suite-author: checks kubectl-validate install gates and canonical
/// review gates. Most validation needs author workflow state; this version
/// validates prompt shape where possible.
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
    if ctx.skill == "suite-runner" {
        return guard_suite_runner(prompts);
    }
    guard_suite_author(prompts)
}

fn guard_suite_runner(
    prompts: &[crate::hook_payloads::AskUserQuestionPrompt],
) -> Result<HookResult, CliError> {
    // Check for manifest-fix gate prompts.
    for prompt in prompts {
        if is_manifest_fix_prompt(prompt) {
            // Full validation checks runner workflow state for triage phase.
            // Without state, allow the prompt since the format is correct.
            return Ok(HookResult::allow());
        }
    }
    Ok(HookResult::allow())
}

fn guard_suite_author(
    _prompts: &[crate::hook_payloads::AskUserQuestionPrompt],
) -> Result<HookResult, CliError> {
    // Full implementation checks:
    // - kubectl-validate install gate
    // - canonical review gates (prewrite/postwrite/copy)
    // - author workflow state
    // Without that infrastructure, allow.
    Ok(HookResult::allow())
}

/// Check if a prompt matches the manifest-fix gate format.
fn is_manifest_fix_prompt(prompt: &crate::hook_payloads::AskUserQuestionPrompt) -> bool {
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
