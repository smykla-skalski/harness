use crate::create::{ApprovalMode, can_request_gate};
use crate::hooks::application::GuardContext as HookContext;
use crate::hooks::protocol::hook_result::HookResult;
use crate::hooks::protocol::payloads::AskUserQuestionPrompt;
use crate::hooks::runner_policy as runner_rules;
use crate::platform::kubectl_validate::kubectl_validate_prompt_required;
use harness_kernel::errors::{CliError, HookMessage};

/// Execute the guard-question hook.
///
/// # Errors
/// Returns `CliError` on failure.
pub fn execute(ctx: &HookContext) -> Result<HookResult, CliError> {
    let prompts = ctx.question_prompts();
    if prompts.is_empty() {
        return Ok(HookResult::allow());
    }
    super::dispatch_by_skill(
        ctx,
        |_ctx| Ok(HookResult::allow()),
        |ctx| guard_suite_create(ctx, &prompts),
    )
}

fn guard_suite_create(
    ctx: &HookContext,
    prompts: &[AskUserQuestionPrompt],
) -> Result<HookResult, CliError> {
    // Check kubectl-validate install gate.
    if runner_rules::is_install_prompt(prompts) {
        if kubectl_validate_prompt_required()? {
            return Ok(HookResult::allow());
        }
        return Ok(HookMessage::validator_gate_unexpected(
            "The local validator is already installed or a prior decision is already saved. \
                      Do not ask the install gate again.",
        )
        .into_result());
    }
    // Block non-install prompts if install gate is pending.
    if kubectl_validate_prompt_required()? {
        return Ok(HookMessage::validator_gate_required(
            "Complete the local validator install decision first.",
        )
        .into_result());
    }
    // Check canonical review gate prompts.
    if let Some(gate) = runner_rules::classify_canonical_gate(prompts) {
        let Some(state) = &ctx.create_state else {
            return Ok(
                HookMessage::approval_state_invalid("create state is missing").into_result(),
            );
        };
        if state.mode() == ApprovalMode::Bypass {
            return Ok(HookMessage::approval_state_invalid(
                "bypass mode forbids canonical review prompts",
            )
            .into_result());
        }
        if let Err(reason) = can_request_gate(state, gate) {
            return Ok(HookMessage::approval_state_invalid(reason).into_result());
        }
        return Ok(HookResult::allow());
    }
    Ok(HookResult::allow())
}

#[cfg(test)]
mod tests;
