use std::fs;

use super::super::{classifier, output};
use super::{
    Issue, IssueCode, IssueSeverity, ObserveFilter, ObserveFilterArgs,
    assert_json_issue_classification_shape, assert_json_issue_identity_shape,
    assert_json_issue_message_shape, scan, types, write_session_file,
};

#[test]
fn golden_scan_json_output() {
    let mut state = types::ScanState::default();
    let issues = classifier::check_text_for_issues(
        42,
        types::MessageRole::User,
        "error[E0308]: mismatched types\n  expected u32, found &str",
        Some(types::SourceTool::Bash),
        &mut state,
    );
    assert!(!issues.is_empty());

    let rendered = output::render_json(&issues[0]);
    let parsed: serde_json::Value = serde_json::from_str(&rendered).unwrap();

    assert_json_issue_identity_shape(&parsed);
    assert_json_issue_classification_shape(&parsed);
    assert_json_issue_message_shape(&parsed);
}

#[test]
fn golden_human_output_format() {
    let issue = Issue {
        id: "abc123def456".into(),
        line: 42,
        code: IssueCode::BuildOrLintFailure,
        category: types::IssueCategory::BuildError,
        severity: IssueSeverity::Critical,
        confidence: types::Confidence::High,
        fix_safety: types::FixSafety::AutoFixSafe,
        summary: "Build failed".into(),
        details: "error[E0308]".into(),
        fingerprint: "build_or_lint_failure".into(),
        source_role: types::MessageRole::Assistant,
        source_tool: None,
        fix_target: Some("src/main.rs".into()),
        fix_hint: Some("Fix the type".into()),
        evidence_excerpt: None,
    };
    let rendered = output::render_human(&issue);
    assert!(rendered.contains("[CRITICAL/high]"));
    assert!(rendered.contains("L42"));
    assert!(rendered.contains("build_error/build_or_lint_failure"));
    assert!(rendered.contains("fix: src/main.rs"));
    assert!(rendered.contains("hint: Fix the type"));
}

#[test]
fn golden_summary_json_shape() {
    let issue = Issue {
        id: "abc123".into(),
        line: 1,
        code: IssueCode::BuildOrLintFailure,
        category: types::IssueCategory::BuildError,
        severity: IssueSeverity::Critical,
        confidence: types::Confidence::High,
        fix_safety: types::FixSafety::AutoFixSafe,
        summary: "test".into(),
        details: String::new(),
        fingerprint: "test".into(),
        source_role: types::MessageRole::Assistant,
        source_tool: None,
        fix_target: None,
        fix_hint: None,
        evidence_excerpt: None,
    };
    let rendered = output::render_summary(&[issue], 100);
    let parsed: serde_json::Value = serde_json::from_str(&rendered).unwrap();
    assert_eq!(parsed["status"], "done");
    assert_eq!(parsed["cursor"]["last_line"], 100);
    assert_eq!(parsed["issues"]["total"], 1);
    assert!(parsed["issues"]["by_severity"].is_array());
    assert!(parsed["issues"]["by_category"].is_array());
}

#[test]
fn markdown_output_contains_table() {
    let issue = Issue {
        id: "abc123".into(),
        line: 42,
        code: IssueCode::BuildOrLintFailure,
        category: types::IssueCategory::BuildError,
        severity: IssueSeverity::Critical,
        confidence: types::Confidence::High,
        fix_safety: types::FixSafety::AutoFixSafe,
        summary: "Build failed".into(),
        details: String::new(),
        fingerprint: "test".into(),
        source_role: types::MessageRole::Assistant,
        source_tool: None,
        fix_target: None,
        fix_hint: None,
        evidence_excerpt: None,
    };
    let rendered = output::render_markdown(&[issue]);
    assert!(rendered.contains("# Observe report"));
    assert!(rendered.contains("Build failed"));
    assert!(rendered.contains("Total: 1 issues"));
}

#[test]
fn top_causes_groups_by_code() {
    let make_issue = |code: IssueCode, summary: &str| Issue {
        id: "x".into(),
        line: 1,
        code,
        category: types::IssueCategory::BuildError,
        severity: IssueSeverity::Critical,
        confidence: types::Confidence::High,
        fix_safety: types::FixSafety::AutoFixSafe,
        summary: summary.into(),
        details: String::new(),
        fingerprint: "x".into(),
        source_role: types::MessageRole::Assistant,
        source_tool: None,
        fix_target: None,
        fix_hint: None,
        evidence_excerpt: None,
    };
    let issues = vec![
        make_issue(IssueCode::BuildOrLintFailure, "Build 1"),
        make_issue(IssueCode::BuildOrLintFailure, "Build 2"),
        make_issue(IssueCode::HookDeniedToolCall, "Hook denied"),
    ];
    let rendered = output::render_top_causes(&issues, 2);
    let parsed: serde_json::Value = serde_json::from_str(&rendered).unwrap();
    let causes = parsed["causes"].as_array().unwrap();
    assert_eq!(causes.len(), 2);
    assert_eq!(causes[0]["occurrences"], 2);
}

#[test]
fn scan_with_limit_stops_at_bound() {
    let dir = tempfile::tempdir().unwrap();
    let path = write_session_file(
        dir.path(),
        &[
            r#"{"message":{"role":"user","content":"line zero"}}"#,
            r#"{"message":{"role":"user","content":"line one"}}"#,
            r#"{"message":{"role":"user","content":"line two"}}"#,
            r#"{"message":{"role":"user","content":"line three"}}"#,
        ],
    );
    let (_, last_line) = scan::scan_range(&path, 0, 1).unwrap();
    assert_eq!(last_line, 2);
}

#[test]
fn sarif_output_has_correct_shape() {
    let issue = Issue {
        id: "abc123".into(),
        line: 42,
        code: IssueCode::BuildOrLintFailure,
        category: types::IssueCategory::BuildError,
        severity: IssueSeverity::Critical,
        confidence: types::Confidence::High,
        fix_safety: types::FixSafety::AutoFixSafe,
        summary: "Build failed".into(),
        details: String::new(),
        fingerprint: "test".into(),
        source_role: types::MessageRole::Assistant,
        source_tool: None,
        fix_target: Some("src/main.rs".into()),
        fix_hint: None,
        evidence_excerpt: None,
    };
    let rendered = output::render_sarif(&[issue]);
    let parsed: serde_json::Value = serde_json::from_str(&rendered).unwrap();
    assert_eq!(parsed["version"], "2.1.0");
    let runs = parsed["runs"].as_array().unwrap();
    assert_eq!(runs.len(), 1);
    let results = runs[0]["results"].as_array().unwrap();
    assert_eq!(results.len(), 1);
    assert_eq!(results[0]["ruleId"], "build_or_lint_failure");
    assert_eq!(results[0]["level"], "error");
    assert_eq!(
        results[0]["properties"]["harnessObserve"]["classification"]["code"],
        "build_or_lint_failure"
    );
}

#[test]
fn scan_range_returns_bounded_results() {
    let dir = tempfile::tempdir().unwrap();
    let path = write_session_file(
        dir.path(),
        &[
            r#"{"message":{"role":"user","content":"line zero"}}"#,
            r#"{"message":{"role":"user","content":"line one"}}"#,
            r#"{"message":{"role":"user","content":"line two"}}"#,
        ],
    );
    let (_, last) = scan::scan_range(&path, 1, 1).unwrap();
    assert_eq!(last, 2);
}

#[test]
fn overrides_yaml_mutes_and_adjusts_severity() {
    let dir = tempfile::tempdir().unwrap();
    let overrides_path = dir.path().join("overrides.yaml");
    fs::write(
        &overrides_path,
        "mute:\n  - hook_denied_tool_call\nseverity_overrides:\n  build_or_lint_failure: low\n",
    )
    .unwrap();

    let hook_issue = Issue {
        id: "h1".into(),
        line: 1,
        code: IssueCode::HookDeniedToolCall,
        category: types::IssueCategory::HookFailure,
        severity: IssueSeverity::Medium,
        confidence: types::Confidence::High,
        fix_safety: types::FixSafety::TriageRequired,
        summary: "hook denied".into(),
        details: String::new(),
        fingerprint: "test".into(),
        source_role: types::MessageRole::User,
        source_tool: None,
        fix_target: None,
        fix_hint: None,
        evidence_excerpt: None,
    };
    let build_issue = Issue {
        id: "b1".into(),
        line: 2,
        code: IssueCode::BuildOrLintFailure,
        category: types::IssueCategory::BuildError,
        severity: IssueSeverity::Critical,
        confidence: types::Confidence::High,
        fix_safety: types::FixSafety::AutoFixSafe,
        summary: "build fail".into(),
        details: String::new(),
        fingerprint: "test".into(),
        source_role: types::MessageRole::Assistant,
        source_tool: None,
        fix_target: None,
        fix_hint: None,
        evidence_excerpt: None,
    };

    let filter: ObserveFilter = ObserveFilterArgs {
        from_line: 0,
        from: None,
        focus: None,
        project_hint: None,
        json: false,
        summary: false,
        severity: None,
        category: None,
        exclude: None,
        fixable: false,
        mute: None,
        format: None,
        overrides: Some(overrides_path.to_string_lossy().into_owned()),
        top_causes: None,
        output: None,
        output_details: None,
        since_timestamp: None,
        until_line: None,
        until_timestamp: None,
    }
    .into();

    let result = scan::apply_filters(vec![hook_issue, build_issue], &filter).unwrap();
    assert_eq!(result.len(), 1);
    assert_eq!(result[0].code, IssueCode::BuildOrLintFailure);
    assert_eq!(result[0].severity, IssueSeverity::Low);
}
