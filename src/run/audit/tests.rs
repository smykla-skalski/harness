use super::*;
use crate::run::workflow::{PreflightState, PreflightStatus};
use crate::run::{RunCounts, Verdict};

use summarize::summarize_answers;

fn sample_status(run_id: &str, suite_id: &str) -> RunStatus {
    RunStatus {
        run_id: run_id.to_string(),
        suite_id: suite_id.to_string(),
        profile: "single-zone".to_string(),
        started_at: String::new(),
        overall_verdict: Verdict::Pending,
        completed_at: None,
        counts: RunCounts::default(),
        executed_groups: vec![],
        skipped_groups: vec![],
        last_completed_group: None,
        last_state_capture: None,
        last_updated_utc: None,
        next_planned_group: None,
        notes: vec![],
    }
}

#[test]
fn resolve_phase_context_keeps_group_only_for_execution() {
    let state = RunnerWorkflowState {
        phase: RunnerPhase::Execution,
        preflight: PreflightState {
            status: PreflightStatus::Complete,
        },
        failure: None,
        suite_fix: None,
        updated_at: String::new(),
        transition_count: 0,
        last_event: None,
        history: Vec::new(),
    };
    let mut status = sample_status("r1", "s1");
    status.next_planned_group = Some("g03".to_string());

    let context = resolve_phase_context(Some(&state), Some(&status), None, None);
    assert_eq!(context.phase, "execution");
    assert_eq!(context.group_id.as_deref(), Some("g03"));

    let context = resolve_phase_context(Some(&state), Some(&status), Some("closeout"), None);
    assert_eq!(context.phase, "closeout");
    assert!(context.group_id.is_none());
}

#[test]
fn normalize_tool_output_formats_bash() {
    let output = normalize_tool_output(
        "Bash",
        &serde_json::json!({
            "stdout": "ok",
            "stderr": "warn",
            "exit_code": 7,
        }),
    );
    assert_eq!(
        output,
        "exit code: 7\n--- STDOUT ---\nok\n--- STDERR ---\nwarn"
    );
}

fn assert_audit_entry_fields(entry: &AuditEntry) {
    assert_eq!(entry.tool_name, "Read");
    assert_eq!(entry.tool_input, "suite.md");
    assert_eq!(entry.output_summary, "file contents");
    assert_eq!(entry.group_id.as_deref(), Some("g01"));
}

fn assert_audit_log_contains_entry(layout: &RunLayout) {
    let log_contents = fs::read_to_string(layout.audit_log_path()).unwrap();
    assert!(log_contents.contains("\"tool_name\":\"Read\""));
    assert!(log_contents.contains("\"group_id\":\"g01\""));
}

#[test]
fn append_audit_entry_writes_jsonl_and_artifact() {
    let tempdir = tempfile::tempdir().unwrap();
    let run_dir = tempdir.path().join("r01");
    let layout = RunLayout::from_run_dir(&run_dir);
    layout.ensure_dirs().unwrap();

    let entry = append_audit_entry(AuditAppendRequest {
        run_dir: run_dir.clone(),
        tool_name: "Read".to_string(),
        tool_input: "suite.md".to_string(),
        full_output: "file contents".to_string(),
        phase: "execution".to_string(),
        group_id: Some("g01".to_string()),
    })
    .unwrap();

    assert_audit_entry_fields(&entry);
    assert!(run_dir.join(&entry.artifact_path).exists());
    assert_audit_log_contains_entry(&layout);
}

#[test]
fn write_run_status_with_audit_records_status_write() {
    let tempdir = tempfile::tempdir().unwrap();
    let run_dir = tempdir.path().join("r01");
    let layout = RunLayout::from_run_dir(&run_dir);
    layout.ensure_dirs().unwrap();

    let status = sample_status("r01", "suite");

    write_run_status_with_audit(&run_dir, &status, None, Some("bootstrap"), None).unwrap();

    let log_contents = fs::read_to_string(layout.audit_log_path()).unwrap();
    assert!(log_contents.contains("\"tool_name\":\"RunStatusWrite\""));
    assert!(log_contents.contains("\"phase\":\"bootstrap\""));
    assert!(layout.status_path().exists());
}

#[test]
fn append_runner_state_audit_records_runner_state_write() {
    let tempdir = tempfile::tempdir().unwrap();
    let run_dir = tempdir.path().join("r01");
    let layout = RunLayout::from_run_dir(&run_dir);
    layout.ensure_dirs().unwrap();

    let mut status = sample_status("r01", "suite");
    status.last_completed_group = Some("g02".to_string());
    status.next_planned_group = Some("g03".to_string());
    write_run_status_with_audit(&run_dir, &status, None, Some("execution"), Some("g03")).unwrap();

    let state = RunnerWorkflowState {
        phase: RunnerPhase::Execution,
        preflight: PreflightState {
            status: PreflightStatus::Complete,
        },
        failure: None,
        suite_fix: None,
        updated_at: String::new(),
        transition_count: 0,
        last_event: None,
        history: Vec::new(),
    };

    append_runner_state_audit(&run_dir, &state).unwrap();

    let log_contents = fs::read_to_string(layout.audit_log_path()).unwrap();
    assert!(log_contents.contains("\"tool_name\":\"RunnerStateWrite\""));
    assert!(log_contents.contains("\"group_id\":\"g03\""));
}

#[test]
fn summarize_tool_input_handles_questions() {
    let summary = summarize_tool_input(
        "AskUserQuestion",
        &serde_json::json!({
            "questions": [
                {"question": "Proceed?\nMore detail", "options": []}
            ]
        }),
    );
    assert_eq!(summary, "Proceed?");
}

#[test]
fn summarize_answers_prefers_question_answer_lines() {
    let summary = summarize_answers(&serde_json::json!({
        "answers": [
            {"question": "Proceed?\nMore detail", "answer": "Yes"}
        ]
    }));
    assert_eq!(summary, "Proceed? => Yes");
}

#[cfg(unix)]
#[test]
fn audit_log_file_has_restricted_permissions() {
    use std::os::unix::fs::PermissionsExt;

    let tempdir = tempfile::tempdir().unwrap();
    let run_dir = tempdir.path().join("r01");
    let layout = RunLayout::from_run_dir(&run_dir);
    layout.ensure_dirs().unwrap();

    append_audit_entry(AuditAppendRequest {
        run_dir,
        tool_name: "Read".to_string(),
        tool_input: "test.md".to_string(),
        full_output: "contents".to_string(),
        phase: "execution".to_string(),
        group_id: None,
    })
    .unwrap();

    let log_metadata = fs::metadata(layout.audit_log_path()).unwrap();
    let log_mode = log_metadata.permissions().mode() & 0o777;
    assert_eq!(log_mode, 0o600, "audit log expected 0600, got {log_mode:o}");
}

#[test]
fn append_audit_entry_scrubs_secrets_from_artifact() {
    let tempdir = tempfile::tempdir().unwrap();
    let run_dir = tempdir.path().join("r01");
    let layout = RunLayout::from_run_dir(&run_dir);
    layout.ensure_dirs().unwrap();

    let entry = append_audit_entry(AuditAppendRequest {
        run_dir: run_dir.clone(),
        tool_name: "Bash".to_string(),
        tool_input: "harness run kuma token dataplane".to_string(),
        full_output: "token: eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IkpvaG4gRG9lIn0.Signature1234567890abcdef".to_string(),
        phase: "execution".to_string(),
        group_id: None,
    })
    .unwrap();

    let artifact_content = fs::read_to_string(run_dir.join(&entry.artifact_path)).unwrap();
    assert!(artifact_content.contains("[REDACTED:JWT]"));
    assert!(!artifact_content.contains("eyJhbGciOiJSUzI1NiI"));
}
