pub(crate) mod predicates;

use crate::hooks::application::GuardContext as HookContext;
use crate::hooks::protocol::hook_result::HookResult;
use harness_kernel::errors::{CliError, HookMessage};

use predicates::{
    deny_create_suite_storage_mutation, deny_python, has_admin_endpoint_hint,
    has_denied_cluster_binary, has_denied_cluster_binary_anywhere, has_denied_subshell_binary,
    has_python_inline, is_harness_head,
};

/// Execute the guard-bash hook.
///
/// # Errors
/// Returns `CliError` on failure.
pub fn execute(ctx: &HookContext) -> Result<HookResult, CliError> {
    if !ctx.skill_active || !ctx.is_suite_create() {
        return Ok(HookResult::allow());
    }
    let command = match ctx.parsed_command() {
        Ok(Some(command)) => command,
        Ok(None) => return Ok(HookResult::allow()),
        Err(e) => {
            return Ok(HookMessage::runner_flow_required(
                "parse command",
                format!("shell tokenization failed: {e}"),
            )
            .into_result());
        }
    };
    let words = command.words();
    if words.is_empty() {
        return Ok(HookResult::allow());
    }
    Ok(guard_suite_create(ctx, words, command.heads()))
}

fn guard_suite_create(ctx: &HookContext, words: &[String], heads: &[String]) -> HookResult {
    if has_denied_subshell_binary(ctx.command_text(), words) {
        return HookMessage::SubshellSmuggling.into_result();
    }
    if has_denied_cluster_binary(heads) || has_denied_cluster_binary_anywhere(words) {
        return HookMessage::ClusterBinary.into_result();
    }
    if has_python_inline(words) {
        return deny_python();
    }
    if !is_harness_head(heads) && has_admin_endpoint_hint(words) {
        return HookMessage::AdminEndpoint.into_result();
    }
    let suite_mutation = deny_create_suite_storage_mutation(words);
    if !suite_mutation.code.is_empty() {
        return suite_mutation;
    }
    HookResult::allow()
}

#[cfg(test)]
mod tests;
