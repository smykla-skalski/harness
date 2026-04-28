use std::collections::BTreeSet;
use std::fs;
use std::thread;
use std::time::Duration;

use agent_client_protocol::schema::{
    CreateTerminalRequest, PermissionOptionId, RequestPermissionOutcome, RequestPermissionResponse,
    SelectedPermissionOutcome, WriteTextFileRequest,
};
use tempfile::TempDir;

use super::{HarnessAcpClient, TERMINAL_DENIED, WRITE_DENIED};
use crate::agents::acp::permission::{PermissionBridgeRequest, PermissionMode};

fn setup_daemon_bridge_client(
    deadline: Duration,
) -> (
    TempDir,
    HarnessAcpClient,
    tokio::sync::mpsc::Receiver<PermissionBridgeRequest>,
) {
    let temp = TempDir::new().expect("create temp dir");
    let run_dir = temp.path().to_path_buf();
    let working_dir = temp.path().to_path_buf();

    fs::create_dir_all(run_dir.join("artifacts")).expect("create artifacts");
    fs::create_dir_all(run_dir.join("commands")).expect("create commands");

    let (tx, rx) = tokio::sync::mpsc::channel(4);
    let client = HarnessAcpClient::new(
        working_dir,
        run_dir,
        None,
        BTreeSet::new(),
        PermissionMode::DaemonBridge { tx, deadline },
    );
    (temp, client, rx)
}

fn permission_response(option_id: &str) -> RequestPermissionResponse {
    RequestPermissionResponse::new(RequestPermissionOutcome::Selected(
        SelectedPermissionOutcome::new(PermissionOptionId::new(option_id)),
    ))
}

fn recv_permission(
    rx: &mut tokio::sync::mpsc::Receiver<PermissionBridgeRequest>,
) -> PermissionBridgeRequest {
    rx.blocking_recv().expect("permission request")
}

#[test]
fn daemon_bridge_write_waits_for_permission_before_writing() {
    let (temp, client, mut rx) = setup_daemon_bridge_client(Duration::from_secs(1));
    let path = temp.path().join("artifacts/bridge-write.txt");
    let request = WriteTextFileRequest::new("test-session", &path, "hello");

    let handle = thread::spawn(move || client.handle_write_text_file(&request));
    let permission = recv_permission(&mut rx);
    assert!(!path.exists(), "write must not happen before approval");
    let raw_input = permission
        .request
        .tool_call
        .fields
        .raw_input
        .expect("raw input");
    assert_eq!(raw_input["kind"], "fs.write_text_file");
    permission
        .response_tx
        .send(Ok(permission_response("allow_once")))
        .expect("send approval");

    handle
        .join()
        .expect("write thread")
        .expect("write approved");
    assert_eq!(fs::read_to_string(path).expect("written file"), "hello");
}

#[test]
fn daemon_bridge_write_denial_returns_json_rpc_error_without_writing() {
    let (temp, client, mut rx) = setup_daemon_bridge_client(Duration::from_secs(1));
    let path = temp.path().join("artifacts/bridge-denied.txt");
    let request = WriteTextFileRequest::new("test-session", &path, "hello");

    let handle = thread::spawn(move || client.handle_write_text_file(&request));
    let permission = recv_permission(&mut rx);
    permission
        .response_tx
        .send(Ok(permission_response("reject_once")))
        .expect("send rejection");

    let error = handle
        .join()
        .expect("write thread")
        .expect_err("write denied");
    assert_eq!(error.code, WRITE_DENIED);
    assert!(!path.exists(), "denied write must not create file");
}

#[test]
fn daemon_bridge_terminal_waits_for_permission_before_spawning() {
    let (_temp, client, mut rx) = setup_daemon_bridge_client(Duration::from_secs(1));
    let request = CreateTerminalRequest::new("test-session", "sh")
        .args(vec!["-c".to_string(), "printf approved".to_string()]);

    let handle = thread::spawn(move || client.handle_create_terminal(&request));
    let permission = recv_permission(&mut rx);
    let raw_input = permission
        .request
        .tool_call
        .fields
        .raw_input
        .expect("raw input");
    assert_eq!(raw_input["kind"], "terminal.create");
    permission
        .response_tx
        .send(Ok(permission_response("allow_once")))
        .expect("send approval");

    let response = handle
        .join()
        .expect("terminal thread")
        .expect("terminal approved");
    assert_eq!(response.terminal_id.0.as_ref(), "terminal-1");
}

#[test]
fn daemon_bridge_terminal_denial_returns_json_rpc_error() {
    let (_temp, client, mut rx) = setup_daemon_bridge_client(Duration::from_secs(1));
    let request = CreateTerminalRequest::new("test-session", "sh")
        .args(vec!["-c".to_string(), "printf denied".to_string()]);

    let handle = thread::spawn(move || client.handle_create_terminal(&request));
    let permission = recv_permission(&mut rx);
    permission
        .response_tx
        .send(Ok(permission_response("reject_once")))
        .expect("send rejection");

    let error = handle
        .join()
        .expect("terminal thread")
        .expect_err("terminal denied");
    assert_eq!(error.code, TERMINAL_DENIED);
}
