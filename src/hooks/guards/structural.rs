use crate::hooks::context::GuardContext;
use crate::hooks::engine::Guard;
use crate::hooks::guard_bash::runner_guards::{
    deny_batched_tracked_harness_commands, deny_direct_command_log_access,
    deny_harness_managed_run_control_mutation, deny_mixed_kuma_delete, deny_raw_manifest_write,
    deny_suite_storage_mutation,
};
use crate::hooks::hook_result::HookResult;
use crate::hooks::result::NormalizedHookResult;

use super::parsed_parts;

/// Bundles the structural runner guards that enforce command shape and
/// resource mutation rules.
///
/// Checks (in order):
/// 1. Batched tracked harness commands
/// 2. Direct command-log access
/// 3. Harness-managed run control file mutation
/// 4. Raw manifest writes via shell redirects
/// 5. Suite storage mutation from suite:run
/// 6. Mixed Kuma resource delete in one command
pub struct StructuralGuard;

impl Guard for StructuralGuard {
    fn check(&self, ctx: &GuardContext) -> Option<NormalizedHookResult> {
        let (_, words, _) = parsed_parts(ctx)?;

        let structural_guards: &[fn(&GuardContext, &[String]) -> HookResult] = &[
            |_, w| deny_batched_tracked_harness_commands(w),
            deny_direct_command_log_access,
            deny_harness_managed_run_control_mutation,
            |ctx, w| deny_raw_manifest_write(w, ctx.command_text()),
            |_, w| deny_suite_storage_mutation(w),
            |_, w| deny_mixed_kuma_delete(w),
        ];

        for guard in structural_guards {
            if let Some(denied) = guard(ctx, words).into_denial() {
                return Some(NormalizedHookResult::from_hook_result(denied));
            }
        }

        None
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::hooks::payloads::HookEnvelopePayload;

    fn ctx(command: &str) -> GuardContext {
        GuardContext::from_test_envelope(
            "suite:run",
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
    fn denies_batched_tracked_harness_in_loop() {
        let guard = StructuralGuard;
        let c = ctx("for i in 01 02 03; do \
             harness apply --manifest \"g10/${i}.yaml\" --step \"g10-manifest-${i}\" || break; \
             done");
        assert!(guard.check(&c).is_some());
    }

    #[test]
    fn denies_mixed_kuma_delete() {
        let guard = StructuralGuard;
        let c = ctx("harness record --phase cleanup --label cleanup-g04 -- \
             kubectl delete meshopentelemetrybackend otel-runtime \
             meshmetric metrics-runtime -n kuma-system");
        assert!(guard.check(&c).is_some());
    }

    #[test]
    fn allows_single_kuma_delete() {
        let guard = StructuralGuard;
        let c = ctx("harness record --phase cleanup --label cleanup-g05 -- \
             kubectl delete meshopentelemetrybackend otel-e2e -n kuma-system");
        assert!(guard.check(&c).is_none());
    }

    #[test]
    fn allows_plain_command() {
        let guard = StructuralGuard;
        let c = ctx("echo hello");
        assert!(guard.check(&c).is_none());
    }
}
