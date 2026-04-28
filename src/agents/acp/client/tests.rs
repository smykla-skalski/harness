//! Tests for ACP client handlers.

use std::collections::BTreeSet;
use std::fs;
use std::path::PathBuf;
use std::sync::Arc;
use std::thread;
use std::time::{Duration, Instant};

use agent_client_protocol::schema::{
    CreateTerminalRequest, KillTerminalRequest, ReadTextFileRequest, ReleaseTerminalRequest,
    RequestPermissionRequest, TerminalOutputRequest, ToolCallUpdate, ToolCallUpdateFields,
    WaitForTerminalExitRequest, WriteTextFileRequest,
};
use tempfile::TempDir;

use super::{
    BINARY_DENIED, DAEMON_SHUTDOWN, HarnessAcpClient, PERMISSION_CAP_REACHED, PERMISSION_TIMEOUT,
    READ_DENIED, TERMINAL_DENIED, TERMINAL_NOT_FOUND, WRITE_DENIED,
};
use crate::agents::acp::permission::{PermissionMode, standard_permission_options};

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
fn terminal_denied_binary_path_rejected_by_basename() {
    let (_temp, client) = setup_client();

    let request = CreateTerminalRequest::new("test-session", "/usr/local/bin/kubectl");
    let result = client.handle_create_terminal(&request);

    assert!(result.is_err());
    let err = result.unwrap_err();
    assert_eq!(err.code, TERMINAL_DENIED);
}

#[test]
fn terminal_denied_binary_rejected_through_common_wrappers() {
    let (_temp, client) = setup_client();

    let shell = CreateTerminalRequest::new("test-session", "sh")
        .args(vec!["-c".to_string(), "exec kubectl get pods".to_string()]);
    let env = CreateTerminalRequest::new("test-session", "env").args(vec![
        "KUBECONFIG=/tmp/config".to_string(),
        "kubectl".to_string(),
    ]);

    assert_eq!(
        client
            .handle_create_terminal(&shell)
            .expect_err("shell wrapper should be denied")
            .code,
        TERMINAL_DENIED
    );
    assert_eq!(
        client
            .handle_create_terminal(&env)
            .expect_err("env wrapper should be denied")
            .code,
        TERMINAL_DENIED
    );
}

#[test]
fn terminal_output_for_running_process_returns_promptly() {
    let (_temp, client) = setup_client();

    let create = CreateTerminalRequest::new("test-session", "sh")
        .args(vec!["-c".to_string(), "printf ready; sleep 2".to_string()]);
    let terminal = client
        .handle_create_terminal(&create)
        .expect("create terminal")
        .terminal_id;

    let start = Instant::now();
    let output = client
        .handle_terminal_output(&TerminalOutputRequest::new(
            "test-session",
            terminal.clone(),
        ))
        .expect("terminal output");

    assert!(
        start.elapsed() < Duration::from_secs(1),
        "terminal/output must not block on a live process"
    );
    assert!(output.exit_status.is_none());

    client
        .handle_kill_terminal(&KillTerminalRequest::new("test-session", terminal))
        .expect("kill terminal");
}

#[test]
fn terminal_wait_then_output_returns_exit_status_and_output() {
    let (_temp, client) = setup_client();

    let create = CreateTerminalRequest::new("test-session", "sh")
        .args(vec!["-c".to_string(), "printf hello".to_string()]);
    let terminal = client
        .handle_create_terminal(&create)
        .expect("create terminal")
        .terminal_id;

    let wait = client
        .handle_wait_for_terminal_exit(&WaitForTerminalExitRequest::new(
            "test-session",
            terminal.clone(),
        ))
        .expect("wait terminal");
    assert_eq!(wait.exit_status.exit_code, Some(0));

    let output = client
        .handle_terminal_output(&TerminalOutputRequest::new("test-session", terminal))
        .expect("terminal output");

    assert!(output.output.contains("hello"), "{output:?}");
    assert_eq!(output.exit_status, Some(wait.exit_status));
}

#[test]
fn terminal_wait_on_one_terminal_does_not_block_output_for_another() {
    let (_temp, client) = setup_client();
    let client = Arc::new(client);

    let slow = client
        .handle_create_terminal(
            &CreateTerminalRequest::new("test-session", "sh")
                .args(vec!["-c".to_string(), "sleep 2".to_string()]),
        )
        .expect("create slow terminal")
        .terminal_id;
    let quick = client
        .handle_create_terminal(
            &CreateTerminalRequest::new("test-session", "sh")
                .args(vec!["-c".to_string(), "printf quick".to_string()]),
        )
        .expect("create quick terminal")
        .terminal_id;

    let wait_client = Arc::clone(&client);
    let wait_terminal = slow.clone();
    let wait_thread = thread::spawn(move || {
        wait_client.handle_wait_for_terminal_exit(&WaitForTerminalExitRequest::new(
            "test-session",
            wait_terminal,
        ))
    });

    thread::sleep(Duration::from_millis(100));

    let start = Instant::now();
    let output = client
        .handle_terminal_output(&TerminalOutputRequest::new("test-session", quick.clone()))
        .expect("terminal output");

    assert!(
        start.elapsed() < Duration::from_secs(1),
        "wait on one terminal must not block output from another"
    );
    assert!(output.output.contains("quick"), "{output:?}");

    wait_thread
        .join()
        .expect("wait thread")
        .expect("wait terminal");
    client
        .handle_release_terminal(&ReleaseTerminalRequest::new("test-session", slow))
        .expect("release slow terminal");
    client
        .handle_release_terminal(&ReleaseTerminalRequest::new("test-session", quick))
        .expect("release quick terminal");
}

#[test]
fn terminal_wait_returns_when_background_child_keeps_pty_open() {
    let (_temp, client) = setup_client();

    let terminal = client
        .handle_create_terminal(
            &CreateTerminalRequest::new("test-session", "sh")
                .args(vec!["-c".to_string(), "sleep 1 & exit 0".to_string()]),
        )
        .expect("create terminal")
        .terminal_id;

    let start = Instant::now();
    client
        .handle_wait_for_terminal_exit(&WaitForTerminalExitRequest::new(
            "test-session",
            terminal.clone(),
        ))
        .expect("wait terminal");

    assert!(
        start.elapsed() < Duration::from_secs(1),
        "wait should not block on the detached PTY reader"
    );

    client
        .handle_release_terminal(&ReleaseTerminalRequest::new("test-session", terminal))
        .expect("release terminal");
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
fn error_codes_are_distinct() {
    let codes = [
        WRITE_DENIED,
        BINARY_DENIED,
        TERMINAL_DENIED,
        TERMINAL_NOT_FOUND,
        READ_DENIED,
        PERMISSION_TIMEOUT,
        PERMISSION_CAP_REACHED,
        DAEMON_SHUTDOWN,
    ];
    let unique: BTreeSet<_> = codes.iter().collect();
    assert_eq!(unique.len(), codes.len(), "error codes must be distinct");
}
