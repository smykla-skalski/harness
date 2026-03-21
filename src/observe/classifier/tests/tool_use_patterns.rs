use super::*;

#[test]
fn build_error_skipped_when_cli_error_matched() {
    let mut state = make_state();
    let issues = check_text_for_issues(
        10,
        MessageRole::User,
        "harness: error: unresolved import cannot find value",
        Some(SourceTool::Bash),
        &mut state,
    );
    assert!(issues.iter().any(|i| i.category == IssueCategory::CliError));
    assert!(
        !issues
            .iter()
            .any(|i| i.category == IssueCategory::BuildError)
    );
}

#[test]
fn env_misconfiguration_uses_pattern_array() {
    let mut state = make_state();
    let issues = check_text_for_issues(
        10,
        MessageRole::User,
        "CLAUDE_SESSION_ID=unset",
        Some(SourceTool::Bash),
        &mut state,
    );
    assert!(
        issues
            .iter()
            .any(|i| i.category == IssueCategory::DataIntegrity)
    );
}

#[test]
fn details_truncated_at_construction() {
    let mut state = make_state();
    let long_text = "x".repeat(5000);
    let input = format!("harness: error: {long_text}");
    let issues = check_text_for_issues(
        10,
        MessageRole::User,
        &input,
        Some(SourceTool::Bash),
        &mut state,
    );
    assert!(!issues.is_empty());
    assert!(issues[0].details.len() <= 2001);
}

#[test]
fn detects_raw_make_k3d_target() {
    let mut state = make_state();
    let block =
        bash_tool_use("K3D_HELM_DEPLOY_NO_CNI=true KIND_CLUSTER_NAME=kuma-1 make k3d/deploy/helm");
    let issues = check_tool_use_for_issues(10, &block, &mut state);
    assert!(
        issues
            .iter()
            .any(|i| i.category == IssueCategory::UnexpectedBehavior
                && i.severity == IssueSeverity::Critical
                && i.summary.contains("make target"))
    );
}

#[test]
fn detects_raw_make_kind_target() {
    let mut state = make_state();
    let block = bash_tool_use("make kind/create");
    let issues = check_tool_use_for_issues(10, &block, &mut state);
    assert!(
        issues
            .iter()
            .any(|i| i.category == IssueCategory::UnexpectedBehavior
                && i.severity == IssueSeverity::Critical)
    );
}

#[test]
fn detects_git_commit_during_run() {
    let mut state = make_state();
    let block =
        bash_tool_use("git add src/xds.go && git commit -sS -m \"fix(xds): correct route\"");
    let issues = check_tool_use_for_issues(10, &block, &mut state);
    assert!(
        issues
            .iter()
            .any(|i| i.category == IssueCategory::SkillBehavior
                && i.severity == IssueSeverity::Low
                && i.summary.contains("Git commit during active run"))
    );
}

#[test]
fn detects_git_add_alone() {
    let mut state = make_state();
    let block = bash_tool_use("git add -A");
    let issues = check_tool_use_for_issues(10, &block, &mut state);
    assert!(
        issues
            .iter()
            .any(|i| i.category == IssueCategory::SkillBehavior
                && i.severity == IssueSeverity::Low)
    );
}

#[test]
fn detects_kubeconfig_env_prefix() {
    let mut state = make_state();
    let block = bash_tool_use("KUBECONFIG=/path/to/config kubectl wait --for=condition=Ready pods");
    let issues = check_tool_use_for_issues(10, &block, &mut state);
    assert!(issues.iter().any(
        |i| i.category == IssueCategory::UnexpectedBehavior && i.summary.contains("KUBECONFIG")
    ));
}

#[test]
fn detects_export_env_var() {
    let mut state = make_state();
    let block = bash_tool_use("export KUBECONFIG=/tmp/k3d-kubeconfig.yaml");
    let issues = check_tool_use_for_issues(10, &block, &mut state);
    assert!(issues.iter().any(
        |i| i.category == IssueCategory::UnexpectedBehavior && i.summary.contains("KUBECONFIG")
    ));
}

#[test]
fn detects_generic_env_prefix() {
    let mut state = make_state();
    let block = bash_tool_use("K3D_HELM_DEPLOY_NO_CNI=true helm install kuma");
    let issues = check_tool_use_for_issues(10, &block, &mut state);
    assert!(
        issues
            .iter()
            .any(|i| i.category == IssueCategory::UnexpectedBehavior
                && i.summary.contains("env var"))
    );
}

#[test]
fn skips_env_detection_for_plain_commands() {
    let mut state = make_state();
    let block = bash_tool_use("ls -la /tmp");
    let issues = check_tool_use_for_issues(10, &block, &mut state);
    assert!(
        !issues
            .iter()
            .any(|i| i.summary.contains("env var") || i.summary.contains("KUBECONFIG"))
    );
}

#[test]
fn rule_table_has_expected_count() {
    assert_eq!(rules::TEXT_RULES.len(), 15);
}

#[test]
fn deduplicates_same_ksa_code_across_repeats() {
    let mut state = make_state();
    let first = check_text_for_issues(
        10,
        MessageRole::User,
        "ERROR [KSA001] Write path is outside the suite:create surface",
        Some(SourceTool::Bash),
        &mut state,
    );
    let second = check_text_for_issues(
        11,
        MessageRole::User,
        "ERROR [KSA001] Write path is outside the suite:create surface",
        Some(SourceTool::Bash),
        &mut state,
    );
    assert_eq!(first.len(), 1);
    assert!(second.is_empty());
}

#[test]
fn keeps_distinct_ksa_codes_separate() {
    let mut state = make_state();
    let first = check_text_for_issues(
        10,
        MessageRole::User,
        "ERROR [KSA001] Write path is outside the suite:create surface",
        Some(SourceTool::Bash),
        &mut state,
    );
    let second = check_text_for_issues(
        11,
        MessageRole::User,
        "ERROR [KSA002] Guard question denied an invalid prompt",
        Some(SourceTool::Bash),
        &mut state,
    );
    assert_eq!(first.len(), 1);
    assert_eq!(second.len(), 1);
    assert!(second[0].summary.contains("KSA002"));
}

#[test]
fn manifest_runtime_failure_dedups_across_exit_codes() {
    let mut state = make_state();
    let first = check_text_for_issues(
        10,
        MessageRole::User,
        "harness apply failed with exit code 2",
        Some(SourceTool::Bash),
        &mut state,
    );
    let second = check_text_for_issues(
        11,
        MessageRole::User,
        "harness apply failed with exit code 137",
        Some(SourceTool::Bash),
        &mut state,
    );
    assert_eq!(first.len(), 1);
    assert!(second.is_empty());
}

#[test]
fn permission_failures_dedup_per_agent() {
    let mut state = make_state();
    let first = check_text_for_issues(
        10,
        MessageRole::User,
        "Agent \"alpha\" says I need Bash permission to continue",
        None,
        &mut state,
    );
    let second = check_text_for_issues(
        11,
        MessageRole::User,
        "Agent \"alpha\" says I need Bash permission to continue",
        None,
        &mut state,
    );
    let third = check_text_for_issues(
        12,
        MessageRole::User,
        "Agent \"beta\" says I need Bash permission to continue",
        None,
        &mut state,
    );
    assert_eq!(first.len(), 1);
    assert!(second.is_empty());
    assert_eq!(third.len(), 1);
    assert!(third[0].summary.contains("beta"));
}

#[test]
fn rule_output_shape_is_preserved() {
    let mut state = make_state();
    let issues = check_text_for_issues(
        10,
        MessageRole::User,
        "harness: error: unrecognized arguments --bad-flag",
        Some(SourceTool::Bash),
        &mut state,
    );
    assert_eq!(issues.len(), 1);
    let issue = &issues[0];
    assert_remediation_fields(issue, true, Some("src/cli.rs"), None);

    let rendered = output::render_json(issue);
    let parsed: serde_json::Value = serde_json::from_str(&rendered).unwrap();
    assert_rule_rendered_target(&parsed, Some("src/cli.rs"));
    assert_rule_rendered_classification(&parsed);
    assert!(parsed["id"].is_string());
}

#[test]
fn detects_direct_task_output_cat() {
    let mut state = make_state();
    let block = bash_tool_use("cat /private/tmp/claude-501/session-abc/tasks/task_123.output");
    let issues = check_tool_use_for_issues(10, &block, &mut state);
    assert!(
        issues
            .iter()
            .any(|i| i.category == IssueCategory::UnexpectedBehavior
                && i.severity == IssueSeverity::Medium
                && i.summary.contains("task output"))
    );
}

#[test]
fn detects_task_output_polling_pattern() {
    let mut state = make_state();
    let block = bash_tool_use("sleep 2 && cat /tmp/tasks/result.output");
    let issues = check_tool_use_for_issues(10, &block, &mut state);
    assert!(
        issues
            .iter()
            .any(|i| i.category == IssueCategory::UnexpectedBehavior
                && i.summary.contains("task output"))
    );
}

#[test]
fn skips_task_output_for_unrelated_paths() {
    let mut state = make_state();
    let block = bash_tool_use("cat /tmp/my-project/output.log");
    let issues = check_tool_use_for_issues(10, &block, &mut state);
    assert!(!issues.iter().any(|i| i.summary.contains("task output")));
}
