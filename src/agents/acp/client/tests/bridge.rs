use std::collections::BTreeSet;
use std::fs;
use std::thread;
use std::time::Duration;

use agent_client_protocol::schema::{
    CreateTerminalRequest, PermissionOptionId, RequestPermissionOutcome, RequestPermissionRequest,
    RequestPermissionResponse, SelectedPermissionOutcome, ToolCallUpdate, ToolCallUpdateFields,
    WriteTextFileRequest,
};
use tempfile::TempDir;
use tokio::runtime::Builder as TokioRuntimeBuilder;

use crate::agents::acp::client::{
    HarnessAcpClient, PERMISSION_RUNTIME_UNSUPPORTED, PERMISSION_TIMEOUT, TERMINAL_DENIED,
    WRITE_DENIED,
};
use crate::agents::acp::permission::{
    PermissionBridgeRequest, PermissionMode, standard_permission_options,
};

fn setup_client(permission_mode: PermissionMode) -> (TempDir, HarnessAcpClient) {
    let temp = TempDir::new().expect("create temp dir");
    let run_dir = temp.path().to_path_buf();
    let working_dir = temp.path().to_path_buf();

    fs::create_dir_all(run_dir.join("artifacts")).expect("create artifacts");
    fs::create_dir_all(run_dir.join("commands")).expect("create commands");

    let client =
        HarnessAcpClient::new(working_dir, run_dir, None, BTreeSet::new(), permission_mode);
    (temp, client)
}

fn setup_daemon_bridge_client(
    deadline: Duration,
) -> (
    TempDir,
    HarnessAcpClient,
    tokio::sync::mpsc::Receiver<PermissionBridgeRequest>,
) {
    let (tx, rx) = tokio::sync::mpsc::channel(4);
    let (temp, client) = setup_client(PermissionMode::DaemonBridge { tx, deadline });
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

fn permission_request() -> RequestPermissionRequest {
    let tool_call = ToolCallUpdate::new("tool-a", ToolCallUpdateFields::new());
    RequestPermissionRequest::new("session-1", tool_call, standard_permission_options())
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

#[test]
fn daemon_bridge_request_permission_returns_selected_response() {
    let (_temp, client, mut rx) = setup_daemon_bridge_client(Duration::from_secs(1));
    let request = permission_request();

    let handle = thread::spawn(move || client.handle_request_permission(&request));
    let permission = recv_permission(&mut rx);
    permission
        .response_tx
        .send(Ok(permission_response("allow_once")))
        .expect("send approval");

    let response = handle
        .join()
        .expect("permission thread")
        .expect("permission approved");
    assert!(matches!(
        response.outcome,
        RequestPermissionOutcome::Selected(ref selected)
            if selected.option_id.0.as_ref() == "allow_once"
    ));
}

#[test]
fn daemon_bridge_request_permission_times_out_when_bridge_never_replies() {
    let (_temp, client, mut rx) = setup_daemon_bridge_client(Duration::from_millis(20));
    let request = permission_request();

    let handle = thread::spawn(move || client.handle_request_permission(&request));
    let permission = recv_permission(&mut rx);
    thread::sleep(Duration::from_millis(40));
    drop(permission);

    let error = handle
        .join()
        .expect("permission thread")
        .expect_err("permission should time out");
    assert_eq!(error.code, PERMISSION_TIMEOUT);
}

#[test]
fn daemon_bridge_request_permission_returns_selected_response_inside_tokio_multi_thread_runtime() {
    let runtime = TokioRuntimeBuilder::new_multi_thread()
        .worker_threads(2)
        .enable_all()
        .build()
        .expect("build multi-thread runtime");
    runtime.block_on(async {
        let (tx, mut rx) = tokio::sync::mpsc::channel(4);
        let (_temp, client) = setup_client(PermissionMode::DaemonBridge {
            tx,
            deadline: Duration::from_secs(1),
        });
        let request = permission_request();
        let resolver = tokio::spawn(async move {
            let permission = rx.recv().await.expect("permission request");
            permission
                .response_tx
                .send(Ok(permission_response("allow_once")))
                .expect("send approval");
        });

        let response = client
            .handle_request_permission(&request)
            .expect("permission approved");
        resolver.await.expect("resolver task");
        assert!(matches!(
            response.outcome,
            RequestPermissionOutcome::Selected(ref selected)
                if selected.option_id.0.as_ref() == "allow_once"
        ));
    });
}

#[test]
fn daemon_bridge_request_permission_times_out_inside_tokio_multi_thread_runtime() {
    let runtime = TokioRuntimeBuilder::new_multi_thread()
        .worker_threads(2)
        .enable_all()
        .build()
        .expect("build multi-thread runtime");
    runtime.block_on(async {
        let (tx, mut rx) = tokio::sync::mpsc::channel(4);
        let (_temp, client) = setup_client(PermissionMode::DaemonBridge {
            tx,
            deadline: Duration::from_millis(20),
        });
        let request = permission_request();
        let delayed_drop = tokio::spawn(async move {
            let permission = rx.recv().await.expect("permission request");
            tokio::time::sleep(Duration::from_millis(40)).await;
            drop(permission);
        });

        let error = client
            .handle_request_permission(&request)
            .expect_err("permission should time out");
        delayed_drop.await.expect("delayed drop task");
        assert_eq!(error.code, PERMISSION_TIMEOUT);
    });
}

#[test]
fn daemon_bridge_request_permission_rejects_tokio_current_thread_runtime() {
    let runtime = TokioRuntimeBuilder::new_current_thread()
        .enable_all()
        .build()
        .expect("build current-thread runtime");
    runtime.block_on(async {
        let (tx, mut rx) = tokio::sync::mpsc::channel(4);
        let (_temp, client) = setup_client(PermissionMode::DaemonBridge {
            tx,
            deadline: Duration::from_secs(1),
        });
        let request = permission_request();

        let error = client
            .handle_request_permission(&request)
            .expect_err("current-thread runtime should be rejected");
        assert_eq!(error.code, PERMISSION_RUNTIME_UNSUPPORTED);
        assert!(
            rx.try_recv().is_err(),
            "unsupported runtime must not enqueue request"
        );
    });
}

#[test]
fn daemon_bridge_write_preserves_runtime_unsupported_inside_tokio_current_thread_runtime() {
    let runtime = TokioRuntimeBuilder::new_current_thread()
        .enable_all()
        .build()
        .expect("build current-thread runtime");
    runtime.block_on(async {
        let (tx, mut rx) = tokio::sync::mpsc::channel(4);
        let (temp, client) = setup_client(PermissionMode::DaemonBridge {
            tx,
            deadline: Duration::from_secs(1),
        });
        let path = temp.path().join("artifacts/runtime-unsupported-write.txt");
        let request = WriteTextFileRequest::new("test-session", &path, "hello");

        let error = client
            .handle_write_text_file(&request)
            .expect_err("current-thread runtime should be rejected");
        assert_eq!(error.code, PERMISSION_RUNTIME_UNSUPPORTED);
        assert!(
            rx.try_recv().is_err(),
            "unsupported runtime must not enqueue request"
        );
        assert!(!path.exists(), "unsupported runtime must not write");
    });
}

#[test]
fn daemon_bridge_terminal_preserves_runtime_unsupported_inside_tokio_current_thread_runtime() {
    let runtime = TokioRuntimeBuilder::new_current_thread()
        .enable_all()
        .build()
        .expect("build current-thread runtime");
    runtime.block_on(async {
        let (tx, mut rx) = tokio::sync::mpsc::channel(4);
        let (_temp, client) = setup_client(PermissionMode::DaemonBridge {
            tx,
            deadline: Duration::from_secs(1),
        });
        let request = CreateTerminalRequest::new("test-session", "sh")
            .args(vec!["-c".to_string(), "printf unsupported".to_string()]);

        let error = client
            .handle_create_terminal(&request)
            .expect_err("current-thread runtime should be rejected");
        assert_eq!(error.code, PERMISSION_RUNTIME_UNSUPPORTED);
        assert!(
            rx.try_recv().is_err(),
            "unsupported runtime must not enqueue request"
        );
    });
}
