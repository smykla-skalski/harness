use crate::errors::HookMessage;
use crate::hooks::application::GuardContext;
use crate::hooks::guard_bash::predicates::has_denied_subshell_binary;
use crate::hooks::protocol::result::NormalizedHookResult;
use crate::hooks::registry::Guard;

use super::parsed_parts;

/// Denies commands that hide blocked binaries inside subshell substitution
/// (`$(...)` or backtick) forms.
pub struct SubshellGuard;

impl Guard for SubshellGuard {
    fn check(&self, ctx: &GuardContext) -> Option<NormalizedHookResult> {
        let (_, words, _) = parsed_parts(ctx)?;
        if has_denied_subshell_binary(ctx.command_text(), words) {
            Some(NormalizedHookResult::from_hook_result(
                HookMessage::SubshellSmuggling.into_result(),
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
    fn denies_kubectl_in_subshell() {
        let guard = SubshellGuard;
        let c = ctx("echo $(kubectl get pods)");
        let result = guard.check(&c);
        assert!(result.is_some());
        let result = result.unwrap();
        assert_eq!(result.code.as_deref(), Some("KSR017"));
    }

    #[test]
    fn denies_docker_in_backtick() {
        let guard = SubshellGuard;
        let c = ctx("echo `docker ps`");
        let result = guard.check(&c);
        assert!(result.is_some());
    }

    #[test]
    fn allows_safe_subshell() {
        let guard = SubshellGuard;
        let c = ctx("echo $(date +%Y-%m-%d)");
        assert!(guard.check(&c).is_none());
    }

    #[test]
    fn allows_plain_command() {
        let guard = SubshellGuard;
        let c = ctx("echo hello");
        assert!(guard.check(&c).is_none());
    }
}
