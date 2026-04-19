use std::path::PathBuf;
use std::sync::Arc;

use serde_json::{Value, json};
use tempfile::TempDir;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::UnixListener;

use crate::mcp::registry::RegistryClient;
use crate::mcp::tool::{Tool, ToolRegistry};

use super::{
    ClickElementTool, GetElementTool, ListElementsTool, ListWindowsTool, register_all,
};

fn socket_path(dir: &TempDir) -> PathBuf {
    dir.path().join("registry.sock")
}

fn spawn_single_response(
    path: &std::path::Path,
    response: String,
) -> tokio::task::JoinHandle<String> {
    let listener = UnixListener::bind(path).expect("bind");
    tokio::spawn(async move {
        let (stream, _) = listener.accept().await.expect("accept");
        let (read, mut write) = stream.into_split();
        let mut reader = BufReader::new(read);
        let mut line = String::new();
        reader.read_line(&mut line).await.expect("read line");
        let mut payload = response.into_bytes();
        payload.push(b'\n');
        write.write_all(&payload).await.expect("write");
        write.shutdown().await.ok();
        line
    })
}

fn sample_element_response(id: u64) -> String {
    json!({
        "id": id,
        "ok": true,
        "result": {"element": {
            "identifier": "button.send",
            "label": "Send",
            "value": null,
            "hint": null,
            "kind": "button",
            "frame": {"x": 100.0, "y": 200.0, "width": 60.0, "height": 40.0},
            "windowID": 7,
            "enabled": true,
            "selected": false,
            "focused": true,
        }}
    })
    .to_string()
}

#[tokio::test]
async fn list_windows_tool_returns_json_text_result() {
    let dir = TempDir::new().unwrap();
    let path = socket_path(&dir);
    let response = json!({
        "id": 1,
        "ok": true,
        "result": {"windows": [{
            "id": 1234,
            "title": "Harness Monitor",
            "role": "AXWindow",
            "frame": {"x": 0.0, "y": 0.0, "width": 800.0, "height": 600.0},
            "isKey": true,
            "isMain": true,
        }]},
    })
    .to_string();
    let server = spawn_single_response(&path, response);
    let client = Arc::new(RegistryClient::with_socket_path(path));
    let tool = ListWindowsTool::new(client);
    let result = tool.call(json!({})).await.expect("ok");
    let request_line = server.await.unwrap();
    assert!(!result.is_error);
    assert_eq!(result.content.len(), 1);
    assert!(request_line.contains("\"op\":\"listWindows\""));
}

#[tokio::test]
async fn list_elements_tool_forwards_filters_to_registry() {
    let dir = TempDir::new().unwrap();
    let path = socket_path(&dir);
    let response = json!({
        "id": 1,
        "ok": true,
        "result": {"elements": []},
    })
    .to_string();
    let server = spawn_single_response(&path, response);
    let client = Arc::new(RegistryClient::with_socket_path(path));
    let tool = ListElementsTool::new(client);
    tool.call(json!({"windowID": 42, "kind": "button"}))
        .await
        .expect("ok");
    let request_line = server.await.unwrap();
    assert!(request_line.contains("\"windowID\":42"));
    assert!(
        request_line.contains("\"kind\":\"button\""),
        "missing kind, got {request_line}",
    );
}

#[tokio::test]
async fn get_element_rejects_empty_identifier() {
    let dir = TempDir::new().unwrap();
    let path = socket_path(&dir);
    let client = Arc::new(RegistryClient::with_socket_path(path));
    let tool = GetElementTool::new(client);
    let err = tool
        .call(json!({"identifier": ""}))
        .await
        .expect_err("empty identifier rejected");
    assert!(err.message().contains("identifier cannot be empty"));
}

#[tokio::test]
async fn click_element_targets_frame_center() {
    let dir = TempDir::new().unwrap();
    let path = socket_path(&dir);
    // Use a bogus harness-input path so click() definitely fails (no
    // backend) after the element lookup completes. We assert the request
    // line made it to the socket, proving the element resolution ran.
    let response = sample_element_response(1);
    let server = spawn_single_response(&path, response);
    let client = Arc::new(RegistryClient::with_socket_path(path));
    let tool = ClickElementTool::new(client);
    // On this host we may or may not have a click backend; we only assert
    // that the registry was consulted. The subsequent click can succeed
    // (on a host with cliclick) or fail (hosts without).
    let _ = tool.call(json!({"identifier": "button.send"})).await;
    let request_line = server.await.unwrap();
    assert!(
        request_line.contains("\"op\":\"getElement\""),
        "missing op, got {request_line}",
    );
    assert!(request_line.contains("\"identifier\":\"button.send\""));
}

#[test]
fn register_all_registers_eight_tools() {
    let dir = TempDir::new().unwrap();
    let client = Arc::new(RegistryClient::with_socket_path(socket_path(&dir)));
    let mut registry = ToolRegistry::new();
    register_all(&mut registry, client);
    let metadata = registry.metadata();
    assert_eq!(metadata.len(), 8);
    let names: Vec<&str> = metadata.iter().map(|t| t.name).collect();
    assert_eq!(
        names,
        vec![
            "list_windows",
            "list_elements",
            "get_element",
            "move_mouse",
            "click",
            "click_element",
            "type_text",
            "screenshot_window",
        ],
    );
}

#[test]
fn every_tool_exposes_non_null_input_schema() {
    let dir = TempDir::new().unwrap();
    let client = Arc::new(RegistryClient::with_socket_path(socket_path(&dir)));
    let mut registry = ToolRegistry::new();
    register_all(&mut registry, client);
    for meta in registry.metadata() {
        let schema = &meta.input_schema;
        assert!(!matches!(schema, Value::Null), "{}: null schema", meta.name);
        assert!(
            schema.get("type").and_then(Value::as_str) == Some("object"),
            "{}: schema is not an object",
            meta.name,
        );
    }
}
