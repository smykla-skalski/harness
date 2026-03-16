use super::*;
use crate::commands::observe::types::{IssueCategory, MessageRole, ScanState, SourceTool};

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
fn rule_table_has_expected_count() {
    assert_eq!(rules::TEXT_RULES.len(), 15);
}
