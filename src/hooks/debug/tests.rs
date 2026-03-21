use std::fs as stdfs;

use super::*;
use crate::hooks::protocol::payloads::HookEnvelopePayload;
use crate::workspace::session_context_dir;

#[test]
fn allow_returns_zero_exit_code() {
    let outcome = HookOutcome::allow();
    assert_eq!(outcome.exit_code, 0);
    assert_eq!(outcome.outcome, OutcomeKind::Allowed);
    assert!(outcome.message.is_none());
    assert!(outcome.gate.is_none());
}

#[test]
fn allow_with_sets_custom_outcome() {
    let outcome = HookOutcome::allow_with(OutcomeKind::Skipped);
    assert_eq!(outcome.exit_code, 0);
    assert_eq!(outcome.outcome, OutcomeKind::Skipped);
}

#[test]
fn error_sets_exit_code_and_outcome() {
    let outcome = HookOutcome::error(2);
    assert_eq!(outcome.exit_code, 2);
    assert_eq!(outcome.outcome, OutcomeKind::Error);
}

#[test]
fn ignored_returns_zero_exit_code() {
    let outcome = HookOutcome::ignored();
    assert_eq!(outcome.exit_code, 0);
    assert_eq!(outcome.outcome, OutcomeKind::Ignored);
}

#[test]
fn outcome_kind_display() {
    assert_eq!(OutcomeKind::Allowed.to_string(), "allowed");
    assert_eq!(OutcomeKind::Error.to_string(), "error");
    assert_eq!(OutcomeKind::Ignored.to_string(), "ignored");
    assert_eq!(OutcomeKind::Skipped.to_string(), "skipped");
}

#[test]
fn with_message_sets_message() {
    let outcome = HookOutcome::allow().with_message("all good");
    assert_eq!(outcome.message.as_deref(), Some("all good"));
}

#[test]
fn with_gate_sets_gate() {
    let outcome = HookOutcome::allow().with_gate("prewrite");
    assert_eq!(outcome.gate.as_deref(), Some("prewrite"));
}

#[test]
fn log_and_exit_returns_exit_code() {
    let event = HookEvent {
        payload: HookEnvelopePayload::default(),
    };
    let outcome = HookOutcome::error(3).with_message("fail");
    assert_eq!(outcome.log_and_exit("test-hook", &event), 3);
}

#[test]
fn log_and_exit_returns_zero_for_allow() {
    let event = HookEvent {
        payload: HookEnvelopePayload::default(),
    };
    let outcome = HookOutcome::allow();
    assert_eq!(outcome.log_and_exit("test-hook", &event), 0);
}

#[test]
fn log_and_exit_writes_jsonl_debug_file() {
    let tmp = tempfile::tempdir().unwrap();
    let xdg = tmp.path().join("xdg");
    temp_env::with_vars(
        [
            ("XDG_DATA_HOME", Some(xdg.to_str().unwrap())),
            ("CLAUDE_SESSION_ID", Some("debug-test-session")),
        ],
        || {
            let event = HookEvent {
                payload: HookEnvelopePayload::default(),
            };
            let outcome = HookOutcome::error(2)
                .with_message("blocked")
                .with_gate("prebash");
            let code = outcome.log_and_exit("guard-bash", &event);
            assert_eq!(code, 2);

            let ctx_dir = session_context_dir().unwrap();
            let debug_path = ctx_dir.join("hooks-debug.jsonl");
            assert!(debug_path.exists(), "debug file should exist");

            let content = stdfs::read_to_string(&debug_path).unwrap();
            let line = parse_last_debug_line(&content);
            assert_debug_line_fields(&line);
        },
    );
}

fn parse_last_debug_line(content: &str) -> serde_json::Value {
    serde_json::from_str(
        content
            .lines()
            .last()
            .expect("debug file should contain at least one JSONL line"),
    )
    .unwrap()
}

fn assert_debug_line_fields(line: &serde_json::Value) {
    assert_eq!(line["hook_name"], "guard-bash");
    assert_eq!(line["exit_code"], 2);
    assert_eq!(line["outcome"], "error");
    assert_eq!(line["message"], "blocked");
    assert_eq!(line["gate"], "prebash");
    assert!(line["timestamp"].as_str().unwrap().ends_with('Z'));
}
