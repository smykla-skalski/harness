use crate::errors::HookMessage;
use crate::hooks::application::GuardContext as HookContext;
use crate::hooks::protocol::hook_result::HookResult;
use crate::hooks::runner_policy::{MakeTargetPrefix, SuiteMutationBinary, TaskOutputPattern};
use crate::kernel::command_intent::{command_heads, normalized_binary_name, path_like_words};

use super::predicates::{
    allows_wrapped_envoy_admin, deny_python, deny_runner_flow, has_admin_endpoint_hint,
    has_denied_cluster_binary, has_denied_cluster_binary_anywhere, has_denied_legacy_script,
    has_denied_runner_binary, has_python_inline, has_task_output_access, is_harness_head,
    is_tracked_harness_command, make_target,
};

#[path = "runner_guards/phase.rs"]
mod phase;
#[path = "runner_guards/structural.rs"]
mod structural;

pub(crate) use self::phase::{guard_runner_phase, has_tracked_run_context};
pub(crate) use self::structural::{
    deny_batched_tracked_harness_commands, deny_direct_command_log_access,
    deny_harness_managed_run_control_mutation, deny_mixed_kuma_delete, deny_raw_manifest_write,
    deny_suite_storage_mutation,
};

const DELETE_FLAGS_WITH_VALUE: &[&str] = &[
    "-n",
    "--namespace",
    "-l",
    "--selector",
    "-o",
    "--output",
    "--cascade",
    "--context",
    "--cluster",
    "--field-selector",
    "--grace-period",
    "--kubeconfig",
    "--timeout",
    "--wait",
];

const KUMA_DELETE_RESOURCE_KINDS: &[&str] = &[
    "meshopentelemetrybackend",
    "meshopentelemetrybackends",
    "meshmetric",
    "meshmetrics",
    "meshtrace",
    "meshtraces",
    "meshaccesslog",
    "meshaccesslogs",
];

pub(crate) fn deny_author_suite_storage_mutation(words: &[String]) -> HookResult {
    let heads = command_heads(words);
    if !heads
        .iter()
        .any(|h| SuiteMutationBinary::is_mutation_binary(&normalized_binary_name(h)))
    {
        return HookResult::allow();
    }
    let path_words = path_like_words(words);
    for word in &path_words {
        if word.contains("/suites/") || word.starts_with("suites/") {
            return HookMessage::approval_required(
                "mutate suite storage",
                "do not delete or overwrite existing suite directories; \
                 use `harness authoring begin` which handles conflicts",
            )
            .into_result();
        }
    }
    HookResult::allow()
}

pub(crate) fn runner_binary_and_pattern_guards(
    ctx: &HookContext,
    words: &[String],
    heads: &[String],
) -> Option<HookResult> {
    if has_task_output_access(words, ctx.command_text()) {
        return Some(deny_runner_flow(TaskOutputPattern::DENY_MESSAGE));
    }
    if has_tracked_run_context(ctx) && has_denied_runner_binary(heads) {
        return Some(deny_runner_flow(
            "suite runs must stay on the tracked run; \
             do not switch into CI or GitHub workflows",
        ));
    }
    if has_python_inline(words) {
        return Some(deny_python());
    }
    if let Some(target) = make_target(words)
        && MakeTargetPrefix::is_denied_target(target)
    {
        return Some(HookMessage::ClusterBinary.into_result());
    }
    None
}

pub(crate) fn runner_tail_guards(words: &[String], heads: &[String]) -> HookResult {
    if has_denied_legacy_script(words) {
        return HookMessage::ClusterBinary.into_result();
    }
    if has_denied_cluster_binary(heads)
        || (!is_tracked_harness_command(words) && has_denied_cluster_binary_anywhere(words))
    {
        return HookMessage::ClusterBinary.into_result();
    }
    if has_admin_endpoint_hint(words)
        && !is_harness_head(heads)
        && !allows_wrapped_envoy_admin(words)
    {
        return HookMessage::AdminEndpoint.into_result();
    }
    HookResult::allow()
}
