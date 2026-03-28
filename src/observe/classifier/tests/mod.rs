use super::*;
use crate::kernel::tooling::legacy_tool_context;
use crate::observe::output;
use crate::observe::types::{
    Confidence, FixSafety, FocusPreset, IssueCategory, IssueCode, IssueSeverity, MessageRole,
    ScanState, SourceTool, ToolUseRecord,
};

mod assistant_diagnostics;
mod coordination;
mod query_tracking;
mod resource_tracking;
mod state_and_registry;
mod text_and_line;
mod tool_guard_patterns;
mod tool_use_patterns;
mod verification;
mod workflow_rules;

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

fn assert_remediation_fields(
    issue: &Issue,
    expected_fixable: bool,
    expected_target: Option<&str>,
    hint_fragment: Option<&str>,
) {
    assert_eq!(issue.fix_safety.is_fixable(), expected_fixable);
    assert_eq!(issue.fix_target.as_deref(), expected_target);
    match hint_fragment {
        Some(fragment) => assert!(
            issue
                .fix_hint
                .as_deref()
                .is_some_and(|hint| hint.contains(fragment))
        ),
        None => assert!(issue.fix_hint.is_none()),
    }
}

fn assert_rule_rendered_target(parsed: &serde_json::Value, expected_target: Option<&str>) {
    assert_eq!(
        parsed["remediation"]["available"],
        expected_target.is_some()
    );
    match expected_target {
        Some(target) => assert_eq!(parsed["remediation"]["target"], target),
        None => assert!(parsed["remediation"].get("target").is_none()),
    }
}

fn assert_rule_rendered_classification(parsed: &serde_json::Value) {
    assert!(parsed["classification"]["code"].is_string());
    assert!(parsed["classification"]["fingerprint"].is_string());
    assert!(parsed["classification"]["confidence"].is_string());
    assert!(parsed["remediation"]["safety"].is_string());
}

fn assert_output_json_identity_fields(parsed: &serde_json::Value) {
    assert!(parsed.get("id").is_some());
    assert!(parsed["location"].get("line").is_some());
    assert!(parsed["classification"].get("code").is_some());
    assert!(parsed["classification"].get("category").is_some());
}

fn assert_output_json_classification_fields(parsed: &serde_json::Value) {
    assert!(parsed["classification"].get("severity").is_some());
    assert!(parsed["classification"].get("confidence").is_some());
    assert!(parsed["classification"].get("fingerprint").is_some());
}

fn assert_output_json_message_fields(parsed: &serde_json::Value) {
    assert!(parsed["message"].get("summary").is_some());
    assert!(parsed["message"].get("details").is_some());
    assert!(parsed["source"].get("role").is_some());
    assert!(parsed["remediation"].get("safety").is_some());
    assert!(parsed["remediation"].get("available").is_some());
}

fn repeated_kubectl_query_block(index: usize) -> serde_json::Value {
    serde_json::json!({
        "type": "tool_use",
        "id": format!("t{index}"),
        "name": "Bash",
        "input": { "command": "kubectl get crd meshretries.kuma.io -o json | jq '.spec'" }
    })
}

fn warm_repeated_kubectl_query_state() {
    let mut state = make_state();
    for index in 0..3 {
        let block = repeated_kubectl_query_block(index);
        check_tool_use_for_issues(10 + index, &block, &mut state);
    }
}

fn collect_repeated_kubectl_query_issues() -> Vec<Issue> {
    let mut fresh_state = make_state();
    let mut all_issues = Vec::new();
    for index in 0..3 {
        let block = repeated_kubectl_query_block(index);
        all_issues.extend(check_tool_use_for_issues(
            10 + index,
            &block,
            &mut fresh_state,
        ));
    }
    all_issues
}
