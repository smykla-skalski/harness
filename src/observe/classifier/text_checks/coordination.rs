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

/// Detect stalled agent progress by checking if the same agent has not
/// produced tool invocations for an extended stretch of lines.
/// Fires when the agent has seen many lines without any `tool_use` blocks.
pub(crate) fn check_stalled_agent(context: &mut TextCheckContext<'_>, issues: &mut Vec<Issue>) {
    let Some(agent_id) = context.state.agent_id.as_deref() else {
        return;
    };
    // Only check on assistant text blocks (not tool results) to avoid noise
    if context.source_tool.is_some() {
        return;
    }
    // If the agent has produced text but no tool uses in the last 50 lines,
    // consider it stalled. We approximate this by checking whether the
    // tool use window is empty while we are past line 50.
    if context.line_number < 50 || !context.state.last_tool_uses.is_empty() {
        return;
    }
    let blueprint = IssueBlueprint::from_code(
        IssueCode::AgentStalledProgress,
        format!("Agent '{agent_id}' has no tool invocations in recent lines"),
    )
    .with_fingerprint(format!("stalled_{agent_id}"))
    .with_guidance(Guidance::advisory(
        "Agent may be stuck generating text without acting. Consider reassigning the task.",
    ))
    .with_confidence(Confidence::Medium)
    .with_fix_safety(FixSafety::TriageRequired)
    .with_source_tool(context.source_tool);
    context.emit_current(issues, blueprint);
}

/// Detect multiple agents editing the same file concurrently.
/// Tracks file paths from `Write`/`Edit` tool uses across agents using the
/// `edit_counts` map in `ScanState`. When an orchestration session is active,
/// the `edit_counts` are agent-scoped and this check fires when a file
/// already edited by another agent appears.
pub(crate) fn check_cross_agent_file_conflict(
    context: &mut TextCheckContext<'_>,
    issues: &mut Vec<Issue>,
) {
    if context.state.orchestration_session_id.is_none() {
        return;
    }
    // Look for file paths in Write/Edit tool result output
    if context.source_tool.is_none() {
        return;
    }
    // Check for "updated successfully" or "created successfully" patterns
    // that indicate a file was written, and extract the path
    let path = extract_written_file_path(context.text);
    let Some(path) = path else {
        return;
    };
    let agent_id = context
        .state
        .agent_id
        .as_deref()
        .unwrap_or("unknown");
    // edit_counts tracks how many agents have touched each file
    let count = context.state.edit_counts.get(path).copied().unwrap_or(0);
    if count > 1 {
        let blueprint = IssueBlueprint::from_code(
            IssueCode::CrossAgentFileConflict,
            format!("File '{path}' edited by {count} agents including '{agent_id}'"),
        )
        .with_fingerprint(format!("conflict_{path}"))
        .with_guidance(Guidance::fix_hint(
            "Multiple agents editing the same file risks merge conflicts. \
             Coordinate via task assignment to prevent concurrent edits.",
        ))
        .with_confidence(Confidence::High)
        .with_fix_safety(FixSafety::TriageRequired)
        .with_source_tool(context.source_tool);
        context.emit_current(issues, blueprint);
    }
}

fn extract_written_file_path(text: &str) -> Option<&str> {
    // Match patterns like "The file /path/to/file.rs has been updated successfully"
    // or "File created successfully at: /path/to/file.rs"
    for line in text.lines() {
        if let Some(rest) = line.strip_prefix("The file ") {
            if let Some(path) = rest.split(" has been").next() {
                return Some(path.trim());
            }
        }
        if let Some(rest) = line.strip_prefix("File created successfully at: ") {
            return Some(rest.trim());
        }
    }
    None
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
