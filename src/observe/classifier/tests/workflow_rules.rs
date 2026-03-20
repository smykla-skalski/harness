use super::*;

#[test]
fn detects_jq_error_in_bash_output() {
    let mut state = make_state();
    let issues = check_text_for_issues(
        10,
        MessageRole::User,
        "jq: error (at <stdin>:1): Cannot iterate over null (null)",
        Some(SourceTool::Bash),
        &mut state,
    );
    assert!(
        issues
            .iter()
            .any(|i| i.category == IssueCategory::DataIntegrity
                && i.severity == IssueSeverity::Medium
                && i.summary.contains("jq"))
    );
}

#[test]
fn detects_jq_null_iteration_without_jq_prefix() {
    let mut state = make_state();
    let issues = check_text_for_issues(
        10,
        MessageRole::User,
        "Cannot iterate over null (null)\nnull is not iterable",
        Some(SourceTool::Bash),
        &mut state,
    );
    assert!(
        issues
            .iter()
            .any(|i| i.category == IssueCategory::DataIntegrity && i.summary.contains("jq"))
    );
}

#[test]
fn detects_jq_parse_error() {
    let mut state = make_state();
    let issues = check_text_for_issues(
        10,
        MessageRole::User,
        "parse error (Invalid numeric literal at line 1, column 5) from jq",
        Some(SourceTool::Bash),
        &mut state,
    );
    assert!(
        issues
            .iter()
            .any(|i| i.category == IssueCategory::DataIntegrity && i.summary.contains("jq"))
    );
}

#[test]
fn skips_jq_error_without_bash_source() {
    let mut state = make_state();
    let issues = check_text_for_issues(
        10,
        MessageRole::User,
        "jq: error (at <stdin>:1): Cannot iterate over null (null)",
        None,
        &mut state,
    );
    assert!(!issues.iter().any(|i| i.summary.contains("jq")));
}

#[test]
fn jq_error_deduplicates() {
    let mut state = make_state();
    let first = check_text_for_issues(
        10,
        MessageRole::User,
        "jq: error (at <stdin>:1): Cannot iterate over null (null)",
        Some(SourceTool::Bash),
        &mut state,
    );
    let second = check_text_for_issues(
        11,
        MessageRole::User,
        "jq: error (at <stdin>:2): null is not iterable",
        Some(SourceTool::Bash),
        &mut state,
    );
    assert_eq!(first.len(), 1);
    assert!(second.is_empty());
}

#[test]
fn detects_ksrcli008_error_code() {
    let mut state = make_state();
    let issues = check_text_for_issues(
        10,
        MessageRole::User,
        "Error KSRCLI008: verdict is still pending, cannot close out",
        Some(SourceTool::Bash),
        &mut state,
    );
    assert!(
        issues
            .iter()
            .any(|i| i.category == IssueCategory::WorkflowError
                && i.severity == IssueSeverity::Critical
                && i.summary.contains("Closeout blocked"))
    );
}

#[test]
fn detects_verdict_still_pending_text() {
    let mut state = make_state();
    let issues = check_text_for_issues(
        10,
        MessageRole::User,
        "The run cannot finish because verdict is still pending",
        Some(SourceTool::Bash),
        &mut state,
    );
    assert!(
        issues
            .iter()
            .any(|i| i.category == IssueCategory::WorkflowError
                && i.summary.contains("Closeout blocked"))
    );
}

#[test]
fn closeout_verdict_pending_deduplicates() {
    let mut state = make_state();
    let first = check_text_for_issues(
        10,
        MessageRole::User,
        "Error KSRCLI008: verdict is still pending",
        Some(SourceTool::Bash),
        &mut state,
    );
    let second = check_text_for_issues(
        11,
        MessageRole::User,
        "Error KSRCLI008: verdict is still pending again",
        Some(SourceTool::Bash),
        &mut state,
    );
    assert_eq!(first.len(), 1);
    assert!(second.is_empty());
}

#[test]
fn skips_ksrcli008_without_bash_source() {
    let mut state = make_state();
    let issues = check_text_for_issues(
        10,
        MessageRole::User,
        "Error KSRCLI008: verdict is still pending",
        None,
        &mut state,
    );
    assert!(
        !issues
            .iter()
            .any(|i| i.summary.contains("Closeout blocked"))
    );
}

#[test]
fn closeout_verdict_pending_output_shape() {
    let mut state = make_state();
    let issues = check_text_for_issues(
        10,
        MessageRole::User,
        "Error KSRCLI008: verdict is still pending",
        Some(SourceTool::Bash),
        &mut state,
    );
    assert_eq!(issues.len(), 1);
    let issue = &issues[0];
    assert!(issue.fix_safety.is_fixable());
    assert!(issue.fix_target.is_none());
    assert!(
        issue
            .fix_hint
            .as_deref()
            .is_some_and(|hint| hint.contains("auto-compute verdict"))
    );
}

#[test]
fn detects_runner_state_event_transition_error() {
    let mut state = make_state();
    let issues = check_text_for_issues(
        10,
        MessageRole::User,
        "event-based transitions are handled by the workflow module, not the CLI",
        Some(SourceTool::Bash),
        &mut state,
    );
    assert!(issues.iter().any(|i| i.category == IssueCategory::CliError
        && i.severity == IssueSeverity::Medium
        && i.summary.contains("runner-state event transition")));
}

#[test]
fn detects_runner_state_query_only_error() {
    let mut state = make_state();
    let issues = check_text_for_issues(
        10,
        MessageRole::User,
        "this CLI path only supports state queries, not event transitions",
        Some(SourceTool::Bash),
        &mut state,
    );
    assert!(issues.iter().any(|i| i.category == IssueCategory::CliError
        && i.summary.contains("runner-state event transition")));
}

#[test]
fn runner_state_event_error_deduplicates() {
    let mut state = make_state();
    let first = check_text_for_issues(
        10,
        MessageRole::User,
        "event-based transitions are handled by the workflow module",
        Some(SourceTool::Bash),
        &mut state,
    );
    let second = check_text_for_issues(
        11,
        MessageRole::User,
        "event-based transitions are handled by the workflow module",
        Some(SourceTool::Bash),
        &mut state,
    );
    assert_eq!(first.len(), 1);
    assert!(second.is_empty());
}

#[test]
fn skips_runner_state_event_error_without_bash() {
    let mut state = make_state();
    let issues = check_text_for_issues(
        10,
        MessageRole::User,
        "event-based transitions are handled by the workflow module",
        None,
        &mut state,
    );
    assert!(
        !issues
            .iter()
            .any(|i| i.summary.contains("runner-state event transition"))
    );
}

#[test]
fn runner_state_event_error_output_shape() {
    let mut state = make_state();
    let issues = check_text_for_issues(
        10,
        MessageRole::User,
        "event-based transitions are handled by the workflow module",
        Some(SourceTool::Bash),
        &mut state,
    );
    assert_eq!(issues.len(), 1);
    let issue = &issues[0];
    assert!(issue.fix_safety.is_fixable());
    assert!(issue.fix_target.is_none());
    assert!(
        issue
            .fix_hint
            .as_deref()
            .is_some_and(|hint| hint.contains("workflow module"))
    );
}

#[test]
fn detects_stale_state_machine_zero_transitions() {
    let mut state = make_state();
    let issues = check_text_for_issues(
        10,
        MessageRole::User,
        r#"suite-run-state.json: {"transition_count": 0, "phase": "running"} - 21 groups passed"#,
        Some(SourceTool::Bash),
        &mut state,
    );
    assert!(
        issues
            .iter()
            .any(|i| i.category == IssueCategory::WorkflowError
                && i.severity == IssueSeverity::Critical
                && i.summary.contains("never advanced"))
    );
}

#[test]
fn detects_stale_state_machine_bootstrap_phase() {
    let mut state = make_state();
    let issues = check_text_for_issues(
        10,
        MessageRole::User,
        r#"suite-run-state.json shows "phase": "bootstrap" but 15 groups have passed"#,
        Some(SourceTool::Bash),
        &mut state,
    );
    assert!(issues.iter().any(
        |i| i.category == IssueCategory::WorkflowError && i.summary.contains("never advanced")
    ));
}

#[test]
fn stale_state_machine_deduplicates() {
    let mut state = make_state();
    let first = check_text_for_issues(
        10,
        MessageRole::User,
        r#"suite-run-state.json: {"transition_count": 0} - groups passed"#,
        Some(SourceTool::Bash),
        &mut state,
    );
    let second = check_text_for_issues(
        11,
        MessageRole::User,
        r#"suite-run-state.json: {"transition_count": 0} - more groups passed"#,
        Some(SourceTool::Bash),
        &mut state,
    );
    assert_eq!(first.len(), 1);
    assert!(second.is_empty());
}

#[test]
fn skips_stale_state_without_group_evidence() {
    let mut state = make_state();
    let issues = check_text_for_issues(
        10,
        MessageRole::User,
        r#"suite-run-state.json: {"transition_count": 0, "phase": "bootstrap"}"#,
        Some(SourceTool::Bash),
        &mut state,
    );
    assert!(!issues.iter().any(|i| i.summary.contains("never advanced")));
}

#[test]
fn skips_stale_state_without_bash_source() {
    let mut state = make_state();
    let issues = check_text_for_issues(
        10,
        MessageRole::User,
        r#"suite-run-state.json: {"transition_count": 0} - groups passed"#,
        None,
        &mut state,
    );
    assert!(!issues.iter().any(|i| i.summary.contains("never advanced")));
}

#[test]
fn stale_state_machine_output_shape() {
    let mut state = make_state();
    let issues = check_text_for_issues(
        10,
        MessageRole::User,
        r#"suite-run-state.json: {"transition_count": 0} - 21 groups passed"#,
        Some(SourceTool::Bash),
        &mut state,
    );
    assert_eq!(issues.len(), 1);
    let issue = &issues[0];
    assert!(issue.fix_safety.is_fixable());
    assert!(issue.fix_target.is_none());
    assert!(
        issue
            .fix_hint
            .as_deref()
            .is_some_and(|hint| hint.contains("advance automatically"))
    );
}

#[test]
fn jq_error_output_shape() {
    let mut state = make_state();
    let issues = check_text_for_issues(
        10,
        MessageRole::User,
        "jq: error (at <stdin>:1): Cannot iterate over null (null)",
        Some(SourceTool::Bash),
        &mut state,
    );
    assert_eq!(issues.len(), 1);
    let issue = &issues[0];
    assert!(!issue.fix_safety.is_fixable());
    assert!(issue.fix_target.is_none());
    assert!(
        issue
            .fix_hint
            .as_deref()
            .is_some_and(|hint| hint.contains("valid JSON"))
    );
}
