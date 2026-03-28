use super::*;

#[test]
fn rate_limit_detected_in_bash_output() {
    let mut state = make_state();
    state.agent_id = Some("codex-1".into());
    let issues = check_text_for_issues(
        10,
        MessageRole::Assistant,
        "Error: 429 too many requests - rate limited",
        Some(SourceTool::Bash),
        &mut state,
    );
    // May match via either the TextRule or the procedural check - both use the same code
    let rate_issues: Vec<_> = issues
        .iter()
        .filter(|issue| issue.code == IssueCode::ApiRateLimitDetected)
        .collect();
    assert!(!rate_issues.is_empty(), "should detect rate limit");
}

#[test]
fn rate_limit_not_triggered_for_normal_output() {
    let mut state = make_state();
    let issues = check_text_for_issues(
        10,
        MessageRole::Assistant,
        "harness run capture completed successfully",
        Some(SourceTool::Bash),
        &mut state,
    );
    let rate_issues: Vec<_> = issues
        .iter()
        .filter(|issue| issue.code == IssueCode::ApiRateLimitDetected)
        .collect();
    assert!(rate_issues.is_empty());
}

#[test]
fn coordination_codes_in_registry() {
    use crate::observe::classifier::registry::issue_code_meta;
    let codes = [
        IssueCode::AgentStalledProgress,
        IssueCode::AgentRepeatedError,
        IssueCode::AgentGuardDenialLoop,
        IssueCode::ApiRateLimitDetected,
        IssueCode::AgentSkillMisuse,
        IssueCode::CrossAgentFileConflict,
    ];
    for code in codes {
        let meta = issue_code_meta(code);
        assert!(meta.is_some(), "{code:?} should be in the registry",);
        assert_eq!(
            meta.unwrap().default_category,
            IssueCategory::AgentCoordination,
        );
    }
}

#[test]
fn coordination_checks_only_fire_with_agent_context() {
    let mut state = make_state();
    // Without agent_id, coordination checks should not run
    let issues = check_text_for_issues(
        10,
        MessageRole::Assistant,
        "overloaded_error from API",
        Some(SourceTool::Bash),
        &mut state,
    );
    // The TextRule still fires regardless (it's not gated on agent_id),
    // but the procedural coordination check is gated.
    // Both produce ApiRateLimitDetected, so we just check total count.
    let count = issues
        .iter()
        .filter(|issue| issue.code == IssueCode::ApiRateLimitDetected)
        .count();
    // At least the TextRule should match
    assert!(count >= 1);
}

#[test]
fn stalled_agent_fires_when_no_tool_uses() {
    let mut state = make_state();
    state.agent_id = Some("codex-stall".into());
    state.orchestration_session_id = Some("sess-1".into());
    // Simulate being past line 50 with empty tool use window
    let issues = check_text_for_issues(
        60,
        MessageRole::Assistant,
        "I am still thinking about this problem and considering options...",
        None,
        &mut state,
    );
    let stalled: Vec<_> = issues
        .iter()
        .filter(|issue| issue.code == IssueCode::AgentStalledProgress)
        .collect();
    assert!(!stalled.is_empty(), "should detect stalled agent");
}

#[test]
fn stalled_agent_does_not_fire_before_line_50() {
    let mut state = make_state();
    state.agent_id = Some("codex-early".into());
    let issues = check_text_for_issues(10, MessageRole::Assistant, "thinking...", None, &mut state);
    let stalled: Vec<_> = issues
        .iter()
        .filter(|issue| issue.code == IssueCode::AgentStalledProgress)
        .collect();
    assert!(stalled.is_empty(), "should not fire early in session");
}

#[test]
fn cross_agent_file_conflict_detected() {
    let mut state = make_state();
    state.agent_id = Some("codex-1".into());
    state.orchestration_session_id = Some("sess-1".into());
    let editors = state
        .cross_agent_editors
        .entry("src/main.rs".into())
        .or_default();
    editors.insert("claude-1".into());
    editors.insert("codex-1".into());
    let issues = check_text_for_issues(
        10,
        MessageRole::Assistant,
        "The file src/main.rs has been updated successfully",
        Some(SourceTool::Write),
        &mut state,
    );
    let conflicts: Vec<_> = issues
        .iter()
        .filter(|issue| issue.code == IssueCode::CrossAgentFileConflict)
        .collect();
    assert!(
        !conflicts.is_empty(),
        "should detect cross-agent file conflict"
    );
}

#[test]
fn cross_agent_file_conflict_not_triggered_without_session() {
    let mut state = make_state();
    let editors = state
        .cross_agent_editors
        .entry("src/lib.rs".into())
        .or_default();
    editors.insert("claude-1".into());
    editors.insert("codex-1".into());
    let issues = check_text_for_issues(
        10,
        MessageRole::Assistant,
        "The file src/lib.rs has been updated successfully",
        Some(SourceTool::Write),
        &mut state,
    );
    let conflicts: Vec<_> = issues
        .iter()
        .filter(|issue| issue.code == IssueCode::CrossAgentFileConflict)
        .collect();
    assert!(
        conflicts.is_empty(),
        "should not fire without orchestration context"
    );
}

#[test]
fn guard_denial_loop_detected_after_three_denials() {
    let mut state = make_state();
    state.agent_id = Some("codex-1".into());
    state.agent_role = Some("worker".into());

    for line in [10, 20] {
        let issues = check_text_for_issues(
            line,
            MessageRole::Assistant,
            "The system denied this tool call because it violates policy",
            None,
            &mut state,
        );
        assert!(
            issues
                .iter()
                .all(|issue| issue.code != IssueCode::AgentGuardDenialLoop)
        );
    }

    let issues = check_text_for_issues(
        30,
        MessageRole::Assistant,
        "The system denied this tool call because it violates policy",
        None,
        &mut state,
    );
    assert!(
        issues
            .iter()
            .any(|issue| issue.code == IssueCode::AgentGuardDenialLoop),
        "third denial should trigger the guard loop detector",
    );
}
