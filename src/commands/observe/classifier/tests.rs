use super::*;
use crate::commands::observe::output;
use crate::commands::observe::types::{
    IssueCategory, IssueSeverity, MessageRole, ScanState, SourceTool,
};

fn make_state() -> ScanState {
    ScanState::default()
}

#[test]
fn detects_hook_denial() {
    let mut state = make_state();
    let issues = check_text_for_issues(
        10,
        MessageRole::User,
        "The system denied this tool call because it violates policy",
        None,
        &mut state,
    );
    assert_eq!(issues.len(), 1);
    assert_eq!(issues[0].category, IssueCategory::HookFailure);
}

#[test]
fn detects_ksa_code_in_bash() {
    let mut state = make_state();
    let issues = check_text_for_issues(
        20,
        MessageRole::User,
        "ERROR [KSA001] Write path is outside the suite:new surface",
        Some(SourceTool::Bash),
        &mut state,
    );
    assert!(
        issues
            .iter()
            .any(|i| i.category == IssueCategory::HookFailure)
    );
}

#[test]
fn skips_ksa_code_not_bash() {
    let mut state = make_state();
    let issues = check_text_for_issues(
        20,
        MessageRole::User,
        "ERROR [KSA001] Write path is outside",
        None,
        &mut state,
    );
    assert!(!issues.iter().any(|i| i.summary.contains("KSA001")));
}

#[test]
fn detects_cli_error() {
    let mut state = make_state();
    let issues = check_text_for_issues(
        30,
        MessageRole::User,
        "harness: error: unrecognized arguments --bad-flag",
        Some(SourceTool::Bash),
        &mut state,
    );
    assert!(issues.iter().any(|i| i.category == IssueCategory::CliError));
}

#[test]
fn detects_tool_error() {
    let mut state = make_state();
    let issues = check_text_for_issues(
        40,
        MessageRole::User,
        "Error: file has not been read yet. Read the file first.",
        None,
        &mut state,
    );
    assert!(
        issues
            .iter()
            .any(|i| i.category == IssueCategory::ToolError)
    );
}

#[test]
fn detects_build_error() {
    let mut state = make_state();
    let issues = check_text_for_issues(
        50,
        MessageRole::User,
        "error[E0308]: mismatched types\n  expected u32, found &str",
        Some(SourceTool::Bash),
        &mut state,
    );
    assert!(
        issues
            .iter()
            .any(|i| i.category == IssueCategory::BuildError)
    );
}

#[test]
fn detects_user_frustration() {
    let mut state = make_state();
    let issues = check_text_for_issues(
        60,
        MessageRole::User,
        "stop guessing and read it again!",
        None,
        &mut state,
    );
    assert!(
        issues
            .iter()
            .any(|i| i.category == IssueCategory::UserFrustration)
    );
}

#[test]
fn skips_file_content() {
    let mut state = make_state();
    let text =
        "     1\u{2192}fn main() {\n     2\u{2192}    println!(\"error[E0308]\");\n     3\u{2192}}";
    let issues = check_text_for_issues(70, MessageRole::User, text, None, &mut state);
    assert!(issues.is_empty());
}

#[test]
fn skips_help_output() {
    let mut state = make_state();
    let issues = check_text_for_issues(
        80,
        MessageRole::User,
        "Kuma test harness\n\nUsage: harness [COMMAND]",
        Some(SourceTool::Bash),
        &mut state,
    );
    assert!(issues.is_empty());
}

#[test]
fn skips_compaction_summary() {
    let mut state = make_state();
    let issues = check_text_for_issues(
        90,
        MessageRole::User,
        "This session is being continued from a previous conversation. Here is context.",
        None,
        &mut state,
    );
    assert!(issues.is_empty());
}

#[test]
fn detects_auth_flow() {
    let mut state = make_state();
    let issues = check_text_for_issues(
        100,
        MessageRole::User,
        "Opening browser for authentication to your cluster",
        Some(SourceTool::Bash),
        &mut state,
    );
    assert!(
        issues
            .iter()
            .any(|i| i.category == IssueCategory::UnexpectedBehavior)
    );
}

#[test]
fn detects_old_skill_name_in_bash() {
    let mut state = make_state();
    let block = serde_json::json!({
        "type": "tool_use",
        "id": "t1",
        "name": "Bash",
        "input": { "command": "harness hook --skill suite-runner guard-bash" }
    });
    let issues = check_tool_use_for_issues(10, &block, &mut state);
    assert!(
        issues
            .iter()
            .any(|i| i.category == IssueCategory::NamingError)
    );
}

#[test]
fn tracks_tool_use_for_correlation() {
    let mut state = make_state();
    let block = serde_json::json!({
        "type": "tool_use",
        "id": "tool_abc",
        "name": "Bash",
        "input": { "command": "ls" }
    });
    check_tool_use_for_issues(10, &block, &mut state);
    assert!(state.last_tool_uses.contains_key("tool_abc"));
    assert_eq!(state.last_tool_uses["tool_abc"].name, "Bash");
}

#[test]
fn detects_file_churn() {
    let mut state = make_state();
    let block = serde_json::json!({
        "type": "tool_use",
        "id": "t1",
        "name": "Edit",
        "input": { "file_path": "test.rs", "old_string": "a", "new_string": "b" }
    });
    for _ in 0..9 {
        let issues = check_tool_use_for_issues(10, &block, &mut state);
        assert!(issues.is_empty());
    }
    let issues = check_tool_use_for_issues(10, &block, &mut state);
    assert_eq!(issues.len(), 1);
    assert!(issues[0].summary.contains("10 times"));
}

#[test]
fn classify_line_parses_text_block() {
    let mut state = make_state();
    let line = serde_json::json!({
        "timestamp": "2025-01-01T00:00:00Z",
        "message": {
            "role": "user",
            "content": [{ "type": "text", "text": "stop guessing!" }]
        }
    });
    let issues = classify_line(0, &serde_json::to_string(&line).unwrap(), &mut state);
    assert!(!issues.is_empty());
    assert_eq!(
        state.session_start_timestamp.as_deref(),
        Some("2025-01-01T00:00:00Z")
    );
}

#[test]
fn classify_line_skips_invalid_json() {
    let mut state = make_state();
    let issues = classify_line(0, "not json at all", &mut state);
    assert!(issues.is_empty());
}

#[test]
fn classify_line_deduplicates() {
    let mut state = make_state();
    let line = serde_json::json!({
        "message": {
            "role": "user",
            "content": [{ "type": "text", "text": "stop guessing!" }]
        }
    });
    let raw = serde_json::to_string(&line).unwrap();
    let first = classify_line(0, &raw, &mut state);
    let second = classify_line(1, &raw, &mut state);
    assert!(!first.is_empty());
    assert!(second.is_empty(), "duplicate should be filtered");
}

#[test]
fn classify_line_correlates_tool_result() {
    let mut state = make_state();
    let tool_use_line = serde_json::json!({
        "message": {
            "role": "assistant",
            "content": [{
                "type": "tool_use",
                "id": "tool_123",
                "name": "Bash",
                "input": { "command": "cargo build" }
            }]
        }
    });
    classify_line(
        0,
        &serde_json::to_string(&tool_use_line).unwrap(),
        &mut state,
    );

    let tool_result_line = serde_json::json!({
        "message": {
            "role": "user",
            "content": [{
                "type": "tool_result",
                "tool_use_id": "tool_123",
                "content": [{ "type": "text", "text": "error[E0308]: mismatched types" }]
            }]
        }
    });
    let issues = classify_line(
        1,
        &serde_json::to_string(&tool_result_line).unwrap(),
        &mut state,
    );
    assert!(
        issues
            .iter()
            .any(|i| i.category == IssueCategory::BuildError)
    );
}

#[test]
fn classify_line_string_content() {
    let mut state = make_state();
    let line = serde_json::json!({
        "message": {
            "role": "user",
            "content": "stop guessing and read it again!"
        }
    });
    let issues = classify_line(0, &serde_json::to_string(&line).unwrap(), &mut state);
    assert!(!issues.is_empty());
}

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
    let block = serde_json::json!({
        "type": "tool_use",
        "id": "t1",
        "name": "Bash",
        "input": { "command": "K3D_HELM_DEPLOY_NO_CNI=true KIND_CLUSTER_NAME=kuma-1 make k3d/deploy/helm" }
    });
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
    let block = serde_json::json!({
        "type": "tool_use",
        "id": "t1",
        "name": "Bash",
        "input": { "command": "make kind/create" }
    });
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
    let block = serde_json::json!({
        "type": "tool_use",
        "id": "t1",
        "name": "Bash",
        "input": { "command": "git add src/xds.go && git commit -sS -m \"fix(xds): correct route\"" }
    });
    let issues = check_tool_use_for_issues(10, &block, &mut state);
    assert!(
        issues
            .iter()
            .any(|i| i.category == IssueCategory::UnexpectedBehavior
                && i.severity == IssueSeverity::Critical
                && i.summary.contains("git commit"))
    );
}

#[test]
fn detects_git_add_alone() {
    let mut state = make_state();
    let block = serde_json::json!({
        "type": "tool_use",
        "id": "t1",
        "name": "Bash",
        "input": { "command": "git add -A" }
    });
    let issues = check_tool_use_for_issues(10, &block, &mut state);
    assert!(
        issues
            .iter()
            .any(|i| i.category == IssueCategory::UnexpectedBehavior
                && i.severity == IssueSeverity::Critical)
    );
}

#[test]
fn detects_kubeconfig_env_prefix() {
    let mut state = make_state();
    let block = serde_json::json!({
        "type": "tool_use",
        "id": "t1",
        "name": "Bash",
        "input": { "command": "KUBECONFIG=/path/to/config kubectl wait --for=condition=Ready pods" }
    });
    let issues = check_tool_use_for_issues(10, &block, &mut state);
    assert!(issues.iter().any(
        |i| i.category == IssueCategory::UnexpectedBehavior && i.summary.contains("KUBECONFIG")
    ));
}

#[test]
fn detects_export_env_var() {
    let mut state = make_state();
    let block = serde_json::json!({
        "type": "tool_use",
        "id": "t1",
        "name": "Bash",
        "input": { "command": "export KUBECONFIG=/tmp/k3d-kubeconfig.yaml" }
    });
    let issues = check_tool_use_for_issues(10, &block, &mut state);
    assert!(issues.iter().any(
        |i| i.category == IssueCategory::UnexpectedBehavior && i.summary.contains("KUBECONFIG")
    ));
}

#[test]
fn detects_generic_env_prefix() {
    let mut state = make_state();
    let block = serde_json::json!({
        "type": "tool_use",
        "id": "t1",
        "name": "Bash",
        "input": { "command": "K3D_HELM_DEPLOY_NO_CNI=true helm install kuma" }
    });
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
    let block = serde_json::json!({
        "type": "tool_use",
        "id": "t1",
        "name": "Bash",
        "input": { "command": "ls -la /tmp" }
    });
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
        "ERROR [KSA001] Write path is outside the suite:new surface",
        Some(SourceTool::Bash),
        &mut state,
    );
    let second = check_text_for_issues(
        11,
        MessageRole::User,
        "ERROR [KSA001] Write path is outside the suite:new surface",
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
        "ERROR [KSA001] Write path is outside the suite:new surface",
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
    assert!(issue.fixable);
    assert_eq!(issue.fix_target.as_deref(), Some("cli.rs"));
    assert!(issue.fix_hint.is_none());

    let rendered = output::render_json(issue);
    let parsed: serde_json::Value = serde_json::from_str(&rendered).unwrap();
    assert_eq!(parsed["fixable"], true);
    assert_eq!(parsed["fix_target"], "cli.rs");
    assert!(parsed.get("code").is_none());
    assert!(parsed.get("fingerprint").is_none());
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
    assert!(issue.fixable);
    assert_eq!(issue.fix_target.as_deref(), Some("src/context.rs"));
    assert!(
        issue
            .fix_hint
            .as_deref()
            .is_some_and(|hint| hint.contains("context directory"))
    );

    let rendered = output::render_json(issue);
    let parsed: serde_json::Value = serde_json::from_str(&rendered).unwrap();
    assert_eq!(parsed["fixable"], true);
    assert_eq!(parsed["fix_target"], "src/context.rs");
    assert!(
        parsed["fix_hint"]
            .as_str()
            .unwrap()
            .contains("context directory")
    );
    assert!(parsed.get("code").is_none());
}

#[test]
fn tool_check_output_shape_is_preserved() {
    let mut state = make_state();
    let block = serde_json::json!({
        "type": "tool_use",
        "id": "t1",
        "name": "Bash",
        "input": { "command": "rm -rf tmp/output" }
    });
    let issues = check_tool_use_for_issues(10, &block, &mut state);
    assert_eq!(issues.len(), 1);
    let issue = &issues[0];
    assert!(!issue.fixable);
    assert!(issue.fix_target.is_none());
    assert!(
        issue
            .fix_hint
            .as_deref()
            .is_some_and(|hint| hint.contains("verify target"))
    );

    let rendered = output::render_json(issue);
    let parsed: serde_json::Value = serde_json::from_str(&rendered).unwrap();
    assert_eq!(parsed["fixable"], false);
    assert!(parsed.get("fix_target").is_none());
    assert!(
        parsed["fix_hint"]
            .as_str()
            .unwrap()
            .contains("verify target")
    );
    assert!(parsed.get("code").is_none());
}
