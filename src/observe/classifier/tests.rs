#![allow(clippy::cognitive_complexity)]

use super::*;
use crate::observe::output;
use crate::observe::types::{
    Confidence, FixSafety, FocusPreset, IssueCategory, IssueCode, IssueSeverity, MessageRole,
    ScanState, SourceTool, ToolUseRecord,
};

fn make_state() -> ScanState {
    ScanState::default()
}

fn bash_tool_use(command: &str) -> serde_json::Value {
    serde_json::json!({
        "type": "tool_use",
        "id": "t1",
        "name": "Bash",
        "input": { "command": command }
    })
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
    let block = bash_tool_use("harness hook --skill suite-runner guard-bash");
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
        "input": { "file_path": "test.txt", "old_string": "a", "new_string": "b" }
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
    assert!(issue.fix_safety.is_fixable());
    assert_eq!(issue.fix_target.as_deref(), Some("src/cli.rs"));
    assert!(issue.fix_hint.is_none());

    let rendered = output::render_json(issue);
    let parsed: serde_json::Value = serde_json::from_str(&rendered).unwrap();
    assert_eq!(parsed["fixable"], true);
    assert_eq!(parsed["fix_target"], "src/cli.rs");
    assert!(parsed.get("code").is_some());
    assert!(parsed.get("fingerprint").is_some());
    assert!(parsed.get("issue_id").is_some());
    assert!(parsed.get("confidence").is_some());
    assert!(parsed.get("fix_safety").is_some());
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
        "The harness cluster command is missing the zone-to-global link setup",
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
    assert!(issue.fix_safety.is_fixable());
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
    assert!(parsed.get("code").is_some());
}

#[test]
fn tool_check_output_shape_is_preserved() {
    let mut state = make_state();
    let block = bash_tool_use("rm -rf tmp/output");
    let issues = check_tool_use_for_issues(10, &block, &mut state);
    assert_eq!(issues.len(), 1);
    let issue = &issues[0];
    assert!(!issue.fix_safety.is_fixable());
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
    assert!(parsed.get("code").is_some());
}

#[test]
fn detects_absolute_manifest_path() {
    let mut state = make_state();
    let block = bash_tool_use(
        "harness apply --manifest /Users/someone/.local/share/kuma/suites/motb/groups/g13/01.yaml",
    );
    let issues = check_tool_use_for_issues(10, &block, &mut state);
    assert!(
        issues
            .iter()
            .any(|i| i.category == IssueCategory::UnexpectedBehavior
                && i.severity == IssueSeverity::Medium
                && i.summary.contains("Absolute path"))
    );
}

#[test]
fn detects_absolute_manifest_path_with_multiple_flags() {
    let mut state = make_state();
    let block = bash_tool_use(
        "harness apply --manifest /tmp/groups/g02/04.yaml --manifest /tmp/groups/g02/05.yaml",
    );
    let issues = check_tool_use_for_issues(10, &block, &mut state);
    assert!(issues.iter().any(|i| i.summary.contains("Absolute path")));
}

#[test]
fn skips_relative_manifest_path() {
    let mut state = make_state();
    let block = bash_tool_use("harness apply --manifest g13/01.yaml");
    let issues = check_tool_use_for_issues(10, &block, &mut state);
    assert!(!issues.iter().any(|i| i.summary.contains("Absolute path")));
}

#[test]
fn skips_absolute_path_detection_for_non_apply_commands() {
    let mut state = make_state();
    let block = bash_tool_use("harness run --label test kubectl get pods");
    let issues = check_tool_use_for_issues(10, &block, &mut state);
    assert!(!issues.iter().any(|i| i.summary.contains("Absolute path")));
}

#[test]
fn absolute_manifest_path_output_shape() {
    let mut state = make_state();
    let block = bash_tool_use("harness apply --manifest /full/path/to/g13/01.yaml");
    let issues = check_tool_use_for_issues(10, &block, &mut state);
    assert_eq!(issues.len(), 1);
    let issue = &issues[0];
    assert!(issue.fix_safety.is_fixable());
    assert!(issue.fix_target.is_none());
    assert!(
        issue
            .fix_hint
            .as_deref()
            .is_some_and(|hint| hint.contains("relative manifest paths"))
    );
}

#[test]
fn detects_sleep_and_ampersand_harness() {
    let mut state = make_state();
    let block = bash_tool_use("sleep 8 && harness apply --manifest g13/01.yaml");
    let issues = check_tool_use_for_issues(10, &block, &mut state);
    assert!(
        issues
            .iter()
            .any(|i| i.category == IssueCategory::UnexpectedBehavior
                && i.severity == IssueSeverity::Low
                && i.summary.contains("Sleep prefix"))
    );
}

#[test]
fn detects_sleep_and_semicolon_harness() {
    let mut state = make_state();
    let block = bash_tool_use("sleep 5; harness record --label test -- kubectl get pods");
    let issues = check_tool_use_for_issues(10, &block, &mut state);
    assert!(
        issues
            .iter()
            .any(|i| i.category == IssueCategory::UnexpectedBehavior
                && i.severity == IssueSeverity::Low
                && i.summary.contains("Sleep prefix"))
    );
}

#[test]
fn skips_sleep_without_harness_continuation() {
    let mut state = make_state();
    let block = bash_tool_use("sleep 5 && echo done");
    let issues = check_tool_use_for_issues(10, &block, &mut state);
    assert!(!issues.iter().any(|i| i.summary.contains("Sleep prefix")));
}

#[test]
fn sleep_prefix_output_shape() {
    let mut state = make_state();
    let block = bash_tool_use("sleep 10 && harness capture --label post-apply");
    let issues = check_tool_use_for_issues(10, &block, &mut state);
    assert_eq!(issues.len(), 1);
    let issue = &issues[0];
    assert!(issue.fix_safety.is_fixable());
    assert!(issue.fix_target.is_none());
    assert!(
        issue
            .fix_hint
            .as_deref()
            .is_some_and(|hint| hint.contains("--delay"))
    );
}

#[test]
fn detects_manifest_created_in_manifests_directory() {
    let mut state = make_state();
    let block = serde_json::json!({
        "type": "tool_use",
        "id": "t1",
        "name": "Write",
        "input": {
            "file_path": "/home/user/.local/share/kuma/runs/20260315/manifests/containerpatch-otel-env.yaml",
            "content": "apiVersion: kuma.io/v1alpha1\nkind: ContainerPatch"
        }
    });
    let issues = check_tool_use_for_issues(10, &block, &mut state);
    assert!(
        issues
            .iter()
            .any(|i| i.category == IssueCategory::SkillBehavior
                && i.severity == IssueSeverity::Critical
                && i.summary.contains("Manifest created during run"))
    );
}

#[test]
fn detects_manifest_yml_extension_in_manifests_directory() {
    let mut state = make_state();
    let block = serde_json::json!({
        "type": "tool_use",
        "id": "t1",
        "name": "Edit",
        "input": {
            "file_path": "/data/suites/motb/manifests/policy.yml",
            "old_string": "old",
            "new_string": "new"
        }
    });
    let issues = check_tool_use_for_issues(10, &block, &mut state);
    assert!(
        issues
            .iter()
            .any(|i| i.category == IssueCategory::SkillBehavior
                && i.summary.contains("Manifest created during run"))
    );
}

#[test]
fn skips_manifest_detection_for_non_yaml_files() {
    let mut state = make_state();
    let block = serde_json::json!({
        "type": "tool_use",
        "id": "t1",
        "name": "Write",
        "input": {
            "file_path": "/data/suites/motb/manifests/README.md",
            "content": "# Manifests"
        }
    });
    let issues = check_tool_use_for_issues(10, &block, &mut state);
    assert!(
        !issues
            .iter()
            .any(|i| i.summary.contains("Manifest created during run"))
    );
}

#[test]
fn skips_manifest_detection_outside_manifests_directory() {
    let mut state = make_state();
    let block = serde_json::json!({
        "type": "tool_use",
        "id": "t1",
        "name": "Write",
        "input": {
            "file_path": "/data/suites/motb/groups/g01/01-create.yaml",
            "content": "apiVersion: v1\nkind: ConfigMap"
        }
    });
    let issues = check_tool_use_for_issues(10, &block, &mut state);
    assert!(
        !issues
            .iter()
            .any(|i| i.summary.contains("Manifest created during run"))
    );
}

#[test]
fn manifest_created_during_run_output_shape() {
    let mut state = make_state();
    let block = serde_json::json!({
        "type": "tool_use",
        "id": "t1",
        "name": "Write",
        "input": {
            "file_path": "/data/runs/20260315/manifests/containerpatch.yaml",
            "content": "kind: ContainerPatch"
        }
    });
    let issues = check_tool_use_for_issues(10, &block, &mut state);
    assert_eq!(issues.len(), 1);
    let issue = &issues[0];
    assert!(!issue.fix_safety.is_fixable());
    assert_eq!(issue.fix_target.as_deref(), Some("skills/new/SKILL.md"));
    assert!(
        issue
            .fix_hint
            .as_deref()
            .is_some_and(|hint| hint.contains("suite:new"))
    );
}

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

// ─── Phase 7 tests ─────────────────────────────────────────────────

#[test]
fn skill_name_short_does_not_fire() {
    // Short names (new, run, observe) are the correct convention in SKILL.md
    let mut state = make_state();
    let block = serde_json::json!({
        "type": "tool_use",
        "id": "t1",
        "name": "Write",
        "input": {
            "file_path": "/data/.claude/skills/observe/SKILL.md",
            "content": "---\nname: observe\n---\nSome content"
        }
    });
    let issues = check_tool_use_for_issues(10, &block, &mut state);
    assert!(
        !issues
            .iter()
            .any(|i| i.code == IssueCode::ShortSkillNameInSkillFile),
        "short name 'observe' should not trigger ShortSkillNameInSkillFile"
    );
}

#[test]
fn skill_name_colon_prefixed_fires() {
    // Colon-prefixed names (suite:new) are wrong in SKILL.md files
    let mut state = make_state();
    let block = serde_json::json!({
        "type": "tool_use",
        "id": "t1",
        "name": "Write",
        "input": {
            "file_path": "/data/.claude/skills/new/SKILL.md",
            "content": "---\nname: suite:new\n---\nSome content"
        }
    });
    let issues = check_tool_use_for_issues(10, &block, &mut state);
    assert!(
        issues
            .iter()
            .any(|i| i.code == IssueCode::ShortSkillNameInSkillFile),
        "colon-prefixed 'suite:new' should trigger ShortSkillNameInSkillFile"
    );
    let issue = issues
        .iter()
        .find(|i| i.code == IssueCode::ShortSkillNameInSkillFile)
        .unwrap();
    assert!(issue.summary.contains("suite:new"));
}

#[test]
fn golden_json_output_all_fields() {
    // Construct issue with all fields, verify render_json includes everything
    let mut state = make_state();
    let issues = check_text_for_issues(
        42,
        MessageRole::User,
        "error[E0308]: mismatched types\n  expected u32, found &str",
        Some(SourceTool::Bash),
        &mut state,
    );
    assert!(!issues.is_empty());
    let issue = &issues[0];
    let rendered = output::render_json(issue);
    let parsed: serde_json::Value = serde_json::from_str(&rendered).unwrap();

    // All required fields present
    assert!(parsed.get("issue_id").is_some());
    assert!(parsed.get("line").is_some());
    assert!(parsed.get("code").is_some());
    assert!(parsed.get("category").is_some());
    assert!(parsed.get("severity").is_some());
    assert!(parsed.get("confidence").is_some());
    assert!(parsed.get("fix_safety").is_some());
    assert!(parsed.get("summary").is_some());
    assert!(parsed.get("details").is_some());
    assert!(parsed.get("fingerprint").is_some());
    assert!(parsed.get("source_role").is_some());
    assert!(parsed.get("fixable").is_some());

    // issue_id is 12 hex chars
    let id = parsed["issue_id"].as_str().unwrap();
    assert_eq!(id.len(), 12);
    assert!(id.chars().all(|c| c.is_ascii_hexdigit()));
}

#[test]
fn confidence_propagation_from_rules() {
    let mut state = make_state();
    // Build error -> High confidence
    let issues = check_text_for_issues(
        10,
        MessageRole::User,
        "error[E0308]: mismatched types\n  expected u32",
        Some(SourceTool::Bash),
        &mut state,
    );
    let build_issue = issues
        .iter()
        .find(|i| i.code == IssueCode::BuildOrLintFailure);
    assert!(build_issue.is_some());
    assert_eq!(build_issue.unwrap().confidence, Confidence::High);
}

#[test]
fn fix_safety_backward_compat() {
    // AutoFixSafe -> fixable: true
    // TriageRequired -> fixable: false
    // AdvisoryOnly -> fixable: false
    // AutoFixGuarded -> fixable: true
    for (safety, expected) in [
        (FixSafety::AutoFixSafe, true),
        (FixSafety::AutoFixGuarded, true),
        (FixSafety::TriageRequired, false),
        (FixSafety::AdvisoryOnly, false),
    ] {
        assert_eq!(
            safety.is_fixable(),
            expected,
            "{safety} should have fixable={expected}"
        );
    }
}

#[test]
fn dedup_tracking_occurrence_count() {
    let mut state = make_state();
    // Feed same text twice -> should only get 1 issue but occurrence_count=2
    check_text_for_issues(
        10,
        MessageRole::User,
        "The system denied this tool call because it violates policy",
        None,
        &mut state,
    );
    check_text_for_issues(
        20,
        MessageRole::User,
        "The system denied this tool call because it violates policy",
        None,
        &mut state,
    );

    // Only 1 unique issue in seen_issues
    let hook_denial_count = state
        .seen_issues
        .iter()
        .filter(|(code, _)| *code == IssueCode::HookDeniedToolCall)
        .count();
    assert_eq!(hook_denial_count, 1);

    // But occurrence tracker has count=2
    let tracker = state
        .issue_occurrences
        .iter()
        .find(|((code, _), _)| *code == IssueCode::HookDeniedToolCall);
    assert!(tracker.is_some());
    let (_, tracker) = tracker.unwrap();
    assert_eq!(tracker.count, 2);
    assert_eq!(tracker.first_seen_line, 10);
    assert_eq!(tracker.last_seen_line, 20);
}

#[test]
fn focus_preset_filtering() {
    let harness_cats = FocusPreset::Harness.categories().unwrap();
    let skills_cats = FocusPreset::Skills.categories().unwrap();

    // BuildError is in harness, not skills
    assert!(harness_cats.contains(&IssueCategory::BuildError));
    assert!(!skills_cats.contains(&IssueCategory::BuildError));

    // SkillBehavior is in skills, not harness
    assert!(skills_cats.contains(&IssueCategory::SkillBehavior));
    assert!(!harness_cats.contains(&IssueCategory::SkillBehavior));

    // All returns None (no filter)
    assert!(FocusPreset::All.categories().is_none());
}

#[test]
fn source_tool_in_json_output() {
    let mut state = make_state();
    let issues = check_text_for_issues(
        10,
        MessageRole::User,
        "error[E0308]: mismatched types\n  expected u32",
        Some(SourceTool::Bash),
        &mut state,
    );
    assert!(!issues.is_empty());
    let issue = &issues[0];
    assert_eq!(issue.source_tool, Some(SourceTool::Bash));

    let rendered = output::render_json(issue);
    let parsed: serde_json::Value = serde_json::from_str(&rendered).unwrap();
    assert_eq!(parsed["source_tool"], "Bash");
}

#[test]
fn source_tool_absent_in_json_when_none() {
    let mut state = make_state();
    let issues = check_text_for_issues(
        10,
        MessageRole::User,
        "The system denied this tool call because it violates policy",
        None,
        &mut state,
    );
    assert!(!issues.is_empty());
    let rendered = output::render_json(&issues[0]);
    let parsed: serde_json::Value = serde_json::from_str(&rendered).unwrap();
    assert!(parsed.get("source_tool").is_none());
}

#[test]
fn tool_correlation_window_pruning() {
    let mut state = make_state();
    // Add 150 tool uses
    for i in 0..150 {
        let block = serde_json::json!({
            "type": "tool_use",
            "id": format!("tool_{i}"),
            "name": "Read",
            "input": {"file_path": format!("/tmp/file_{i}.rs")}
        });
        check_tool_use_for_issues(i, &block, &mut state);
    }
    // Should be capped at ~100
    assert!(
        state.last_tool_uses.len() <= 101,
        "tool uses should be pruned to ~100, got {}",
        state.last_tool_uses.len()
    );
}

// ─── Repository layout drift tests (Phase 7.5) ────────────────────

#[test]
fn fix_target_paths_look_valid() {
    // Collect all fix_target strings from TEXT_RULES and verify they
    // look like relative paths (not stale like "cli.rs" without src/)
    use crate::observe::classifier::rules::TEXT_RULES;
    for rule in TEXT_RULES {
        if let super::rules::RuleGuidance::Fix {
            target: Some(target),
            ..
        } = rule.guidance
        {
            // Targets should either contain a slash or be a known pattern
            assert!(
                target.contains('/') || target.contains('.'),
                "fix_target '{target}' for {:?} looks incomplete - should include path segments",
                rule.code
            );
        }
    }
}

#[test]
fn registry_and_all_codes_aligned() {
    // Every code in IssueCode::ALL should have a registry entry
    use crate::observe::classifier::registry::issue_code_meta;
    for code in IssueCode::ALL {
        assert!(
            issue_code_meta(*code).is_some(),
            "IssueCode::{code} missing from registry"
        );
    }
}

// ─── Fixture-driven scan test (Phase 7.6) ──────────────────────────

#[test]
fn scan_fixture_finds_known_issues() {
    // Synthetic JSONL with a known build error
    let session_line = r#"{"timestamp":"2026-03-15T10:00:00Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"error[E0308]: mismatched types\n  expected u32, found &str"}]}}"#;
    let mut state = ScanState::default();
    // Seed a tool_use record so the tool_result resolves to Bash
    state.last_tool_uses.insert(
        "t1".to_string(),
        ToolUseRecord {
            name: "Bash".to_string(),
            input: serde_json::json!({"command": "cargo check"}),
        },
    );
    let issues = super::classify_line(0, session_line, &mut state);
    assert!(
        issues
            .iter()
            .any(|i| i.category == IssueCategory::BuildError),
        "should detect build error in fixture"
    );
}

#[test]
fn evidence_excerpt_populated_for_long_details() {
    let mut state = make_state();
    let long_text = format!(
        "error[E0308]: mismatched types\n  expected u32, found &str\n{}",
        "x".repeat(200)
    );
    let issues = check_text_for_issues(
        10,
        MessageRole::User,
        &long_text,
        Some(SourceTool::Bash),
        &mut state,
    );
    let build = issues
        .iter()
        .find(|i| i.category == IssueCategory::BuildError);
    assert!(build.is_some());
    let excerpt = &build.unwrap().evidence_excerpt;
    assert!(
        excerpt.is_some(),
        "evidence_excerpt should be populated for long details"
    );
    assert!(excerpt.as_ref().unwrap().len() <= 200);
}

#[test]
fn detects_uncommitted_source_edit_before_second_edit() {
    let mut state = make_state();
    // First edit: sets the flag
    let edit1 = serde_json::json!({
        "type": "tool_use",
        "id": "t1",
        "name": "Edit",
        "input": { "file_path": "/repo/pkg/xds/proxy.go", "old_string": "a", "new_string": "b" }
    });
    let issues = check_tool_use_for_issues(10, &edit1, &mut state);
    assert!(
        !issues
            .iter()
            .any(|i| i.code == IssueCode::UncommittedSourceCodeEdit),
        "first edit should not trigger"
    );
    assert!(state.source_code_edited_without_commit);

    // Second edit without commit: should fire
    let edit2 = serde_json::json!({
        "type": "tool_use",
        "id": "t2",
        "name": "Write",
        "input": { "file_path": "/repo/pkg/xds/proxy.go", "content": "new content" }
    });
    let issues = check_tool_use_for_issues(20, &edit2, &mut state);
    assert!(
        issues
            .iter()
            .any(|i| i.code == IssueCode::UncommittedSourceCodeEdit
                && i.category == IssueCategory::SkillBehavior
                && i.severity == IssueSeverity::Medium)
    );
}

#[test]
fn detects_uncommitted_source_edit_before_harness_command() {
    let mut state = make_state();
    let edit = serde_json::json!({
        "type": "tool_use",
        "id": "t1",
        "name": "Edit",
        "input": { "file_path": "/repo/pkg/xds/proxy.go", "old_string": "a", "new_string": "b" }
    });
    check_tool_use_for_issues(10, &edit, &mut state);

    let bash = serde_json::json!({
        "type": "tool_use",
        "id": "t2",
        "name": "Bash",
        "input": { "command": "harness apply --manifest g01/01.yaml" }
    });
    let issues = check_tool_use_for_issues(20, &bash, &mut state);
    assert!(issues.iter().any(
        |i| i.code == IssueCode::UncommittedSourceCodeEdit && i.summary.contains("uncommitted")
    ));
}

#[test]
fn git_commit_clears_uncommitted_source_flag() {
    let mut state = make_state();
    let edit = serde_json::json!({
        "type": "tool_use",
        "id": "t1",
        "name": "Edit",
        "input": { "file_path": "/repo/pkg/xds/proxy.go", "old_string": "a", "new_string": "b" }
    });
    check_tool_use_for_issues(10, &edit, &mut state);
    assert!(state.source_code_edited_without_commit);

    let commit = serde_json::json!({
        "type": "tool_use",
        "id": "t2",
        "name": "Bash",
        "input": { "command": "git add pkg/xds/proxy.go && git commit -m 'fix: proxy config'" }
    });
    let issues = check_tool_use_for_issues(20, &commit, &mut state);
    assert!(
        !issues
            .iter()
            .any(|i| i.code == IssueCode::UncommittedSourceCodeEdit),
        "git commit should not trigger uncommitted edit issue"
    );
    assert!(!state.source_code_edited_without_commit);
}

#[test]
fn skips_uncommitted_detection_for_non_source_files() {
    let mut state = make_state();
    let edit = serde_json::json!({
        "type": "tool_use",
        "id": "t1",
        "name": "Write",
        "input": { "file_path": "/repo/docs/README.md", "content": "# docs" }
    });
    check_tool_use_for_issues(10, &edit, &mut state);
    assert!(!state.source_code_edited_without_commit);
}

#[test]
fn uncommitted_edit_detects_various_source_extensions() {
    for extension in &["go", "rs", "py", "ts", "java", "c", "cpp", "rb", "sh"] {
        let mut state = make_state();
        let path = format!("/repo/src/main.{extension}");
        let edit = serde_json::json!({
            "type": "tool_use",
            "id": "t1",
            "name": "Edit",
            "input": { "file_path": path, "old_string": "a", "new_string": "b" }
        });
        check_tool_use_for_issues(10, &edit, &mut state);
        assert!(
            state.source_code_edited_without_commit,
            "should track .{extension} files"
        );
    }
}

// ─── Repeated kubectl query tests ──────────────────────────────────

#[test]
fn detects_repeated_kubectl_get_for_same_resource() {
    let mut state = make_state();
    let commands = [
        "kubectl get crd meshretries.kuma.io -o json | jq '.spec.versions'",
        "kubectl get crd meshretries.kuma.io -o json | jq '.spec.names'",
        "kubectl get crd meshretries.kuma.io -o json | jq '.status'",
    ];
    for (index, command) in commands.iter().enumerate() {
        let block = serde_json::json!({
            "type": "tool_use",
            "id": format!("t{index}"),
            "name": "Bash",
            "input": { "command": command }
        });
        let issues = check_tool_use_for_issues(10 + index, &block, &mut state);
        if index < 2 {
            assert!(
                !issues
                    .iter()
                    .any(|i| i.code == IssueCode::RepeatedKubectlQueryForSameResource),
                "should not flag on query {index}"
            );
        } else {
            assert!(
                issues
                    .iter()
                    .any(|i| i.code == IssueCode::RepeatedKubectlQueryForSameResource),
                "should flag on third query"
            );
        }
    }
}

#[test]
fn no_flag_for_different_kubectl_resources() {
    let mut state = make_state();
    let commands = [
        "kubectl get crd meshretries.kuma.io -o json",
        "kubectl get crd meshtimeouts.kuma.io -o json",
        "kubectl get crd meshcircuitbreakers.kuma.io -o json",
    ];
    for (index, command) in commands.iter().enumerate() {
        let block = serde_json::json!({
            "type": "tool_use",
            "id": format!("t{index}"),
            "name": "Bash",
            "input": { "command": command }
        });
        let issues = check_tool_use_for_issues(10 + index, &block, &mut state);
        assert!(
            !issues
                .iter()
                .any(|i| i.code == IssueCode::RepeatedKubectlQueryForSameResource),
            "different resources should not trigger flag"
        );
    }
}

#[test]
fn kubectl_queries_outside_window_do_not_trigger() {
    let mut state = make_state();
    // Space queries far apart so they fall outside the 20-line window
    let lines = [10, 40, 70];
    for (index, line) in lines.iter().enumerate() {
        let block = serde_json::json!({
            "type": "tool_use",
            "id": format!("t{index}"),
            "name": "Bash",
            "input": { "command": "kubectl get crd meshretries.kuma.io -o json" }
        });
        let issues = check_tool_use_for_issues(*line, &block, &mut state);
        assert!(
            !issues
                .iter()
                .any(|i| i.code == IssueCode::RepeatedKubectlQueryForSameResource),
            "queries outside window should not trigger flag"
        );
    }
}

#[test]
fn kubectl_describe_also_tracked() {
    let mut state = make_state();
    for index in 0..3 {
        let block = serde_json::json!({
            "type": "tool_use",
            "id": format!("t{index}"),
            "name": "Bash",
            "input": { "command": "kubectl describe pod my-pod -n kuma-system" }
        });
        let issues = check_tool_use_for_issues(10 + index, &block, &mut state);
        if index == 2 {
            assert!(
                issues
                    .iter()
                    .any(|i| i.code == IssueCode::RepeatedKubectlQueryForSameResource),
                "describe should be tracked too"
            );
        }
    }
}

#[test]
fn non_kubectl_commands_ignored_by_query_tracker() {
    let mut state = make_state();
    for index in 0..5 {
        let block = serde_json::json!({
            "type": "tool_use",
            "id": format!("t{index}"),
            "name": "Bash",
            "input": { "command": "harness record --label test -- kubectl get pods" }
        });
        let issues = check_tool_use_for_issues(10 + index, &block, &mut state);
        assert!(
            !issues
                .iter()
                .any(|i| i.code == IssueCode::RepeatedKubectlQueryForSameResource),
            "harness record wrapper should not produce false positives"
        );
    }
}

#[test]
fn repeated_kubectl_query_output_shape() {
    let mut state = make_state();
    for index in 0..3 {
        let block = serde_json::json!({
            "type": "tool_use",
            "id": format!("t{index}"),
            "name": "Bash",
            "input": { "command": "kubectl get crd meshretries.kuma.io -o json | jq '.spec'" }
        });
        check_tool_use_for_issues(10 + index, &block, &mut state);
    }
    // Re-run to get issues on the 3rd (dedup means the first emit sticks)
    let mut fresh_state = make_state();
    let mut all_issues = Vec::new();
    for index in 0..3 {
        let block = serde_json::json!({
            "type": "tool_use",
            "id": format!("t{index}"),
            "name": "Bash",
            "input": { "command": "kubectl get crd meshretries.kuma.io -o json | jq '.spec'" }
        });
        all_issues.extend(check_tool_use_for_issues(
            10 + index,
            &block,
            &mut fresh_state,
        ));
    }
    let issue = all_issues
        .iter()
        .find(|i| i.code == IssueCode::RepeatedKubectlQueryForSameResource)
        .expect("should have emitted issue");
    assert_eq!(issue.category, IssueCategory::UnexpectedBehavior);
    assert_eq!(issue.severity, IssueSeverity::Low);
    assert!(!issue.fix_safety.is_fixable());
    assert!(issue.summary.contains("dump once"));
    assert!(issue.details.contains("meshretries"));
}

#[test]
fn extract_kubectl_target_strips_namespace_and_output_flags() {
    use super::tool_checks::extract_kubectl_query_target;
    let target = extract_kubectl_query_target(
        "kubectl get pod my-pod -n kuma-system -o json | jq '.status'",
    );
    assert_eq!(target.as_deref(), Some("get pod my-pod"));
}

#[test]
fn extract_kubectl_target_returns_none_for_non_query() {
    use super::tool_checks::extract_kubectl_query_target;
    assert!(extract_kubectl_query_target("kubectl apply -f manifest.yaml").is_none());
    assert!(extract_kubectl_query_target("ls -la /tmp").is_none());
}

// ─── Resource cleanup tracking tests ───────────────────────────────

#[test]
fn resource_cleanup_tracks_apply_commands() {
    let mut state = make_state();
    let block = bash_tool_use("harness apply --manifest g13/01-meshtrace.yaml");
    check_tool_use_for_issues(10, &block, &mut state);
    assert!(state.pending_resource_creates.contains("01-meshtrace"));
}

#[test]
fn resource_cleanup_tracks_multiple_manifests() {
    let mut state = make_state();
    let block = bash_tool_use(
        "harness apply --manifest g13/01-meshtrace.yaml --manifest g13/02-containerpatch.yaml",
    );
    check_tool_use_for_issues(10, &block, &mut state);
    assert_eq!(state.pending_resource_creates.len(), 2);
    assert!(state.pending_resource_creates.contains("01-meshtrace"));
    assert!(state.pending_resource_creates.contains("02-containerpatch"));
}

#[test]
fn resource_cleanup_delete_removes_from_tracking() {
    let mut state = make_state();
    let apply = serde_json::json!({
        "type": "tool_use",
        "id": "t1",
        "name": "Bash",
        "input": { "command": "harness apply --manifest g13/01-meshtrace.yaml" }
    });
    check_tool_use_for_issues(10, &apply, &mut state);
    assert_eq!(state.pending_resource_creates.len(), 1);

    let delete = serde_json::json!({
        "type": "tool_use",
        "id": "t2",
        "name": "Bash",
        "input": { "command": "harness delete --manifest g13/01-meshtrace.yaml" }
    });
    check_tool_use_for_issues(20, &delete, &mut state);
    assert!(state.pending_resource_creates.is_empty());
}

#[test]
fn resource_cleanup_flags_uncleaned_on_group_report() {
    let mut state = make_state();
    let apply = serde_json::json!({
        "type": "tool_use",
        "id": "t1",
        "name": "Bash",
        "input": { "command": "harness apply --manifest g13/01-meshtrace.yaml --manifest g13/02-motb.yaml" }
    });
    check_tool_use_for_issues(10, &apply, &mut state);

    let report = serde_json::json!({
        "type": "tool_use",
        "id": "t2",
        "name": "Bash",
        "input": { "command": "harness report group --group g13 --verdict pass" }
    });
    let issues = check_tool_use_for_issues(20, &report, &mut state);
    assert!(
        issues
            .iter()
            .any(|i| i.code == IssueCode::ResourceNotCleanedUpBeforeGroupEnd
                && i.category == IssueCategory::SkillBehavior
                && i.severity == IssueSeverity::Low)
    );
}

#[test]
fn resource_cleanup_no_issue_when_all_deleted() {
    let mut state = make_state();
    let apply = serde_json::json!({
        "type": "tool_use",
        "id": "t1",
        "name": "Bash",
        "input": { "command": "harness apply --manifest g13/01-meshtrace.yaml" }
    });
    check_tool_use_for_issues(10, &apply, &mut state);

    let delete = serde_json::json!({
        "type": "tool_use",
        "id": "t2",
        "name": "Bash",
        "input": { "command": "harness delete --manifest g13/01-meshtrace.yaml" }
    });
    check_tool_use_for_issues(20, &delete, &mut state);

    let report = serde_json::json!({
        "type": "tool_use",
        "id": "t3",
        "name": "Bash",
        "input": { "command": "harness report group --group g13 --verdict pass" }
    });
    let issues = check_tool_use_for_issues(30, &report, &mut state);
    assert!(
        !issues
            .iter()
            .any(|i| i.code == IssueCode::ResourceNotCleanedUpBeforeGroupEnd)
    );
}

#[test]
fn resource_cleanup_resets_after_group_report() {
    let mut state = make_state();
    let apply = serde_json::json!({
        "type": "tool_use",
        "id": "t1",
        "name": "Bash",
        "input": { "command": "harness apply --manifest g13/01-meshtrace.yaml" }
    });
    check_tool_use_for_issues(10, &apply, &mut state);

    let report = serde_json::json!({
        "type": "tool_use",
        "id": "t2",
        "name": "Bash",
        "input": { "command": "harness report group --group g13 --verdict pass" }
    });
    check_tool_use_for_issues(20, &report, &mut state);
    assert!(
        state.pending_resource_creates.is_empty(),
        "should be cleared after group report"
    );

    // Second group report without any new applies should not fire
    let report2 = serde_json::json!({
        "type": "tool_use",
        "id": "t3",
        "name": "Bash",
        "input": { "command": "harness report group --group g14 --verdict pass" }
    });
    let issues = check_tool_use_for_issues(30, &report2, &mut state);
    assert!(
        !issues
            .iter()
            .any(|i| i.code == IssueCode::ResourceNotCleanedUpBeforeGroupEnd)
    );
}

#[test]
fn resource_cleanup_partial_delete_flags_remaining() {
    let mut state = make_state();
    let apply = serde_json::json!({
        "type": "tool_use",
        "id": "t1",
        "name": "Bash",
        "input": { "command": "harness apply --manifest g13/01-meshtrace.yaml --manifest g13/02-containerpatch.yaml" }
    });
    check_tool_use_for_issues(10, &apply, &mut state);

    // Only delete one of the two
    let delete = serde_json::json!({
        "type": "tool_use",
        "id": "t2",
        "name": "Bash",
        "input": { "command": "harness delete --manifest g13/01-meshtrace.yaml" }
    });
    check_tool_use_for_issues(20, &delete, &mut state);

    let report = serde_json::json!({
        "type": "tool_use",
        "id": "t3",
        "name": "Bash",
        "input": { "command": "harness report group --group g13 --verdict pass" }
    });
    let issues = check_tool_use_for_issues(30, &report, &mut state);
    assert!(
        issues
            .iter()
            .any(|i| i.code == IssueCode::ResourceNotCleanedUpBeforeGroupEnd)
    );
    let cleanup_issue = issues
        .iter()
        .find(|i| i.code == IssueCode::ResourceNotCleanedUpBeforeGroupEnd)
        .unwrap();
    assert!(cleanup_issue.details.contains("02-containerpatch"));
}

#[test]
fn resource_cleanup_output_shape() {
    let mut state = make_state();
    let apply = serde_json::json!({
        "type": "tool_use",
        "id": "t1",
        "name": "Bash",
        "input": { "command": "harness apply --manifest g13/01-meshtrace.yaml" }
    });
    check_tool_use_for_issues(10, &apply, &mut state);

    let report = serde_json::json!({
        "type": "tool_use",
        "id": "t2",
        "name": "Bash",
        "input": { "command": "harness report group --group g13 --verdict pass" }
    });
    let issues = check_tool_use_for_issues(20, &report, &mut state);
    assert_eq!(
        issues
            .iter()
            .filter(|i| i.code == IssueCode::ResourceNotCleanedUpBeforeGroupEnd)
            .count(),
        1
    );
    let issue = issues
        .iter()
        .find(|i| i.code == IssueCode::ResourceNotCleanedUpBeforeGroupEnd)
        .unwrap();
    assert!(!issue.fix_safety.is_fixable());
    assert!(issue.fix_target.is_none());
    assert!(
        issue
            .fix_hint
            .as_deref()
            .is_some_and(|hint| hint.contains("Delete test resources"))
    );
    assert_eq!(issue.source_tool, Some(SourceTool::Bash));
}

#[test]
fn resource_cleanup_ignores_non_harness_commands() {
    let mut state = make_state();
    let block = bash_tool_use("kubectl apply -f manifest.yaml");
    check_tool_use_for_issues(10, &block, &mut state);
    assert!(state.pending_resource_creates.is_empty());
}

#[test]
fn resource_cleanup_deduplicates_across_groups() {
    let mut state = make_state();

    // First group with uncleaned resources
    let apply1 = serde_json::json!({
        "type": "tool_use",
        "id": "t1",
        "name": "Bash",
        "input": { "command": "harness apply --manifest g13/01-meshtrace.yaml" }
    });
    check_tool_use_for_issues(10, &apply1, &mut state);

    let report1 = serde_json::json!({
        "type": "tool_use",
        "id": "t2",
        "name": "Bash",
        "input": { "command": "harness report group --group g13 --verdict pass" }
    });
    let issues1 = check_tool_use_for_issues(20, &report1, &mut state);
    assert_eq!(
        issues1
            .iter()
            .filter(|i| i.code == IssueCode::ResourceNotCleanedUpBeforeGroupEnd)
            .count(),
        1
    );

    // Second group with the same uncleaned resource name - deduplicates
    let apply2 = serde_json::json!({
        "type": "tool_use",
        "id": "t3",
        "name": "Bash",
        "input": { "command": "harness apply --manifest g14/01-meshtrace.yaml" }
    });
    check_tool_use_for_issues(30, &apply2, &mut state);

    let report2 = serde_json::json!({
        "type": "tool_use",
        "id": "t4",
        "name": "Bash",
        "input": { "command": "harness report group --group g14 --verdict pass" }
    });
    let issues2 = check_tool_use_for_issues(40, &report2, &mut state);
    // Same fingerprint ("01-meshtrace") so it deduplicates
    assert!(
        !issues2
            .iter()
            .any(|i| i.code == IssueCode::ResourceNotCleanedUpBeforeGroupEnd),
        "same fingerprint should be deduplicated"
    );
}

// ─── Capture between groups tracking tests ────────────────────────

#[test]
fn first_group_report_does_not_flag_missing_capture() {
    let mut state = make_state();
    let report = serde_json::json!({
        "type": "tool_use",
        "id": "t1",
        "name": "Bash",
        "input": { "command": "harness report group --group-id g01 --status pass --evidence-label e1" }
    });
    let issues = check_tool_use_for_issues(10, &report, &mut state);
    assert!(
        !issues
            .iter()
            .any(|i| i.code == IssueCode::GroupReportedWithoutCapture),
        "first group should not flag missing capture"
    );
    assert!(state.seen_any_group_report);
    assert!(!state.seen_capture_since_last_group_report);
}

#[test]
fn second_group_without_capture_flags_issue() {
    let mut state = make_state();

    // First group report
    let report1 = serde_json::json!({
        "type": "tool_use",
        "id": "t1",
        "name": "Bash",
        "input": { "command": "harness report group --group-id g01 --status pass --evidence-label e1" }
    });
    check_tool_use_for_issues(10, &report1, &mut state);

    // Second group report without capture in between
    let report2 = serde_json::json!({
        "type": "tool_use",
        "id": "t2",
        "name": "Bash",
        "input": { "command": "harness report group --group-id g02 --status pass --evidence-label e2" }
    });
    let issues = check_tool_use_for_issues(20, &report2, &mut state);
    assert!(
        issues
            .iter()
            .any(|i| i.code == IssueCode::GroupReportedWithoutCapture
                && i.category == IssueCategory::SkillBehavior
                && i.severity == IssueSeverity::Medium),
        "second group without capture should flag issue"
    );
}

#[test]
fn capture_between_groups_prevents_flag() {
    let mut state = make_state();

    // First group
    let report1 = serde_json::json!({
        "type": "tool_use",
        "id": "t1",
        "name": "Bash",
        "input": { "command": "harness report group --group-id g01 --status pass --evidence-label e1" }
    });
    check_tool_use_for_issues(10, &report1, &mut state);

    // Capture between groups
    let capture = serde_json::json!({
        "type": "tool_use",
        "id": "t2",
        "name": "Bash",
        "input": { "command": "harness capture --label after-g01" }
    });
    check_tool_use_for_issues(15, &capture, &mut state);

    // Second group
    let report2 = serde_json::json!({
        "type": "tool_use",
        "id": "t3",
        "name": "Bash",
        "input": { "command": "harness report group --group-id g02 --status pass --evidence-label e2" }
    });
    let issues = check_tool_use_for_issues(20, &report2, &mut state);
    assert!(
        !issues
            .iter()
            .any(|i| i.code == IssueCode::GroupReportedWithoutCapture),
        "capture between groups should prevent flag"
    );
}

#[test]
fn capture_label_on_report_prevents_flag() {
    let mut state = make_state();

    // First group
    let report1 = serde_json::json!({
        "type": "tool_use",
        "id": "t1",
        "name": "Bash",
        "input": { "command": "harness report group --group-id g01 --status pass --evidence-label e1" }
    });
    check_tool_use_for_issues(10, &report1, &mut state);

    // Second group with --capture-label (inline capture)
    let report2 = serde_json::json!({
        "type": "tool_use",
        "id": "t2",
        "name": "Bash",
        "input": { "command": "harness report group --group-id g02 --status pass --capture-label after-g02" }
    });
    let issues = check_tool_use_for_issues(20, &report2, &mut state);
    assert!(
        !issues
            .iter()
            .any(|i| i.code == IssueCode::GroupReportedWithoutCapture),
        "--capture-label should prevent flag"
    );
}

// ─── Truncated verification output tests ───────────────────────────

#[test]
fn detects_make_test_piped_through_tail() {
    let mut state = make_state();
    let block = bash_tool_use("make test | tail -10");
    let issues = check_tool_use_for_issues(10, &block, &mut state);
    assert!(
        issues
            .iter()
            .any(|i| i.code == IssueCode::VerificationOutputTruncated
                && i.category == IssueCategory::SkillBehavior
                && i.severity == IssueSeverity::Low)
    );
}

#[test]
fn detects_cargo_clippy_piped_through_head() {
    let mut state = make_state();
    let block = bash_tool_use("cargo clippy --lib 2>&1 | head -20");
    let issues = check_tool_use_for_issues(10, &block, &mut state);
    assert!(
        issues
            .iter()
            .any(|i| i.code == IssueCode::VerificationOutputTruncated)
    );
}

#[test]
fn detects_cargo_test_piped_through_tail() {
    let mut state = make_state();
    let block = bash_tool_use("cargo test --lib 2>&1 | tail -15");
    let issues = check_tool_use_for_issues(10, &block, &mut state);
    assert!(
        issues
            .iter()
            .any(|i| i.code == IssueCode::VerificationOutputTruncated)
    );
}

#[test]
fn detects_make_check_piped_through_tail() {
    let mut state = make_state();
    let block = bash_tool_use("make check 2>&1 | tail -5");
    let issues = check_tool_use_for_issues(10, &block, &mut state);
    assert!(
        issues
            .iter()
            .any(|i| i.code == IssueCode::VerificationOutputTruncated)
    );
}

#[test]
fn detects_lint_command_piped_through_head() {
    let mut state = make_state();
    let block = bash_tool_use("golangci-lint run ./... | head -20");
    let issues = check_tool_use_for_issues(10, &block, &mut state);
    assert!(
        issues
            .iter()
            .any(|i| i.code == IssueCode::VerificationOutputTruncated),
        "lint command piped through head should fire"
    );
}

#[test]
fn skips_tail_without_verification_keyword() {
    let mut state = make_state();
    let block = bash_tool_use("ls -la /tmp | tail -5");
    let issues = check_tool_use_for_issues(10, &block, &mut state);
    assert!(
        !issues
            .iter()
            .any(|i| i.code == IssueCode::VerificationOutputTruncated),
        "non-verification commands should not trigger"
    );
}

#[test]
fn skips_head_without_verification_keyword() {
    let mut state = make_state();
    let block = bash_tool_use("cat output.log | head -50");
    let issues = check_tool_use_for_issues(10, &block, &mut state);
    assert!(
        !issues
            .iter()
            .any(|i| i.code == IssueCode::VerificationOutputTruncated)
    );
}

#[test]
fn skips_verification_keyword_without_pipe() {
    let mut state = make_state();
    let block = bash_tool_use("make test");
    let issues = check_tool_use_for_issues(10, &block, &mut state);
    assert!(
        !issues
            .iter()
            .any(|i| i.code == IssueCode::VerificationOutputTruncated),
        "no pipe means no truncation"
    );
}

#[test]
fn truncated_verification_output_shape() {
    let mut state = make_state();
    let block = bash_tool_use("make test 2>&1 | tail -10");
    let issues = check_tool_use_for_issues(10, &block, &mut state);
    let issue = issues
        .iter()
        .find(|i| i.code == IssueCode::VerificationOutputTruncated)
        .expect("should detect truncated verification output");
    assert!(!issue.fix_safety.is_fixable());
    assert!(issue.fix_target.is_none());
    assert!(
        issue
            .fix_hint
            .as_deref()
            .is_some_and(|hint| hint.contains("grep"))
    );
    assert_eq!(issue.source_tool, Some(SourceTool::Bash));
}
