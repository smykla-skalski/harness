use super::*;

#[test]
fn detects_harness_infrastructure_issue_phrase() {
    let mut state = make_state();
    let issues = check_text_for_issues(
        10,
        MessageRole::Assistant,
        "This is a harness infrastructure issue - the KDS port wasn't forwarded",
        None,
        &mut state,
    );
    assert!(
        issues
            .iter()
            .any(|i| i.category == IssueCategory::WorkflowError
                && i.severity == IssueSeverity::Critical
                && i.summary.contains("infrastructure misconfiguration"))
    );
}

#[test]
fn detects_harness_bug_phrase() {
    let mut state = make_state();
    let issues = check_text_for_issues(
        10,
        MessageRole::Assistant,
        "This looks like a harness bug in the multi-zone flow",
        None,
        &mut state,
    );
    assert!(issues.iter().any(
        |i| i.category == IssueCategory::WorkflowError && i.severity == IssueSeverity::Critical
    ));
}

#[test]
fn detects_harness_bootstrap_didnt_configure() {
    let mut state = make_state();
    let issues = check_text_for_issues(
        10,
        MessageRole::Assistant,
        "The harness bootstrap didn't configure KDS connections between zones",
        None,
        &mut state,
    );
    assert!(issues.iter().any(
        |i| i.category == IssueCategory::WorkflowError && i.severity == IssueSeverity::Critical
    ));
}

#[test]
fn detects_harness_cluster_missing() {
    let mut state = make_state();
    let issues = check_text_for_issues(
        10,
        MessageRole::Assistant,
        "The harness setup kuma cluster command is missing the zone-to-global link setup",
        None,
        &mut state,
    );
    assert!(issues.iter().any(
        |i| i.category == IssueCategory::WorkflowError && i.severity == IssueSeverity::Critical
    ));
}

#[test]
fn detects_harness_setup_failed() {
    let mut state = make_state();
    let issues = check_text_for_issues(
        10,
        MessageRole::Assistant,
        "The harness setup failed to register the zone control plane",
        None,
        &mut state,
    );
    assert!(issues.iter().any(
        |i| i.category == IssueCategory::WorkflowError && i.severity == IssueSeverity::Critical
    ));
}

#[test]
fn skips_harness_infrastructure_from_user_role() {
    let mut state = make_state();
    let issues = check_text_for_issues(
        10,
        MessageRole::User,
        "This is a harness infrastructure issue",
        None,
        &mut state,
    );
    assert!(
        !issues
            .iter()
            .any(|i| i.summary.contains("infrastructure misconfiguration"))
    );
}

#[test]
fn skips_harness_infrastructure_from_bash_tool() {
    let mut state = make_state();
    let issues = check_text_for_issues(
        10,
        MessageRole::Assistant,
        "This is a harness infrastructure issue",
        Some(SourceTool::Bash),
        &mut state,
    );
    assert!(
        !issues
            .iter()
            .any(|i| i.summary.contains("infrastructure misconfiguration"))
    );
}

#[test]
fn detects_missing_kuma_multizone_env_var() {
    let mut state = make_state();
    let issues = check_text_for_issues(
        10,
        MessageRole::Assistant,
        "The bootstrap is missing the KUMA_MULTIZONE environment variable",
        None,
        &mut state,
    );
    assert!(
        issues
            .iter()
            .any(|i| i.category == IssueCategory::DataIntegrity
                && i.severity == IssueSeverity::Medium
                && i.summary.contains("Missing configuration"))
    );
}

#[test]
fn detects_lacking_kubeconfig() {
    let mut state = make_state();
    let issues = check_text_for_issues(
        10,
        MessageRole::Assistant,
        "The zone cluster lacks the KUBECONFIG needed to reach the global CP",
        None,
        &mut state,
    );
    assert!(
        issues
            .iter()
            .any(|i| i.category == IssueCategory::DataIntegrity
                && i.severity == IssueSeverity::Medium)
    );
}

#[test]
fn detects_kds_connection_not_established() {
    let mut state = make_state();
    let issues = check_text_for_issues(
        10,
        MessageRole::Assistant,
        "The KDS connection between global and zone was not established",
        None,
        &mut state,
    );
    assert!(
        issues
            .iter()
            .any(|i| i.category == IssueCategory::DataIntegrity
                && i.severity == IssueSeverity::Medium)
    );
}

#[test]
fn skips_missing_env_var_from_user_role() {
    let mut state = make_state();
    let issues = check_text_for_issues(
        10,
        MessageRole::User,
        "The bootstrap is missing the KUMA_MULTIZONE env var",
        None,
        &mut state,
    );
    assert!(
        !issues
            .iter()
            .any(|i| i.summary.contains("Missing configuration"))
    );
}

#[test]
fn harness_infrastructure_deduplicates() {
    let mut state = make_state();
    let first = check_text_for_issues(
        10,
        MessageRole::Assistant,
        "This is a harness infrastructure issue with KDS",
        None,
        &mut state,
    );
    let second = check_text_for_issues(
        11,
        MessageRole::Assistant,
        "Confirmed this is a harness bug",
        None,
        &mut state,
    );
    assert_eq!(first.len(), 1);
    assert!(second.is_empty());
}

#[test]
fn harness_infrastructure_output_shape() {
    let mut state = make_state();
    let issues = check_text_for_issues(
        10,
        MessageRole::Assistant,
        "This is a harness infrastructure issue - KDS wasn't configured",
        None,
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
            .is_some_and(|hint| hint.contains("bootstrap/cluster"))
    );
}

#[test]
fn missing_connection_output_shape() {
    let mut state = make_state();
    let issues = check_text_for_issues(
        10,
        MessageRole::Assistant,
        "The KDS connection was not established between zones",
        None,
        &mut state,
    );
    assert_eq!(issues.len(), 1);
    let issue = &issues[0];
    assert!(!issue.fix_safety.is_fixable());
    assert!(
        issue
            .fix_hint
            .as_deref()
            .is_some_and(|hint| hint.contains("investigate"))
    );
}

#[test]
fn text_check_output_shape_is_preserved() {
    let mut state = make_state();
    let issues = check_text_for_issues(
        10,
        MessageRole::User,
        "CLAUDE_SESSION_ID=unset",
        Some(SourceTool::Bash),
        &mut state,
    );
    assert_eq!(issues.len(), 1);
    let issue = &issues[0];
    assert_remediation_fields(
        issue,
        true,
        Some("src/context.rs"),
        Some("context directory"),
    );

    let rendered = output::render_json(issue);
    let parsed: serde_json::Value = serde_json::from_str(&rendered).unwrap();
    assert_rule_rendered_target(&parsed, Some("src/context.rs"));
    assert_rule_rendered_classification(&parsed);
    assert!(
        parsed["remediation"]["hint"]
            .as_str()
            .unwrap()
            .contains("context directory")
    );
}

#[test]
fn tool_check_output_shape_is_preserved() {
    let mut state = make_state();
    let block = bash_tool_use("rm -rf tmp/output");
    let issues = check_tool_use_for_issues(10, &block, &mut state);
    assert_eq!(issues.len(), 1);
    let issue = &issues[0];
    assert_remediation_fields(issue, false, None, Some("verify target"));

    let rendered = output::render_json(issue);
    let parsed: serde_json::Value = serde_json::from_str(&rendered).unwrap();
    assert_rule_rendered_target(&parsed, None);
    assert_rule_rendered_classification(&parsed);
    assert!(
        parsed["remediation"]["hint"]
            .as_str()
            .unwrap()
            .contains("verify target")
    );
    assert!(parsed["classification"].get("code").is_some());
}
