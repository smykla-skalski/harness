use crate::hooks::application::GuardContext;
use crate::hooks::guard_bash::runner_guards::{
    deny_batched_tracked_harness_commands, deny_direct_command_log_access,
    deny_harness_managed_run_control_mutation, deny_mixed_kuma_delete, deny_raw_manifest_write,
    deny_suite_storage_mutation,
};
use crate::hooks::protocol::hook_result::HookResult;
use crate::hooks::protocol::result::NormalizedHookResult;
use crate::hooks::registry::Guard;

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
#[path = "structural/tests.rs"]
mod tests;
