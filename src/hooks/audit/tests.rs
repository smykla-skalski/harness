use std::fs;

use super::summarize::summarize_answers;
use super::*;
use crate::hooks::application::GuardContext as HookContext;
use crate::hooks::protocol::hook_result::Decision;
use crate::hooks::protocol::payloads::HookEnvelopePayload;
use crate::run::context::{RunContext, RunLayout};
use crate::run::test_support::build_test_run_dir;

fn ctx_audit(skill: &str) -> HookContext {
    HookContext::from_envelope(
        skill,
        HookEnvelopePayload {
            tool_name: String::new(),
            tool_input: serde_json::Value::Null,
            tool_response: serde_json::Value::Null,
            last_assistant_message: None,
            transcript_path: None,
            stop_hook_active: false,
            raw_keys: vec![],
        },
    )
}

#[test]
fn is_silent_suite_runner() {
    let context = ctx_audit("suite:run");
    let result = execute(&context).unwrap().to_hook_result();
    assert_eq!(result.decision, Decision::Allow);
    assert!(result.code.is_empty());
}

#[test]
fn is_silent_suite_author() {
    let context = ctx_audit("suite:create");
    let result = execute(&context).unwrap().to_hook_result();
    assert_eq!(result.decision, Decision::Allow);
    assert!(result.code.is_empty());
}

#[test]
fn allows_inactive_skill() {
    let mut context = ctx_audit("suite:run");
    context.skill_active = false;
    let result = execute(&context).unwrap().to_hook_result();
    assert_eq!(result.decision, Decision::Allow);
}

#[test]
fn writes_audit_entry_for_suite_run_hook() {
    let tempdir = tempfile::tempdir().unwrap();
    let (run_dir, _) = build_test_run_dir(tempdir.path(), "r01");
    let run_context = RunContext::from_run_dir(&run_dir).unwrap();

    let mut context = HookContext::from_test_envelope(
        "suite:run",
        HookEnvelopePayload {
            tool_name: "Bash".to_string(),
            tool_input: serde_json::json!({
                "command": "harness record --phase verify --gid g01 -- echo hello",
            }),
            tool_response: serde_json::json!({
                "stdout": "hello\n",
                "stderr": "",
                "exit_code": 0,
            }),
            last_assistant_message: None,
            transcript_path: None,
            stop_hook_active: false,
            raw_keys: vec![],
        },
    );
    context.run_dir = Some(run_dir.clone());
    context.run = Some(run_context);

    let outcome = execute(&context).unwrap();
    let mut result = outcome.normalized_result();
    super::super::effects::apply_effects(&mut result, outcome.effects());
    assert_eq!(result.to_hook_result().decision, Decision::Allow);

    let log_path = run_dir.join("audit-log.jsonl");
    let contents = fs::read_to_string(&log_path).unwrap();
    assert!(contents.contains("\"tool_name\":\"Bash\""));
    assert!(contents.contains("\"phase\":\"bootstrap\""));
    assert!(!contents.contains("\"group_id\""));
}

#[test]
fn allows_when_run_context_is_missing() {
    let context = HookContext::from_envelope(
        "suite:run",
        HookEnvelopePayload {
            tool_name: "Read".to_string(),
            tool_input: serde_json::json!({
                "file_path": "/tmp/test.txt",
            }),
            tool_response: serde_json::Value::Null,
            last_assistant_message: None,
            transcript_path: None,
            stop_hook_active: false,
            raw_keys: vec![],
        },
    );

    let result = execute(&context).unwrap().to_hook_result();
    assert_eq!(result.decision, Decision::Allow);
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
