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
mod tests {
    use super::*;
    use crate::hooks::protocol::payloads::HookEnvelopePayload;

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
    fn denies_k3d_make_target() {
        let guard = MakeTargetGuard;
        let c = ctx("make k3d/stop");
        assert!(guard.check(&c).is_some());
    }

    #[test]
    fn allows_safe_make_target() {
        let guard = MakeTargetGuard;
        let c = ctx("make test");
        assert!(guard.check(&c).is_none());
    }

    #[test]
    fn allows_non_make_command() {
        let guard = MakeTargetGuard;
        let c = ctx("echo hello");
        assert!(guard.check(&c).is_none());
    }
}
