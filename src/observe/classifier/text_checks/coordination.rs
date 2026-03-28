use super::super::emitter::{Guidance, IssueBlueprint};
use super::super::TextCheckContext;
use crate::observe::types::{Confidence, FixSafety, Issue, IssueCode};

/// Detect API rate limit or overload errors (429, 529) in tool output.
/// Runs on all roles and source tools since rate limits surface everywhere.
pub(crate) fn check_api_rate_limit(context: &mut TextCheckContext<'_>, issues: &mut Vec<Issue>) {
    const SIGNALS: &[&str] = &[
        "429 too many requests",
        "rate limit exceeded",
        "overloaded_error",
        "rate_limit_error",
        "too many requests",
        "529 overloaded",
    ];
    for signal in SIGNALS {
        if context.lower.contains(signal) {
            let blueprint = IssueBlueprint::from_code(
                IssueCode::ApiRateLimitDetected,
                format!("API rate limit: {signal}"),
            )
            .with_fingerprint((*signal).to_string())
            .with_guidance(Guidance::advisory(
                "Back off and retry after a delay. If persistent, reduce concurrency.",
            ))
            .with_confidence(Confidence::High)
            .with_fix_safety(FixSafety::AdvisoryOnly)
            .with_source_tool(context.source_tool);
            context.emit_current(issues, blueprint);
            return;
        }
    }
}

/// Detect guard denial loops - agent hitting the same guard repeatedly.
/// Fires when orchestration context is set and the agent has been denied
/// multiple times in the current scan window.
pub(crate) fn check_guard_denial_loop(
    context: &mut TextCheckContext<'_>,
    issues: &mut Vec<Issue>,
) {
    if context.state.agent_id.is_none() {
        return;
    }
    let key = (IssueCode::HookDeniedToolCall, "hook_denied".to_string());
    let count = context
        .state
        .issue_occurrences
        .get(&key)
        .map_or(0, |tracker| tracker.count);
    if count >= 3 {
        let role_hint = context
            .state
            .agent_role
            .as_deref()
            .unwrap_or("unknown");
        let blueprint = IssueBlueprint::from_code(
            IssueCode::AgentGuardDenialLoop,
            format!("Agent ({role_hint}) hit guard denials {count} times"),
        )
        .with_fingerprint("guard_denial_loop".to_string())
        .with_guidance(Guidance::fix_hint(
            "Agent is repeatedly blocked by guards. Reassign or provide guidance.",
        ))
        .with_confidence(Confidence::High)
        .with_fix_safety(FixSafety::TriageRequired)
        .with_source_tool(context.source_tool);
        context.emit_current(issues, blueprint);
    }
}
