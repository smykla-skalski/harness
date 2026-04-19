use std::path::PathBuf;
use std::time::Duration;

use serde_json::{Value, json};
use tempfile::TempDir;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::UnixListener;
use tokio::sync::oneshot;

use super::client::{RegistryClient, RegistryError};
use super::path::{SOCKET_OVERRIDE_ENV, default_socket_path};
use super::types::{ListWindowsResult, RegistryRequest};

fn socket_path(dir: &TempDir) -> PathBuf {
    dir.path().join("registry.sock")
}

async fn spawn_fake_server<F>(path: PathBuf, responder: F) -> oneshot::Receiver<String>
where
    F: Fn(&str) -> String + Send + 'static,
{
    let (tx, rx) = oneshot::channel();
    let listener = UnixListener::bind(&path).expect("bind test socket");
    tokio::spawn(async move {
        let (stream, _) = listener.accept().await.expect("accept");
        let (read, mut write) = stream.into_split();
        let mut reader = BufReader::new(read);
        let mut line = String::new();
        reader
            .read_line(&mut line)
            .await
            .expect("read request line");
        let response = responder(line.trim_end_matches('\n'));
        let mut payload = response.into_bytes();
        payload.push(b'\n');
        write.write_all(&payload).await.expect("write response");
        write.shutdown().await.ok();
        let _ = tx.send(line);
    });
    rx
}

#[tokio::test]
async fn request_returns_typed_ok_result() {
    let dir = TempDir::new().unwrap();
    let path = socket_path(&dir);
    let received = spawn_fake_server(path.clone(), |line| {
        let parsed: Value = serde_json::from_str(line).unwrap();
        let id = parsed.get("id").and_then(Value::as_u64).unwrap();
        json!({
            "id": id,
            "ok": true,
            "result": {"windows": []},
        })
        .to_string()
    })
    .await;

    let client = RegistryClient::with_socket_path(path);
    let id = client.next_request_id();
    let result: ListWindowsResult = client
        .request(&RegistryRequest::ListWindows { id })
        .await
        .expect("ok result");
    assert!(result.windows.is_empty());
    let line = received.await.unwrap();
    assert!(line.contains("\"op\":\"listWindows\""));
}

#[tokio::test]
async fn request_surfaces_server_error() {
    let dir = TempDir::new().unwrap();
    let path = socket_path(&dir);
    spawn_fake_server(path.clone(), |line| {
        let parsed: Value = serde_json::from_str(line).unwrap();
        let id = parsed.get("id").and_then(Value::as_u64).unwrap();
        json!({
            "id": id,
            "ok": false,
            "error": {"code": "not-found", "message": "no element"},
        })
        .to_string()
    })
    .await;

    let client = RegistryClient::with_socket_path(path);
    let id = client.next_request_id();
    let err = client
        .request::<ListWindowsResult>(&RegistryRequest::ListWindows { id })
        .await
        .expect_err("server error");
    match err {
        RegistryError::Server { code, message } => {
            assert_eq!(code, "not-found");
            assert_eq!(message, "no element");
        }
        other => panic!("expected server error, got {other:?}"),
    }
}

#[tokio::test]
async fn request_returns_unavailable_when_socket_missing() {
    let dir = TempDir::new().unwrap();
    let missing = dir.path().join("never-created.sock");
    let client = RegistryClient::with_socket_path(missing.clone());
    let id = client.next_request_id();
    let err = client
        .request::<ListWindowsResult>(&RegistryRequest::ListWindows { id })
        .await
        .expect_err("missing socket");
    match err {
        RegistryError::Unavailable { path, .. } => assert_eq!(path, missing),
        other => panic!("expected Unavailable, got {other:?}"),
    }
}

#[tokio::test]
async fn request_times_out_when_server_is_silent() {
    let dir = TempDir::new().unwrap();
    let path = socket_path(&dir);
    let listener = UnixListener::bind(&path).expect("bind");
    tokio::spawn(async move {
        let _conn = listener.accept().await.expect("accept");
        // Hold the connection open without responding.
        tokio::time::sleep(Duration::from_secs(2)).await;
    });

    let client = RegistryClient::with_socket_path(path)
        .with_timeouts(Duration::from_millis(500), Duration::from_millis(200));
    let id = client.next_request_id();
    let err = client
        .request::<ListWindowsResult>(&RegistryRequest::ListWindows { id })
        .await
        .expect_err("timeout");
    assert!(matches!(err, RegistryError::Timeout { .. }));
}

#[tokio::test]
async fn request_detects_id_mismatch_as_protocol_error() {
    let dir = TempDir::new().unwrap();
    let path = socket_path(&dir);
    spawn_fake_server(path.clone(), |_| {
        json!({
            "id": 999,
            "ok": true,
            "result": {"windows": []},
        })
        .to_string()
    })
    .await;

    let client = RegistryClient::with_socket_path(path);
    let id = client.next_request_id();
    let err = client
        .request::<ListWindowsResult>(&RegistryRequest::ListWindows { id })
        .await
        .expect_err("id mismatch");
    assert!(matches!(err, RegistryError::Protocol { .. }));
}

#[test]
fn default_socket_path_respects_override_env() {
    temp_env::with_var(SOCKET_OVERRIDE_ENV, Some("/tmp/custom.sock"), || {
        assert_eq!(default_socket_path(), PathBuf::from("/tmp/custom.sock"));
    });
}

#[test]
fn default_socket_path_falls_back_to_group_container() {
    temp_env::with_vars(
        [
            (SOCKET_OVERRIDE_ENV, None::<&str>),
            ("HOME", Some("/Users/fake")),
        ],
        || {
            let path = default_socket_path();
            let text = path.to_string_lossy();
            assert!(text.starts_with("/Users/fake/Library/Group Containers/"));
            assert!(text.ends_with("/harness-monitor-mcp.sock"));
        },
    );
}
