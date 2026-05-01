use std::sync::Arc;

use serde_json::{Value, json};
use tempfile::TempDir;

use crate::mcp::automation::INPUT_OVERRIDE_ENV;
use crate::mcp::registry::RegistryClient;
use crate::mcp::tool::{Tool, ToolRegistry};

use super::*;

#[tokio::test]
async fn scroll_tool_rejects_disabled_targets() {
    let dir = TempDir::new().unwrap();
    let path = socket_path(&dir);
    let response = sample_element_response_with_enabled(
        1,
        "harness.session.cockpit.scroll",
        10.0,
        20.0,
        200.0,
        120.0,
        false,
    );
    let server = spawn_single_response(&path, response);
    let client = Arc::new(RegistryClient::with_socket_path(path));
    let tool = ScrollTool::new(client);
    let err = tool
        .call(json!({"identifier": "harness.session.cockpit.scroll", "deltaY": 180}))
        .await
        .expect_err("disabled targets should be rejected");
    let request_line = server.await.unwrap();
    assert!(request_line.contains("\"identifier\":\"harness.session.cockpit.scroll\""));
    assert!(err.message().contains("disabled target"));
}

#[tokio::test]
async fn scroll_tool_uses_helper_fallback_when_registry_reports_not_found() {
    let dir = TempDir::new().unwrap();
    let path = socket_path(&dir);
    let helper = dir.path().join("fake-harness-monitor-input");
    write_fake_harness_input(&helper);
    let helper_value = helper.to_string_lossy().into_owned();
    let server = spawn_single_response(&path, not_found_response(1));
    let client = Arc::new(RegistryClient::with_socket_path(path));
    let tool = ScrollTool::new(client);

    let result = temp_env::async_with_vars(
        [(INPUT_OVERRIDE_ENV, Some(helper_value.as_str()))],
        async move {
            tool.call(json!({
                "identifier": "harness.session.cockpit.scroll",
                "deltaY": 180,
            }))
            .await
        },
    )
    .await
    .expect("helper fallback should let scroll succeed");

    let request_line = server.await.unwrap();
    assert!(request_line.contains("\"identifier\":\"harness.session.cockpit.scroll\""));
    assert!(!result.is_error);
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
async fn drag_drop_tool_rejects_disabled_destination() {
    let dir = TempDir::new().unwrap();
    let path = socket_path(&dir);
    let server = spawn_response_sequence(
        &path,
        vec![
            sample_element_response_with(1, "task.source", 10.0, 20.0, 50.0, 40.0),
            sample_element_response_with_enabled(
                2,
                "agent.destination",
                210.0,
                120.0,
                60.0,
                60.0,
                false,
            ),
        ],
    );
    let client = Arc::new(RegistryClient::with_socket_path(path));
    let tool = DragDropTool::new(client);
    let err = tool
        .call(json!({
            "sourceIdentifier": "task.source",
            "destinationIdentifier": "agent.destination",
        }))
        .await
        .expect_err("disabled destination should be rejected");
    let requests = server.await.unwrap();
    assert_eq!(requests.len(), 2);
    assert!(err.message().contains("disabled target"));
}

#[tokio::test]
async fn drag_drop_tool_uses_helper_fallback_when_registry_reports_not_found() {
    let dir = TempDir::new().unwrap();
    let path = socket_path(&dir);
    let helper = dir.path().join("fake-harness-monitor-input");
    write_fake_harness_input(&helper);
    let helper_value = helper.to_string_lossy().into_owned();
    let server = spawn_response_sequence(
        &path,
        vec![not_found_response(1), not_found_response(2)],
    );
    let client = Arc::new(RegistryClient::with_socket_path(path));
    let tool = DragDropTool::new(client);

    let result = temp_env::async_with_vars(
        [(INPUT_OVERRIDE_ENV, Some(helper_value.as_str()))],
        async move {
            tool.call(json!({
                "sourceIdentifier": "task.source",
                "destinationIdentifier": "agent.destination",
            }))
            .await
        },
    )
    .await
    .expect("helper fallback should let drag succeed");

    let requests = server.await.unwrap();
    assert_eq!(requests.len(), 2);
    assert!(requests[0].contains("\"identifier\":\"task.source\""));
    assert!(requests[1].contains("\"identifier\":\"agent.destination\""));
    assert!(!result.is_error);
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
    register_all(&mut registry, &client);
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
    register_all(&mut registry, &client);
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
