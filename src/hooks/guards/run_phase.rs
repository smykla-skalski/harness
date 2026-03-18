use crate::hooks::protocol::context::GuardContext;
use crate::hooks::registry::Guard;
use crate::hooks::guard_bash::runner_guards::guard_runner_phase;
use crate::hooks::protocol::result::NormalizedHookResult;

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
    fn allows_when_no_runner_state() {
        let guard = RunPhaseGuard;
        // Without runner state loaded, phase guard passes through.
        let c = ctx("harness run --phase verify --label test kubectl get pods");
        assert!(guard.check(&c).is_none());
    }

    #[test]
    fn allows_plain_command() {
        let guard = RunPhaseGuard;
        let c = ctx("echo hello");
        assert!(guard.check(&c).is_none());
    }
}
