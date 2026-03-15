use crate::errors::CliError;
use crate::hook::HookResult;
use crate::hook_payloads::HookContext;

/// Execute the audit hook.
///
/// Logs suite-author hook debug info without affecting the main hook decision.
/// For suite-runner or inactive contexts, allow unconditionally.
///
/// # Errors
/// Returns `CliError` on failure.
pub fn execute(ctx: &HookContext) -> Result<HookResult, CliError> {
    if !ctx.skill_active {
        return Ok(HookResult::allow());
    }
    if ctx.is_suite_author() {
        // In the full implementation this would append debug info to the
        // authoring debug log. For now, just allow.
        return Ok(HookResult::allow());
    }
    Ok(HookResult::allow())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::hook::Decision;
    use crate::hook_payloads::{HookContext, HookEnvelopePayload};

    fn ctx_audit(skill: &str) -> HookContext {
        HookContext::from_envelope(
            skill,
            HookEnvelopePayload {
                root: None,
                input_payload: None,
                tool_input: None,
                response: None,
                last_assistant_message: None,
                transcript_path: None,
                stop_hook_active: false,
                raw_keys: vec![],
            },
        )
    }

    // -- Python: test_audit_is_silent_suite_runner --
    #[test]
    fn is_silent_suite_runner() {
        let c = ctx_audit("suite-runner");
        let result = execute(&c).unwrap();
        assert_eq!(result.decision, Decision::Allow);
        assert!(result.code.is_empty());
    }

    // -- Python: test_audit_is_silent_suite_author --
    #[test]
    fn is_silent_suite_author() {
        let c = ctx_audit("suite-author");
        let result = execute(&c).unwrap();
        assert_eq!(result.decision, Decision::Allow);
        assert!(result.code.is_empty());
    }

    #[test]
    fn allows_inactive_skill() {
        let mut c = ctx_audit("suite-runner");
        c.skill_active = false;
        let result = execute(&c).unwrap();
        assert_eq!(result.decision, Decision::Allow);
    }
}
