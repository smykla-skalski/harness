pub(crate) mod predicates;
pub(crate) mod runner_guards;

use crate::errors::{CliError, HookMessage};
use crate::hooks::application::GuardContext as HookContext;
use crate::hooks::protocol::hook_result::HookResult;

use predicates::{
    deny_python, has_admin_endpoint_hint, has_denied_cluster_binary,
    has_denied_cluster_binary_anywhere, has_denied_legacy_script, has_denied_subshell_binary,
    has_python_inline, is_harness_head,
};
use runner_guards::{
    deny_batched_tracked_harness_commands, deny_create_suite_storage_mutation,
    deny_direct_command_log_access, deny_harness_managed_run_control_mutation,
    deny_mixed_kuma_delete, deny_raw_manifest_write, deny_suite_storage_mutation,
    guard_runner_phase, runner_binary_and_pattern_guards,
};

/// Execute the guard-bash hook.
///
/// # Errors
/// Returns `CliError` on failure.
pub fn execute(ctx: &HookContext) -> Result<HookResult, CliError> {
    if !ctx.skill_active {
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
    let heads = command.heads();
    if ctx.is_suite_create() {
        return Ok(guard_suite_create(ctx, words, heads));
    }
    Ok(guard_suite_runner(ctx, words, heads))
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

fn guard_suite_runner(ctx: &HookContext, words: &[String], heads: &[String]) -> HookResult {
    // Universal security guards run regardless of tracked run context.
    // These block dangerous binaries and patterns even when run state
    // cannot be loaded (early bootstrap, race conditions, missing XDG state).
    if has_denied_subshell_binary(ctx.command_text(), words) {
        return HookMessage::SubshellSmuggling.into_result();
    }
    if let Some(denied) = runner_binary_and_pattern_guards(ctx, words, heads) {
        return denied;
    }
    if has_denied_legacy_script(words) {
        return HookMessage::ClusterBinary.into_result();
    }
    if has_denied_cluster_binary(heads)
        || (!predicates::is_tracked_harness_command(words)
            && has_denied_cluster_binary_anywhere(words))
    {
        return HookMessage::ClusterBinary.into_result();
    }
    if has_admin_endpoint_hint(words)
        && !is_harness_head(heads)
        && !predicates::allows_wrapped_envoy_admin(words)
    {
        return HookMessage::AdminEndpoint.into_result();
    }

    // Phase and structural guards only apply when a tracked run is active.
    if !runner_guards::has_tracked_run_context(ctx) {
        return HookResult::allow();
    }
    if let Some(denied) = guard_runner_phase(ctx, words).into_denial() {
        return denied;
    }
    let structural_guards: &[fn(&HookContext, &[String]) -> HookResult] = &[
        |_, w| deny_batched_tracked_harness_commands(w),
        deny_direct_command_log_access,
        deny_harness_managed_run_control_mutation,
        |ctx, w| deny_raw_manifest_write(w, ctx.command_text()),
        |_, w| deny_suite_storage_mutation(w),
        |_, w| deny_mixed_kuma_delete(w),
    ];
    for guard in structural_guards {
        if let Some(denied) = guard(ctx, words).into_denial() {
            return denied;
        }
    }
    HookResult::allow()
}

#[cfg(test)]
mod tests;
