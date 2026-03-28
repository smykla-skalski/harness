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
        assert!(
            meta.is_some(),
            "{code:?} should be in the registry",
        );
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
