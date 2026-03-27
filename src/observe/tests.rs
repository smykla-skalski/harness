use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};

use super::application::ObserveFilter;
use super::application::maintenance::{load_observer_state, save_observer_state};
use super::types::{Issue, IssueCode, IssueSeverity, ObserverState};
use super::{ObserveFilterArgs, classifier, output, redact_details, scan, types};
use crate::workspace::project_context_dir;

fn write_session_file(dir: &Path, lines: &[&str]) -> PathBuf {
    let path = dir.join("test-session.jsonl");
    let mut file = fs::File::create(&path).unwrap();
    for line in lines {
        writeln!(file, "{line}").unwrap();
    }
    path
}

fn assert_json_issue_identity_shape(parsed: &serde_json::Value) {
    assert!(parsed["id"].is_string());
    assert!(parsed["location"]["line"].is_number());
    assert!(parsed["classification"]["code"].is_string());
    assert!(parsed["classification"]["category"].is_string());
}

fn assert_json_issue_classification_shape(parsed: &serde_json::Value) {
    assert!(parsed["classification"]["severity"].is_string());
    assert!(parsed["classification"]["confidence"].is_string());
    assert!(parsed["classification"]["fingerprint"].is_string());
}

fn assert_json_issue_message_shape(parsed: &serde_json::Value) {
    assert!(parsed["source"]["role"].is_string());
    assert!(parsed["message"]["summary"].is_string());
    assert!(parsed["message"]["details"].is_string());
    assert!(parsed["remediation"]["safety"].is_string());
    assert!(parsed["remediation"]["available"].is_boolean());
}

#[test]
fn resolve_from_numeric() {
    let tmp = tempfile::tempdir().unwrap();
    let path = write_session_file(tmp.path(), &["{}", "{}"]);
    let result = scan::resolve_from(&path, "500");
    assert_eq!(result.unwrap(), 500);
}

#[test]
fn resolve_from_timestamp() {
    let tmp = tempfile::tempdir().unwrap();
    let lines = [
        r#"{"timestamp":"2026-03-15T10:00:00Z","message":{"role":"user","content":"hello"}}"#,
        r#"{"timestamp":"2026-03-15T11:00:00Z","message":{"role":"user","content":"world"}}"#,
        r#"{"timestamp":"2026-03-15T12:00:00Z","message":{"role":"user","content":"end"}}"#,
    ];
    let path = write_session_file(tmp.path(), &lines);
    let result = scan::resolve_from(&path, "2026-03-15T11:00:00Z");
    assert_eq!(result.unwrap(), 1);
}

#[test]
fn resolve_from_prose() {
    let tmp = tempfile::tempdir().unwrap();
    let lines = [
        r#"{"message":{"role":"user","content":"starting bootstrap"}}"#,
        r#"{"message":{"role":"user","content":"running tests now"}}"#,
    ];
    let path = write_session_file(tmp.path(), &lines);
    let result = scan::resolve_from(&path, "running tests");
    assert_eq!(result.unwrap(), 1);
}

#[test]
fn resolve_from_no_match() {
    let tmp = tempfile::tempdir().unwrap();
    let path = write_session_file(
        tmp.path(),
        &[r#"{"message":{"role":"user","content":"hello"}}"#],
    );
    let result = scan::resolve_from(&path, "nonexistent phrase");
    assert!(result.is_err());
}

#[test]
fn filter_validation_unknown_severity() {
    let filter: ObserveFilter = ObserveFilterArgs {
        from_line: 0,
        from: None,
        focus: None,
        project_hint: None,
        json: false,
        summary: false,
        severity: Some("extreme".into()),
        category: None,
        exclude: None,
        fixable: false,
        mute: None,
        output: None,
        format: None,
        overrides: None,
        top_causes: None,
        output_details: None,
        since_timestamp: None,
        until_line: None,
        until_timestamp: None,
    }
    .into();
    let result = scan::apply_filters(Vec::new(), &filter);
    assert!(result.is_err());
    let err = result.unwrap_err();
    assert!(err.to_string().contains("unknown severity"));
}

#[test]
fn filter_validation_unknown_focus() {
    let filter: ObserveFilter = ObserveFilterArgs {
        from_line: 0,
        from: None,
        focus: Some("invalid_preset".into()),
        project_hint: None,
        json: false,
        summary: false,
        severity: None,
        category: None,
        exclude: None,
        fixable: false,
        mute: None,
        format: None,
        overrides: None,
        top_causes: None,
        output: None,
        output_details: None,
        since_timestamp: None,
        until_line: None,
        until_timestamp: None,
    }
    .into();
    let result = scan::apply_filters(Vec::new(), &filter);
    assert!(result.is_err());
}

#[test]
fn filter_mute_suppresses_issues() {
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
        mute: Some("build_or_lint_failure".into()),
        format: None,
        overrides: None,
        top_causes: None,
        output: None,
        output_details: None,
        since_timestamp: None,
        until_line: None,
        until_timestamp: None,
    }
    .into();
    let result = scan::apply_filters(vec![issue], &filter).unwrap();
    assert!(result.is_empty());
}

#[test]
fn redact_details_strips_home_paths() {
    let text = "Error in /Users/alice/Projects/foo/src/main.rs";
    let redacted = redact_details(text);
    assert!(redacted.contains("<home>/"));
    assert!(!redacted.contains("alice"));
}

#[test]
fn redact_details_strips_env_values() {
    let text = "KUBECONFIG=/data/k3d-config SECRET_KEY=abc123 other text";
    let redacted = redact_details(text);
    assert!(redacted.contains("KUBECONFIG=<redacted>"));
    assert!(redacted.contains("SECRET_KEY=<redacted>"));
}

#[test]
fn state_file_lifecycle_two_cycles() {
    let session_id = "lifecycle-test-session";
    let tmp_dir = tempfile::tempdir().unwrap();
    let session_file = write_session_file(
        tmp_dir.path(),
        &[
            r#"{"timestamp":"2026-03-15T10:00:00Z","message":{"role":"user","content":"hello"}}"#,
            r#"{"timestamp":"2026-03-15T10:01:00Z","message":{"role":"user","content":"world"}}"#,
        ],
    );

    let data_dir = tmp_dir.path().join("xdg_data");
    fs::create_dir_all(&data_dir).unwrap();
    temp_env::with_vars(
        [
            ("XDG_DATA_HOME", Some(data_dir.to_str().unwrap())),
            ("HOME", Some(tmp_dir.path().to_str().unwrap())),
        ],
        || {
            let project_context_root = project_context_dir(tmp_dir.path());
            let (issues, last_line) = scan::scan(&session_file, 0).unwrap();
            assert_eq!(last_line, 2);

            let mut state = ObserverState::default_for_session(session_id);
            state.cursor = last_line;
            state.last_scan_time = "2026-03-15T10:02:00Z".to_string();
            let state =
                save_observer_state(&project_context_root, "project-default", &state).unwrap();

            let loaded =
                load_observer_state(&project_context_root, "project-default", session_id).unwrap();
            assert_eq!(loaded.cursor, 2);
            assert_eq!(loaded.session_id, session_id);
            assert_eq!(loaded.state_version, state.state_version);

            let (issues2, last_line2) = scan::scan(&session_file, loaded.cursor).unwrap();
            assert!(issues2.is_empty());
            assert_eq!(last_line2, 2);

            let loaded2 =
                load_observer_state(&project_context_root, "project-default", session_id).unwrap();
            assert_eq!(loaded2.cursor, 2);
            assert!(
                project_context_root
                    .join("agents")
                    .join("observe")
                    .join("project-default")
                    .join("events.jsonl")
                    .exists()
            );
            assert!(
                project_context_root
                    .join("agents")
                    .join("observe")
                    .join("project-default")
                    .join("snapshot.json")
                    .exists()
            );

            drop(issues);
        },
    );
}

#[test]
fn state_file_save_detects_conflict() {
    let session_id = "conflict-test-session";
    let tmp_dir = tempfile::tempdir().unwrap();
    let data_dir = tmp_dir.path().join("xdg_data");
    fs::create_dir_all(&data_dir).unwrap();

    temp_env::with_vars(
        [
            ("XDG_DATA_HOME", Some(data_dir.to_str().unwrap())),
            ("HOME", Some(tmp_dir.path().to_str().unwrap())),
        ],
        || {
            let project_context_root = project_context_dir(tmp_dir.path());
            let initial = ObserverState::default_for_session(session_id);
            let saved =
                save_observer_state(&project_context_root, "project-default", &initial).unwrap();
            assert_eq!(saved.state_version, 1);

            let mut stale = ObserverState::default_for_session(session_id);
            stale.cursor = 99;
            let err = save_observer_state(&project_context_root, "project-default", &stale)
                .expect_err("stale observer state should conflict");
            assert!(
                err.details()
                    .is_some_and(|details| details.contains("observer state conflict"))
            );

            let loaded =
                load_observer_state(&project_context_root, "project-default", session_id).unwrap();
            assert_eq!(loaded.cursor, 0);
            assert_eq!(loaded.state_version, 1);
        },
    );
}

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
fn observer_state_active_workers_tracks() {
    let mut state = ObserverState::default_for_session("test");
    assert!(!state.handoff_safe());
    state.last_scan_time = "2026-03-16T00:00:00Z".into();
    assert!(state.handoff_safe());
    state.active_workers.push(types::ActiveWorker {
        issue_id: "abc".into(),
        target_file: "src/main.rs".into(),
        started_at: "2026-03-16T00:00:00Z".into(),
    });
    assert!(!state.handoff_safe());
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
