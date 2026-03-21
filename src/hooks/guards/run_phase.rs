use crate::hooks::application::GuardContext;
use crate::hooks::guard_bash::runner_guards::guard_runner_phase;
use crate::hooks::protocol::result::NormalizedHookResult;
use crate::hooks::registry::Guard;

use super::parsed_parts;

/// Enforces runner-phase restrictions. Denies commands that are not allowed
/// in the current workflow phase (e.g. mutations after a finalized verdict,
/// or non-closeout commands in completed/aborted state).
pub struct RunPhaseGuard;

impl Guard for RunPhaseGuard {
    fn check(&self, ctx: &GuardContext) -> Option<NormalizedHookResult> {
        let (_, words, _) = parsed_parts(ctx)?;
        let result = guard_runner_phase(ctx, words);
        result
            .into_denial()
            .map(NormalizedHookResult::from_hook_result)
    }
}

#[cfg(test)]
#[path = "run_phase/tests.rs"]
mod tests;
