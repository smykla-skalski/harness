//! Tests for ACP client handlers.

mod bridge;
mod terminal;

use std::collections::BTreeSet;
use std::fs;
use std::path::PathBuf;
use std::time::Duration;

use agent_client_protocol::schema::{
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

pub(super) fn setup_client() -> (TempDir, HarnessAcpClient) {
    let temp = TempDir::new().expect("create temp dir");
    let run_dir = temp.path().to_path_buf();
    let working_dir = temp.path().to_path_buf();

    fs::create_dir_all(run_dir.join("artifacts")).expect("create artifacts");
    fs::create_dir_all(run_dir.join("commands")).expect("create commands");

    let mut denied = BTreeSet::new();
    denied.insert("kubectl".to_string());
    denied.insert("kumactl".to_string());

    let client = HarnessAcpClient::new(
        working_dir,
        run_dir.clone(),
        None,
        denied,
        PermissionMode::Recording {
            log_path: run_dir.join("permission-log.ndjson"),
        },
    );

    (temp, client)
}

pub(super) fn setup_recording_client() -> (TempDir, HarnessAcpClient, PathBuf) {
    let temp = TempDir::new().expect("create temp dir");
    let run_dir = temp.path().to_path_buf();
    let working_dir = temp.path().to_path_buf();
    let log_path = run_dir.join("permission-log.ndjson");

    fs::create_dir_all(run_dir.join("artifacts")).expect("create artifacts");
    fs::create_dir_all(run_dir.join("commands")).expect("create commands");

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
    fs::read_to_string(path)
        .expect("permission log")
        .lines()
        .map(|line| serde_json::from_str(line).expect("json line"))
        .collect()
}

#[test]
fn write_to_artifacts_allowed() {
    let (temp, client) = setup_client();
    let path = temp.path().join("artifacts/test.txt");

    let request = WriteTextFileRequest::new("test-session", &path, "hello");
    client
        .handle_write_text_file(&request)
        .expect("write to artifacts allowed");
    assert_eq!(fs::read_to_string(&path).unwrap(), "hello");
}

#[test]
fn write_outside_surface_denied() {
    let (_temp, client) = setup_client();
    let path = PathBuf::from("/tmp/outside.txt");

    let request = WriteTextFileRequest::new("test-session", &path, "hello");
    let result = client.handle_write_text_file(&request);

    assert!(result.is_err());
    let err = result.unwrap_err();
    assert_eq!(err.code, WRITE_DENIED);
}

#[test]
fn write_denied_binary_rejected() {
    let (temp, client) = setup_client();
    let path = temp.path().join("artifacts/kubectl");

    let request = WriteTextFileRequest::new("test-session", &path, "#!/bin/bash");
    let result = client.handle_write_text_file(&request);

    assert!(result.is_err());
    let err = result.unwrap_err();
    assert_eq!(err.code, BINARY_DENIED);
}

#[test]
fn recording_write_logs_policy_decision_and_still_writes_when_allowed() {
    let (temp, client, log_path) = setup_recording_client();
    let path = temp.path().join("artifacts/test.txt");
    let request = WriteTextFileRequest::new("session-1", &path, "hello");

    client
        .handle_write_text_file(&request)
        .expect("write allowed");

    let records = read_log(&log_path);
    assert_eq!(records.len(), 1);
    assert_eq!(records[0]["operation"], "fs.write_text_file");
    assert_eq!(records[0]["decision"], "allowed");
    assert_eq!(records[0]["wouldAsk"]["path"], path.display().to_string());
    assert_eq!(fs::read_to_string(path).expect("written file"), "hello");
}

#[test]
fn recording_write_logs_denial_aligned_with_policy() {
    let (temp, client, log_path) = setup_recording_client();
    let path = temp.path().join("artifacts/kubectl");
    let request = WriteTextFileRequest::new("session-1", &path, "#!/bin/sh");

    let error = client
        .handle_write_text_file(&request)
        .expect_err("denied binary");

    assert_eq!(error.code, BINARY_DENIED);
    let records = read_log(&log_path);
    assert_eq!(records.len(), 1);
    assert_eq!(records[0]["operation"], "fs.write_text_file");
    assert_eq!(records[0]["decision"], "denied");
    assert!(
        records[0]["reason"]
            .as_str()
            .expect("reason")
            .contains("kubectl")
    );
}

#[test]
fn recording_write_logs_denial_when_allowed_path_fails_to_write() {
    let (temp, client, log_path) = setup_recording_client();
    let path = temp.path().join("artifacts/existing-dir");
    fs::create_dir_all(&path).expect("create existing directory");
    let request = WriteTextFileRequest::new("session-1", &path, "hello");

    let error = client
        .handle_write_text_file(&request)
        .expect_err("cannot write file over directory");

    assert_eq!(error.code, WRITE_DENIED);
    let records = read_log(&log_path);
    assert_eq!(records.len(), 1);
    assert_eq!(records[0]["operation"], "fs.write_text_file");
    assert_eq!(records[0]["decision"], "denied");
    assert!(
        records[0]["reason"]
            .as_str()
            .expect("reason")
            .contains("failed to write")
    );
}

#[test]
fn read_within_working_dir_allowed() {
    let (temp, client) = setup_client();
    let path = temp.path().join("test.txt");
    fs::write(&path, "content").unwrap();

    let request = ReadTextFileRequest::new("test-session", &path);
    assert_eq!(
        client
            .handle_read_text_file(&request)
            .expect("read within working dir")
            .content,
        "content"
    );
}

#[test]
fn read_with_line_and_limit() {
    let (temp, client) = setup_client();
    let path = temp.path().join("lines.txt");
    fs::write(&path, "line1\nline2\nline3\nline4").unwrap();

    let mut request = ReadTextFileRequest::new("test-session", &path);
    request.line = Some(2);
    request.limit = Some(2);
    assert_eq!(
        client
            .handle_read_text_file(&request)
            .expect("read with line and limit")
            .content,
        "line2\nline3"
    );
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

    let error = client
        .handle_request_permission(&request)
        .expect_err("closed bridge should fail");

    assert_eq!(error.code, DAEMON_SHUTDOWN);
}

#[test]
fn recording_permission_request_never_blocks_or_approves() {
    let (_temp, client, log_path) = setup_recording_client();
    let tool_call = ToolCallUpdate::new("tool-a", ToolCallUpdateFields::new());
    let request =
        RequestPermissionRequest::new("session-1", tool_call, standard_permission_options());

    let response = client
        .handle_request_permission(&request)
        .expect("record permission");

    assert!(matches!(
        response.outcome,
        RequestPermissionOutcome::Selected(ref selected)
            if selected.option_id.0.as_ref() == "reject_once"
    ));
    let records = read_log(&log_path);
    assert_eq!(records.len(), 1);
    assert_eq!(records[0]["operation"], "session.request_permission");
    assert_eq!(records[0]["decision"], "recorded_reject");
    assert_eq!(records[0]["wouldAsk"]["toolCall"]["toolCallId"], "tool-a");
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
