//! Tests for ACP client handlers.

use std::collections::BTreeSet;
use std::fs;
use std::path::PathBuf;

use agent_client_protocol::schema::{
    CreateTerminalRequest, ReadTextFileRequest, WriteTextFileRequest,
};
use tempfile::TempDir;

use super::{
    BINARY_DENIED, DAEMON_SHUTDOWN, HarnessAcpClient, PERMISSION_TIMEOUT, READ_DENIED,
    TERMINAL_DENIED, TERMINAL_NOT_FOUND, WRITE_DENIED,
};
use crate::agents::acp::permission::PermissionMode;

fn setup_client() -> (TempDir, HarnessAcpClient) {
    let temp = TempDir::new().expect("create temp dir");
    let run_dir = temp.path().to_path_buf();
    let working_dir = temp.path().to_path_buf();

    fs::create_dir_all(run_dir.join("artifacts")).expect("create artifacts");
    fs::create_dir_all(run_dir.join("commands")).expect("create commands");

    let mut denied = BTreeSet::new();
    denied.insert("kubectl".to_string());
    denied.insert("kumactl".to_string());

    let client = HarnessAcpClient::new(working_dir, run_dir, None, denied, PermissionMode::Stdin);

    (temp, client)
}

#[test]
fn write_to_artifacts_allowed() {
    let (temp, client) = setup_client();
    let path = temp.path().join("artifacts/test.txt");

    let request = WriteTextFileRequest::new("test-session", &path, "hello");
    let result = client.handle_write_text_file(&request);

    assert!(result.is_ok());
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
fn read_within_working_dir_allowed() {
    let (temp, client) = setup_client();
    let path = temp.path().join("test.txt");
    fs::write(&path, "content").unwrap();

    let request = ReadTextFileRequest::new("test-session", &path);
    let result = client.handle_read_text_file(&request);

    assert!(result.is_ok());
    assert_eq!(result.unwrap().content, "content");
}

#[test]
fn read_with_line_and_limit() {
    let (temp, client) = setup_client();
    let path = temp.path().join("lines.txt");
    fs::write(&path, "line1\nline2\nline3\nline4").unwrap();

    let mut request = ReadTextFileRequest::new("test-session", &path);
    request.line = Some(2);
    request.limit = Some(2);
    let result = client.handle_read_text_file(&request);

    assert!(result.is_ok());
    assert_eq!(result.unwrap().content, "line2\nline3");
}

#[test]
fn terminal_denied_binary_rejected() {
    let (_temp, client) = setup_client();

    let request = CreateTerminalRequest::new("test-session", "kubectl");
    let result = client.handle_create_terminal(&request);

    assert!(result.is_err());
    let err = result.unwrap_err();
    assert_eq!(err.code, TERMINAL_DENIED);
}

#[test]
fn terminal_cap_enforced() {
    let (_temp, client) = setup_client();

    for i in 0..16 {
        let request = CreateTerminalRequest::new("test-session", "echo").args(vec![format!("{i}")]);
        let result = client.handle_create_terminal(&request);
        assert!(result.is_ok(), "terminal {i} should succeed");
    }

    let request = CreateTerminalRequest::new("test-session", "echo").args(vec!["17".to_string()]);
    let result = client.handle_create_terminal(&request);

    assert!(result.is_err());
    let err = result.unwrap_err();
    assert_eq!(err.code, TERMINAL_DENIED);
    assert!(err.message.contains("cap"));
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
        DAEMON_SHUTDOWN,
    ];
    let unique: BTreeSet<_> = codes.iter().collect();
    assert_eq!(unique.len(), codes.len(), "error codes must be distinct");
}
