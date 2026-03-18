use crate::errors::HookMessage;
use crate::hooks::guard_bash::predicates::{
    deny_python, has_denied_cluster_binary, has_denied_cluster_binary_anywhere,
    has_denied_legacy_script, has_denied_runner_binary, has_python_inline, has_task_output_access,
    is_tracked_harness_command,
};
use crate::hooks::guard_bash::runner_guards::deny_author_suite_storage_mutation;
use crate::hooks::protocol::context::GuardContext;
use crate::hooks::protocol::result::NormalizedHookResult;
use crate::hooks::registry::Guard;
use crate::rules::suite_runner::TaskOutputPattern;

use super::parsed_parts;

/// Mode that determines which binary checks apply.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Mode {
    Runner,
    Author,
}

/// Denies direct use of blocked cluster binaries, runner binaries,
/// python inline, task output access, and legacy scripts.
///
/// Operates in two modes:
/// - **Runner**: full set of checks including runner-binary, task output,
///   python inline, legacy scripts, and cluster binary (with tracked-command
///   exemption).
/// - **Author**: cluster binary, python inline, and suite storage mutation
///   checks only.
pub struct DeniedBinaryGuard {
    mode: Mode,
}

impl DeniedBinaryGuard {
    #[must_use]
    pub fn runner() -> Self {
        Self { mode: Mode::Runner }
    }

    #[must_use]
    pub fn author() -> Self {
        Self { mode: Mode::Author }
    }
}

impl Guard for DeniedBinaryGuard {
    fn check(&self, ctx: &GuardContext) -> Option<NormalizedHookResult> {
        let (_, words, heads) = parsed_parts(ctx)?;
        match self.mode {
            Mode::Runner => check_runner(ctx, words, heads),
            Mode::Author => check_author(ctx, words, heads),
        }
    }
}

fn deny_runner_flow(details: &str) -> NormalizedHookResult {
    NormalizedHookResult::from_hook_result(
        HookMessage::runner_flow_required("run this command", details.to_string()).into_result(),
    )
}

fn check_runner(
    ctx: &GuardContext,
    words: &[String],
    heads: &[String],
) -> Option<NormalizedHookResult> {
    // Task output access
    if has_task_output_access(words, ctx.command_text()) {
        return Some(deny_runner_flow(TaskOutputPattern::DENY_MESSAGE));
    }
    // Runner binary (gh, etc.)
    if has_denied_runner_binary(heads) {
        return Some(deny_runner_flow(
            "suite runs must stay on the tracked run; \
             do not switch into CI or GitHub workflows",
        ));
    }
    // Python inline
    if has_python_inline(words) {
        return Some(NormalizedHookResult::from_hook_result(deny_python()));
    }
    // Legacy scripts
    if has_denied_legacy_script(words) {
        return Some(NormalizedHookResult::from_hook_result(
            HookMessage::ClusterBinary.into_result(),
        ));
    }
    // Cluster binary in heads
    if has_denied_cluster_binary(heads) {
        return Some(NormalizedHookResult::from_hook_result(
            HookMessage::ClusterBinary.into_result(),
        ));
    }
    // Cluster binary anywhere (exempt tracked harness commands)
    if !is_tracked_harness_command(words) && has_denied_cluster_binary_anywhere(words) {
        return Some(NormalizedHookResult::from_hook_result(
            HookMessage::ClusterBinary.into_result(),
        ));
    }
    None
}

fn check_author(
    _ctx: &GuardContext,
    words: &[String],
    heads: &[String],
) -> Option<NormalizedHookResult> {
    // Cluster binary in heads or anywhere
    if has_denied_cluster_binary(heads) || has_denied_cluster_binary_anywhere(words) {
        return Some(NormalizedHookResult::from_hook_result(
            HookMessage::ClusterBinary.into_result(),
        ));
    }
    // Python inline
    if has_python_inline(words) {
        return Some(NormalizedHookResult::from_hook_result(deny_python()));
    }
    // Suite storage mutation
    let suite_mutation = deny_author_suite_storage_mutation(words);
    if !suite_mutation.code.is_empty() {
        return Some(NormalizedHookResult::from_hook_result(suite_mutation));
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::hooks::protocol::payloads::HookEnvelopePayload;

    fn ctx(skill: &str, command: &str) -> GuardContext {
        GuardContext::from_test_envelope(
            skill,
            HookEnvelopePayload {
                tool_name: "Bash".to_string(),
                tool_input: serde_json::json!({ "command": command }),
                tool_response: serde_json::Value::Null,
                last_assistant_message: None,
                transcript_path: None,
                stop_hook_active: false,
                raw_keys: vec![],
            },
        )
    }

    #[test]
    fn runner_denies_kubectl() {
        let guard = DeniedBinaryGuard::runner();
        let c = ctx("suite:run", "kubectl get pods");
        assert!(guard.check(&c).is_some());
    }

    #[test]
    fn runner_allows_harness_run_with_kubectl() {
        let guard = DeniedBinaryGuard::runner();
        let c = ctx(
            "suite:run",
            "harness run record --phase verify --label pods -- kubectl get pods -o json",
        );
        assert!(guard.check(&c).is_none());
    }

    #[test]
    fn runner_denies_python_inline() {
        let guard = DeniedBinaryGuard::runner();
        let c = ctx("suite:run", "python3 -c \"import json\"");
        assert!(guard.check(&c).is_some());
    }

    #[test]
    fn runner_allows_python_version() {
        let guard = DeniedBinaryGuard::runner();
        let c = ctx("suite:run", "python3 --version");
        assert!(guard.check(&c).is_none());
    }

    #[test]
    fn author_denies_kubectl() {
        let guard = DeniedBinaryGuard::author();
        let c = ctx("suite:new", "kubectl get pods");
        assert!(guard.check(&c).is_some());
    }

    #[test]
    fn author_allows_harness() {
        let guard = DeniedBinaryGuard::author();
        let c = ctx("suite:new", "harness authoring-show --kind session");
        assert!(guard.check(&c).is_none());
    }

    #[test]
    fn author_denies_rm_rf_suite_dir() {
        let guard = DeniedBinaryGuard::author();
        let c = ctx(
            "suite:new",
            "rm -rf ~/.local/share/kuma/suites/motb-compliance",
        );
        let result = guard.check(&c);
        assert!(result.is_some());
    }

    #[test]
    fn runner_allows_echo() {
        let guard = DeniedBinaryGuard::runner();
        let c = ctx("suite:run", "echo hello world");
        assert!(guard.check(&c).is_none());
    }
}
