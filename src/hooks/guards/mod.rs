mod admin_endpoint;
mod denied_binary;
mod make_target;
mod run_phase;
mod structural;
mod subshell;

pub use admin_endpoint::AdminEndpointGuard;
pub use denied_binary::DeniedBinaryGuard;
pub use make_target::MakeTargetGuard;
pub use run_phase::RunPhaseGuard;
pub use structural::StructuralGuard;
pub use subshell::SubshellGuard;

use crate::hooks::application::GuardContext;
use crate::hooks::registry::GuardChain;
use crate::kernel::command_intent::ParsedCommand;

/// Extract parsed command parts, returning `None` when the command is empty
/// or missing. Parse errors are treated as allow-through so the caller's
/// top-level handler can surface the error with the right hook message.
fn parsed_parts(ctx: &GuardContext) -> Option<(&ParsedCommand, &[String], &[String])> {
    let command = ctx.parsed_command().ok().flatten()?;
    let words = command.words();
    if words.is_empty() {
        return None;
    }
    Some((command, words, command.heads()))
}

/// Build the standard guard chain for suite:run bash commands.
#[must_use]
pub fn runner_bash_chain() -> GuardChain {
    GuardChain::new(vec![
        Box::new(RunPhaseGuard),
        Box::new(SubshellGuard),
        Box::new(DeniedBinaryGuard::runner()),
        Box::new(MakeTargetGuard),
        Box::new(StructuralGuard),
        Box::new(AdminEndpointGuard),
    ])
}

/// Build the standard guard chain for suite:new bash commands.
#[must_use]
pub fn author_bash_chain() -> GuardChain {
    GuardChain::new(vec![
        Box::new(SubshellGuard),
        Box::new(DeniedBinaryGuard::author()),
        Box::new(AdminEndpointGuard),
    ])
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::hooks::application::GuardContext;
    use crate::hooks::protocol::payloads::HookEnvelopePayload;
    use crate::hooks::protocol::result::NormalizedDecision;

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

    // --- GuardChain ordering tests ---

    #[test]
    fn empty_chain_allows() {
        let chain = GuardChain::new(vec![]);
        let c = ctx("suite:run", "echo hello");
        let result = chain.evaluate(&c);
        assert_eq!(result.decision, NormalizedDecision::Allow);
    }

    #[test]
    fn chain_stops_at_first_denial() {
        let chain = runner_bash_chain();
        // kubectl is denied - subshell guard runs first but won't fire,
        // then denied binary guard catches it.
        let c = ctx("suite:run", "kubectl get pods");
        let result = chain.evaluate(&c);
        assert_eq!(result.decision, NormalizedDecision::Deny);
    }

    #[test]
    fn chain_allows_safe_commands() {
        let chain = runner_bash_chain();
        let c = ctx("suite:run", "echo hello");
        let result = chain.evaluate(&c);
        assert_eq!(result.decision, NormalizedDecision::Allow);
    }

    #[test]
    fn author_chain_denies_kubectl() {
        let chain = author_bash_chain();
        let c = ctx("suite:new", "kubectl get pods");
        let result = chain.evaluate(&c);
        assert_eq!(result.decision, NormalizedDecision::Deny);
    }

    #[test]
    fn author_chain_allows_harness_command() {
        let chain = author_bash_chain();
        let c = ctx("suite:new", "harness authoring-show --kind session");
        let result = chain.evaluate(&c);
        assert_eq!(result.decision, NormalizedDecision::Allow);
    }

    #[test]
    fn subshell_smuggling_caught_before_binary_check() {
        let chain = runner_bash_chain();
        let c = ctx("suite:run", "echo $(kubectl get pods)");
        let result = chain.evaluate(&c);
        assert_eq!(result.decision, NormalizedDecision::Deny);
        // Subshell guard produces KSR017
        assert_eq!(result.code.as_deref(), Some("KSR017"));
    }
}
