//! Tests for ACP client handlers.

mod bridge;
mod terminal;

use std::collections::BTreeSet;
use std::fs;
use std::path::PathBuf;
use std::time::Duration;

use agent_client_protocol::schema::v1::{
    ReadTextFileRequest, RequestPermissionOutcome, RequestPermissionRequest, ToolCallUpdate,
    ToolCallUpdateFields, WriteTextFileRequest,
};
use serde_json::Value;
use tempfile::TempDir;

use super::{
    BINARY_DENIED, DAEMON_SHUTDOWN, HarnessAcpClient, PERMISSION_CAP_REACHED,
    PERMISSION_RUNTIME_UNSUPPORTED, PERMISSION_TIMEOUT, READ_DENIED, TERMINAL_DENIED,
    TERMINAL_NOT_FOUND, WRITE_DENIED,
};
use crate::agents::acp::permission::{PermissionMode, standard_permission_options};

#[track_caller]
fn ok<T, E: std::fmt::Debug>(result: Result<T, E>, context: &str) -> T {
    assert!(
        result.is_ok(),
        "{context}: unexpected Err({:?})",
        result.as_ref().err()
    );
    match result {
        Ok(value) => value,
        Err(error) => unreachable!("{context}: {error:?}"),
    }
}

#[track_caller]
fn err<T: std::fmt::Debug, E: std::fmt::Debug>(result: Result<T, E>, context: &str) -> E {
    assert!(
        result.is_err(),
        "{context}: unexpected Ok({:?})",
        result.as_ref().ok()
    );
    match result {
        Err(error) => error,
        Ok(value) => unreachable!("{context}: unexpected Ok({value:?})"),
    }
}

pub(super) fn setup_client() -> (TempDir, HarnessAcpClient) {
    setup_client_with_terminal_cap(super::MAX_TERMINALS_PER_SESSION)
}

pub(super) fn setup_client_with_terminal_cap(terminal_cap: usize) -> (TempDir, HarnessAcpClient) {
    let temp = ok(TempDir::new(), "create temp dir");
    let run_dir = temp.path().to_path_buf();
    let working_dir = temp.path().to_path_buf();

    ok(
        fs::create_dir_all(run_dir.join("artifacts")),
        "create artifacts",
    );
    ok(
        fs::create_dir_all(run_dir.join("commands")),
        "create commands",
    );

    let mut denied = BTreeSet::new();
    denied.insert("kubectl".to_string());
    denied.insert("kumactl".to_string());

    let client = HarnessAcpClient::new_with_terminal_cap(
        working_dir,
        run_dir.clone(),
        None,
        denied,
        PermissionMode::Recording {
            log_path: run_dir.join("permission-log.ndjson"),
        },
        terminal_cap,
    );

    (temp, client)
}

pub(super) fn setup_recording_client() -> (TempDir, HarnessAcpClient, PathBuf) {
    let temp = ok(TempDir::new(), "create temp dir");
    let run_dir = temp.path().to_path_buf();
    let working_dir = temp.path().to_path_buf();
    let log_path = run_dir.join("permission-log.ndjson");

    ok(
        fs::create_dir_all(run_dir.join("artifacts")),
        "create artifacts",
    );
    ok(
        fs::create_dir_all(run_dir.join("commands")),
        "create commands",
    );

    let mut denied = BTreeSet::new();
    denied.insert("kubectl".to_string());

    let client = HarnessAcpClient::new(
        working_dir,
        run_dir,
        None,
        denied,
        PermissionMode::Recording {
            log_path: log_path.clone(),
        },
    );

    (temp, client, log_path)
}

pub(super) fn read_log(path: &PathBuf) -> Vec<Value> {
    ok(fs::read_to_string(path), "permission log")
        .lines()
        .map(|line| ok(serde_json::from_str(line), "json line"))
        .collect()
}

#[test]
fn write_to_artifacts_allowed() {
    let (temp, client) = setup_client();
    let path = temp.path().join("artifacts/test.txt");

    let request = WriteTextFileRequest::new("test-session", &path, "hello");
    ok(
        client.handle_write_text_file(&request),
        "write to artifacts allowed",
    );
    assert_eq!(ok(fs::read_to_string(&path), "read written file"), "hello");
}

#[test]
fn write_outside_surface_denied() {
    let (_temp, client) = setup_client();
    let path = PathBuf::from("/tmp/outside.txt");

    let request = WriteTextFileRequest::new("test-session", &path, "hello");
    let err = err(
        client.handle_write_text_file(&request),
        "write should be denied",
    );
    assert_eq!(err.code, WRITE_DENIED);
}

#[test]
fn write_denied_binary_rejected() {
    let (temp, client) = setup_client();
    let path = temp.path().join("artifacts/kubectl");

    let request = WriteTextFileRequest::new("test-session", &path, "#!/bin/bash");
    let err = err(
        client.handle_write_text_file(&request),
        "binary should be denied",
    );
    assert_eq!(err.code, BINARY_DENIED);
}

#[test]
fn recording_write_logs_policy_decision_and_still_writes_when_allowed() {
    let (temp, client, log_path) = setup_recording_client();
    let path = temp.path().join("artifacts/test.txt");
    let request = WriteTextFileRequest::new("session-1", &path, "hello");

    ok(client.handle_write_text_file(&request), "write allowed");

    let records = read_log(&log_path);
    assert_eq!(records.len(), 1);
    assert_eq!(records[0]["operation"], "fs.write_text_file");
    assert_eq!(records[0]["decision"], "allowed");
    assert_eq!(records[0]["wouldAsk"]["path"], path.display().to_string());
    assert_eq!(ok(fs::read_to_string(&path), "written file"), "hello");
}

#[test]
fn recording_write_logs_denial_aligned_with_policy() {
    let (temp, client, log_path) = setup_recording_client();
    let path = temp.path().join("artifacts/kubectl");
    let request = WriteTextFileRequest::new("session-1", &path, "#!/bin/sh");

    let error = err(client.handle_write_text_file(&request), "denied binary");

    assert_eq!(error.code, BINARY_DENIED);
    let records = read_log(&log_path);
    assert_eq!(records.len(), 1);
    assert_eq!(records[0]["operation"], "fs.write_text_file");
    assert_eq!(records[0]["decision"], "denied");
    let reason_value = &records[0]["reason"];
    let Some(reason) = reason_value.as_str() else {
        unreachable!("recorded denial reason should be a string, got {reason_value:?}");
    };
    assert!(reason.contains("kubectl"), "unexpected reason: {reason}");
}

#[test]
fn recording_write_logs_denial_when_allowed_path_fails_to_write() {
    let (temp, client, log_path) = setup_recording_client();
    let path = temp.path().join("artifacts/existing-dir");
    ok(fs::create_dir_all(&path), "create existing directory");
    let request = WriteTextFileRequest::new("session-1", &path, "hello");

    let error = err(
        client.handle_write_text_file(&request),
        "cannot write file over directory",
    );

    assert_eq!(error.code, WRITE_DENIED);
    let records = read_log(&log_path);
    assert_eq!(records.len(), 1);
    assert_eq!(records[0]["operation"], "fs.write_text_file");
    assert_eq!(records[0]["decision"], "denied");
    let reason_value = &records[0]["reason"];
    let Some(reason) = reason_value.as_str() else {
        unreachable!("write failure reason should be a string, got {reason_value:?}");
    };
    assert!(
        reason.contains("failed to write"),
        "unexpected reason: {reason}"
    );
}

#[test]
fn read_within_working_dir_allowed() {
    let (temp, client) = setup_client();
    let path = temp.path().join("test.txt");
    fs::write(&path, "content").unwrap();

    let request = ReadTextFileRequest::new("test-session", &path);
    let response = ok(
        client.handle_read_text_file(&request),
        "read within working dir",
    );
    assert_eq!(response.content, "content");
}

#[test]
fn read_with_line_and_limit() {
    let (temp, client) = setup_client();
    let path = temp.path().join("lines.txt");
    fs::write(&path, "line1\nline2\nline3\nline4").unwrap();

    let mut request = ReadTextFileRequest::new("test-session", &path);
    request.line = Some(2);
    request.limit = Some(2);
    let response = ok(
        client.handle_read_text_file(&request),
        "read with line and limit",
    );
    assert_eq!(response.content, "line2\nline3");
}

#[test]
fn closed_daemon_permission_bridge_returns_shutdown() {
    let (temp, _) = setup_client();
    let (tx, rx) = tokio::sync::mpsc::channel(1);
    drop(rx);
    let client = HarnessAcpClient::new(
        temp.path().to_path_buf(),
        temp.path().to_path_buf(),
        None,
        BTreeSet::new(),
        PermissionMode::DaemonBridge {
            tx,
            deadline: Duration::from_millis(1),
        },
    );
    let tool_call = ToolCallUpdate::new("tool-a", ToolCallUpdateFields::new());
    let request =
        RequestPermissionRequest::new("session-1", tool_call, standard_permission_options());

    let error = err(
        client.handle_request_permission(&request),
        "closed bridge should fail",
    );

    assert_eq!(error.code, DAEMON_SHUTDOWN);
}

#[test]
fn recording_permission_request_never_blocks_or_approves() {
    let (_temp, client, log_path) = setup_recording_client();
    let tool_call = ToolCallUpdate::new("tool-a", ToolCallUpdateFields::new());
    let request =
        RequestPermissionRequest::new("session-1", tool_call, standard_permission_options());

    let response = ok(
        client.handle_request_permission(&request),
        "record permission",
    );

    let outcome = response.outcome;
    let RequestPermissionOutcome::Selected(selected) = outcome else {
        unreachable!(
            "recording permission mode should always return a selected outcome, got {outcome:?}"
        );
    };
    assert_eq!(selected.option_id.0.as_ref(), "reject_once");
    let records = read_log(&log_path);
    assert_eq!(records.len(), 1);
    assert_eq!(records[0]["operation"], "session.request_permission");
    assert_eq!(records[0]["decision"], "recorded_reject");
    assert_eq!(records[0]["wouldAsk"]["toolCall"]["toolCallId"], "tool-a");
}

#[test]
fn handle_request_permission_emits_permission_asked_event() {
    use std::sync::Arc;

    use crate::agents::acp::connection::SupervisorEventSink;
    use crate::agents::runtime::event::ConversationEventKind;

    let (temp, _) = setup_client();
    let log_path = temp.path().join("perm.log");
    let (event_tx, mut event_rx) = tokio::sync::mpsc::channel(8);
    let sink = Arc::new(SupervisorEventSink::new(
        event_tx,
        "acp-fixture".to_string(),
        "agent-fixture".to_string(),
        "session-fixture".to_string(),
    ));
    let client = HarnessAcpClient::new(
        temp.path().to_path_buf(),
        temp.path().to_path_buf(),
        None,
        BTreeSet::new(),
        PermissionMode::Recording {
            log_path: log_path.clone(),
        },
    )
    .with_event_sink(Arc::clone(&sink));

    let tool_call = ToolCallUpdate::new(
        "fs.write_text_file:/tmp/foo.txt",
        ToolCallUpdateFields::new(),
    );
    let request =
        RequestPermissionRequest::new("session-fixture", tool_call, standard_permission_options());

    let _ = ok(
        client.handle_request_permission(&request),
        "recording mode permission",
    );

    let batch = event_rx
        .try_recv()
        .expect("permission_asked batch must be admitted");
    assert_eq!(batch.acp_id, "acp-fixture");
    assert_eq!(batch.events.len(), 1);
    assert_eq!(batch.session_id, "session-fixture");
    assert_eq!(batch.raw_count, 0, "synthetic batch must mark raw_count 0");

    let kind = &batch.events[0].kind;
    let ConversationEventKind::PermissionAsked { tool, scope, .. } = kind else {
        panic!("expected PermissionAsked variant, got {kind:?}");
    };
    assert_eq!(tool, "fs.write_text_file");
    assert_eq!(scope, "/tmp/foo.txt");
}

#[test]
fn handle_request_permission_with_no_sink_emits_nothing() {
    let (temp, _) = setup_client();
    let log_path = temp.path().join("perm.log");
    let client = HarnessAcpClient::new(
        temp.path().to_path_buf(),
        temp.path().to_path_buf(),
        None,
        BTreeSet::new(),
        PermissionMode::Recording { log_path },
    );

    let tool_call = ToolCallUpdate::new("opaque-no-colon-id", ToolCallUpdateFields::new());
    let request =
        RequestPermissionRequest::new("session-fixture", tool_call, standard_permission_options());

    let _ = ok(
        client.handle_request_permission(&request),
        "recording mode permission",
    );
    // No sink attached -> no panic, no emit; the test passes if we got here.
}

#[test]
fn error_codes_are_distinct() {
    let codes = [
        WRITE_DENIED,
        BINARY_DENIED,
        TERMINAL_DENIED,
        TERMINAL_NOT_FOUND,
        READ_DENIED,
        PERMISSION_TIMEOUT,
        PERMISSION_CAP_REACHED,
        PERMISSION_RUNTIME_UNSUPPORTED,
        DAEMON_SHUTDOWN,
    ];
    let unique: BTreeSet<_> = codes.iter().collect();
    assert_eq!(unique.len(), codes.len(), "error codes must be distinct");
}
