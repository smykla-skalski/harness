use crate::errors::HookMessage;
use crate::hooks::application::GuardContext;
use crate::hooks::guard_bash::predicates::make_target;
use crate::hooks::protocol::result::NormalizedHookResult;
use crate::hooks::registry::Guard;
use crate::hooks::runner_policy::MakeTargetPrefix;

use super::parsed_parts;

/// Denies `make` invocations that target blocked prefixes (e.g. `k3d/`,
/// `docker/`).
pub struct MakeTargetGuard;

impl Guard for MakeTargetGuard {
    fn check(&self, ctx: &GuardContext) -> Option<NormalizedHookResult> {
        let (_, words, _) = parsed_parts(ctx)?;
        let target = make_target(words)?;
        if MakeTargetPrefix::is_denied_target(target) {
            Some(NormalizedHookResult::from_hook_result(
                HookMessage::ClusterBinary.into_result(),
            ))
        } else {
            None
        }
    }
}

#[cfg(test)]
#[path = "make_target/tests.rs"]
mod tests;
