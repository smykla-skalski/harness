use crate::errors::HookMessage;
use crate::hooks::application::GuardContext;
use crate::hooks::guard_bash::predicates::{
    allows_wrapped_envoy_admin, has_admin_endpoint_hint, is_harness_head,
};
use crate::hooks::protocol::result::NormalizedHookResult;
use crate::hooks::registry::Guard;

use super::parsed_parts;

/// Denies direct access to Envoy admin endpoints when the command does not
/// go through an approved `harness` wrapper.
pub struct AdminEndpointGuard;

impl Guard for AdminEndpointGuard {
    fn check(&self, ctx: &GuardContext) -> Option<NormalizedHookResult> {
        let (_, words, heads) = parsed_parts(ctx)?;
        if !has_admin_endpoint_hint(words) {
            return None;
        }
        if is_harness_head(heads) || allows_wrapped_envoy_admin(words) {
            return None;
        }
        Some(NormalizedHookResult::from_hook_result(
            HookMessage::AdminEndpoint.into_result(),
        ))
    }
}

#[cfg(test)]
#[path = "admin_endpoint/tests.rs"]
mod tests;
