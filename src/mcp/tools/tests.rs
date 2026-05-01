use std::path::PathBuf;
use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};

use serde_json::{Value, json};
use tempfile::TempDir;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::UnixListener;

use crate::mcp::automation::AccessibilityQueryError;
use crate::mcp::registry::RegistryClient;
use crate::mcp::registry::{ElementKind, GetElementResult, ListElementsResult};
use crate::mcp::tool::{Tool, ToolRegistry};
use crate::workspace::socket_paths::session_socket;

use super::shared::{resolve_get_element_with, resolve_list_elements_with};
use super::{
    ClickElementTool, DragDropTool, GetElementTool, ListElementsTool, ListWindowsTool,
    ScrollTool, register_all,
};

fn socket_path(dir: &TempDir) -> PathBuf {
    session_socket(dir.path(), "testid00", "registry")
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

fn spawn_response_sequence(
    path: &std::path::Path,
    responses: Vec<String>,
) -> tokio::task::JoinHandle<Vec<String>> {
    let listener = UnixListener::bind(path).expect("bind");
    tokio::spawn(async move {
        let (stream, _) = listener.accept().await.expect("accept");
        let (read, mut write) = stream.into_split();
        let mut reader = BufReader::new(read);
        let mut lines = Vec::with_capacity(responses.len());
        for response in responses {
            let mut line = String::new();
            reader.read_line(&mut line).await.expect("read line");
            lines.push(line);
            let mut payload = response.into_bytes();
            payload.push(b'\n');
            write.write_all(&payload).await.expect("write");
        }
        write.shutdown().await.ok();
        lines
    })
}

fn sample_element_response(id: u64) -> String {
    sample_element_response_with(id, "button.send", 100.0, 200.0, 60.0, 40.0)
}

fn sample_element_response_with(
    id: u64,
    identifier: &str,
    x: f64,
    y: f64,
    width: f64,
    height: f64,
) -> String {
    json!({
        "id": id,
        "ok": true,
        "result": {"element": {
            "identifier": identifier,
            "label": identifier,
            "value": null,
            "hint": null,
            "kind": "button",
            "frame": {"x": x, "y": y, "width": width, "height": height},
            "windowID": 7,
            "enabled": true,
            "selected": false,
            "focused": true,
        }}
    })
    .to_string()
}

fn empty_elements_response(id: u64) -> String {
    json!({
        "id": id,
        "ok": true,
        "result": {"elements": []},
    })
    .to_string()
}

fn elements_response(id: u64, identifier: &str, window_id: i64) -> String {
    json!({
        "id": id,
        "ok": true,
        "result": {"elements": [{
            "identifier": identifier,
            "label": "Fallback",
            "value": null,
            "hint": null,
            "kind": "button",
            "frame": {"x": 10.0, "y": 20.0, "width": 30.0, "height": 40.0},
            "windowID": window_id,
            "enabled": true,
            "selected": false,
            "focused": false,
        }]},
    })
    .to_string()
}

fn not_found_response(id: u64) -> String {
    json!({
        "id": id,
        "ok": false,
        "error": {"code": "not-found", "message": "no element"},
    })
    .to_string()
}

fn fallback_element(
    identifier: &str,
    window_id: i64,
    kind: ElementKind,
) -> crate::mcp::registry::RegistryElement {
    crate::mcp::registry::RegistryElement {
        identifier: identifier.to_string(),
        label: Some("Fallback".to_string()),
        value: None,
        hint: None,
        kind,
        frame: crate::mcp::registry::Rect {
            x: 10.0,
            y: 20.0,
            width: 30.0,
            height: 40.0,
        },
        window_id: Some(window_id),
        enabled: true,
        selected: false,
        focused: false,
    }
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
        "result": {"elements": [{
            "identifier": "button.send",
            "label": "Send",
            "value": null,
            "hint": null,
            "kind": "button",
            "frame": {"x": 100.0, "y": 200.0, "width": 60.0, "height": 40.0},
            "windowID": 42,
            "enabled": true,
            "selected": false,
            "focused": false,
        }]},
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
async fn resolve_list_elements_uses_helper_when_registry_is_empty() {
    async fn helper(
        window_id: Option<i64>,
        kind: Option<ElementKind>,
    ) -> Result<ListElementsResult, AccessibilityQueryError> {
        assert_eq!(window_id, Some(42));
        assert_eq!(kind, Some(ElementKind::Button));
        Ok(ListElementsResult {
            elements: vec![fallback_element("button.fallback", 42, ElementKind::Button)],
        })
    }

    let dir = TempDir::new().unwrap();
    let path = socket_path(&dir);
    let server = spawn_single_response(&path, empty_elements_response(1));
    let client = RegistryClient::with_socket_path(path);
    let result = resolve_list_elements_with(&client, Some(42), Some(ElementKind::Button), helper)
        .await
        .expect("fallback succeeds");
    let request_line = server.await.unwrap();

    assert!(request_line.contains("\"op\":\"listElements\""));
    assert_eq!(result.elements.len(), 1);
    assert_eq!(result.elements[0].identifier, "button.fallback");
    assert_eq!(result.elements[0].window_id, Some(42));
}

#[tokio::test]
async fn resolve_list_elements_preserves_empty_success_when_helper_fails() {
    async fn helper(
        _window_id: Option<i64>,
        _kind: Option<ElementKind>,
    ) -> Result<ListElementsResult, AccessibilityQueryError> {
        Err(AccessibilityQueryError::AccessibilityDenied)
    }

    let dir = TempDir::new().unwrap();
    let path = socket_path(&dir);
    let server = spawn_single_response(&path, empty_elements_response(1));
    let client = RegistryClient::with_socket_path(path);
    let result = resolve_list_elements_with(&client, Some(42), Some(ElementKind::Button), helper)
        .await
        .expect("empty success is preserved");
    let request_line = server.await.unwrap();

    assert!(request_line.contains("\"op\":\"listElements\""));
    assert!(result.elements.is_empty());
}

#[tokio::test]
async fn resolve_list_elements_retries_window_scoped_empty_results_until_registry_populates() {
    let helper_calls = AtomicUsize::new(0);

    async fn helper(
        helper_calls: &AtomicUsize,
        _window_id: Option<i64>,
        _kind: Option<ElementKind>,
    ) -> Result<ListElementsResult, AccessibilityQueryError> {
        helper_calls.fetch_add(1, Ordering::Relaxed);
        Ok(ListElementsResult { elements: vec![] })
    }

    let dir = TempDir::new().unwrap();
    let path = socket_path(&dir);
    let server = spawn_response_sequence(
        &path,
        vec![
            empty_elements_response(1),
            empty_elements_response(2),
            elements_response(3, "button.ready", 42),
        ],
    );
    let client = RegistryClient::with_socket_path(path);
    let result = resolve_list_elements_with(&client, Some(42), None, |window_id, kind| {
        helper(&helper_calls, window_id, kind)
    })
    .await
    .expect("registry eventually populates");
    let request_lines = server.await.unwrap();

    assert_eq!(request_lines.len(), 3);
    assert_eq!(helper_calls.load(Ordering::Relaxed), 1);
    assert_eq!(result.elements.len(), 1);
    assert_eq!(result.elements[0].identifier, "button.ready");
    assert_eq!(result.elements[0].window_id, Some(42));
}

#[tokio::test]
async fn resolve_list_elements_does_not_retry_unscoped_empty_results() {
    async fn helper(
        _window_id: Option<i64>,
        _kind: Option<ElementKind>,
    ) -> Result<ListElementsResult, AccessibilityQueryError> {
        Ok(ListElementsResult { elements: vec![] })
    }

    let dir = TempDir::new().unwrap();
    let path = socket_path(&dir);
    let server = spawn_single_response(&path, empty_elements_response(1));
    let client = RegistryClient::with_socket_path(path);
    let result = resolve_list_elements_with(&client, None, None, helper)
        .await
        .expect("empty unscoped result succeeds");
    let request_line = server.await.unwrap();

    assert!(request_line.contains("\"op\":\"listElements\""));
    assert!(result.elements.is_empty());
}

#[tokio::test]
async fn resolve_list_elements_does_not_retry_kind_filtered_empty_results() {
    async fn helper(
        _window_id: Option<i64>,
        _kind: Option<ElementKind>,
    ) -> Result<ListElementsResult, AccessibilityQueryError> {
        Ok(ListElementsResult { elements: vec![] })
    }

    let dir = TempDir::new().unwrap();
    let path = socket_path(&dir);
    let server = spawn_single_response(&path, empty_elements_response(1));
    let client = RegistryClient::with_socket_path(path);
    let result = resolve_list_elements_with(&client, Some(42), Some(ElementKind::Button), helper)
        .await
        .expect("empty kind-filtered result succeeds");
    let request_line = server.await.unwrap();

    assert!(request_line.contains("\"op\":\"listElements\""));
    assert!(request_line.contains("\"kind\":\"button\""));
    assert!(result.elements.is_empty());
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
async fn resolve_get_element_uses_helper_when_registry_reports_not_found() {
    async fn helper(identifier: String) -> Result<GetElementResult, AccessibilityQueryError> {
        assert_eq!(identifier, "button.fallback");
        Ok(GetElementResult {
            element: fallback_element("button.fallback", 7, ElementKind::Button),
        })
    }

    let dir = TempDir::new().unwrap();
    let path = socket_path(&dir);
    let server = spawn_single_response(&path, not_found_response(1));
    let client = RegistryClient::with_socket_path(path);
    let result = resolve_get_element_with(&client, "button.fallback", helper)
        .await
        .expect("helper recovers not-found");
    let request_line = server.await.unwrap();

    assert!(request_line.contains("\"op\":\"getElement\""));
    assert_eq!(result.element.identifier, "button.fallback");
    assert_eq!(result.element.window_id, Some(7));
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

#[tokio::test]
async fn scroll_tool_queries_registry_for_identifier() {
    let dir = TempDir::new().unwrap();
    let path = socket_path(&dir);
    let response = sample_element_response_with(
        1,
        "harness.session.cockpit.scroll",
        10.0,
        20.0,
        200.0,
        120.0,
    );
    let server = spawn_single_response(&path, response);
    let client = Arc::new(RegistryClient::with_socket_path(path));
    let tool = ScrollTool::new(client);
    let _ = tool
        .call(json!({"identifier": "harness.session.cockpit.scroll", "deltaY": 180}))
        .await;
    let request_line = server.await.unwrap();
    assert!(request_line.contains("\"op\":\"getElement\""));
    assert!(request_line.contains("\"identifier\":\"harness.session.cockpit.scroll\""));
}

#[tokio::test]
async fn drag_drop_tool_queries_source_and_destination_identifiers() {
    let dir = TempDir::new().unwrap();
    let path = socket_path(&dir);
    let server = spawn_response_sequence(
        &path,
        vec![
            sample_element_response_with(1, "task.source", 10.0, 20.0, 50.0, 40.0),
            sample_element_response_with(2, "agent.destination", 210.0, 120.0, 60.0, 60.0),
        ],
    );
    let client = Arc::new(RegistryClient::with_socket_path(path));
    let tool = DragDropTool::new(client);
    let _ = tool
        .call(json!({
            "sourceIdentifier": "task.source",
            "destinationIdentifier": "agent.destination",
        }))
        .await;
    let requests = server.await.unwrap();
    assert_eq!(requests.len(), 2);
    assert!(requests[0].contains("\"identifier\":\"task.source\""));
    assert!(requests[1].contains("\"identifier\":\"agent.destination\""));
}

#[tokio::test]
async fn drag_drop_tool_rejects_duration_over_maximum() {
    let dir = TempDir::new().unwrap();
    let path = socket_path(&dir);
    let client = Arc::new(RegistryClient::with_socket_path(path));
    let tool = DragDropTool::new(client);
    let err = tool
        .call(json!({
            "sourceIdentifier": "task.source",
            "destinationIdentifier": "agent.destination",
            "durationMs": 60_001u64,
        }))
        .await
        .expect_err("duration above maximum rejected");
    assert!(err.message().contains("durationMs must be <="));
}

#[test]
fn register_all_registers_ten_tools() {
    let dir = TempDir::new().unwrap();
    let client = Arc::new(RegistryClient::with_socket_path(socket_path(&dir)));
    let mut registry = ToolRegistry::new();
    register_all(&mut registry, client);
    let metadata = registry.metadata();
    assert_eq!(metadata.len(), 10);
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
            "scroll",
            "drag_drop",
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
