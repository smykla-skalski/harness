use async_trait::async_trait;
use serde_json::{Value, json};

use super::dispatch::Dispatcher;
use super::handshake::{PROTOCOL_VERSION, SERVER_NAME};
use super::protocol::{Request, RequestId, ToolResult};
use super::server::RequestHandler;
use super::tool::{Tool, ToolError, ToolRegistry};

struct FakeTool;

#[async_trait]
impl Tool for FakeTool {
    fn name(&self) -> &'static str {
        "fake"
    }

    fn description(&self) -> &'static str {
        "Fake tool for tests."
    }

    fn input_schema(&self) -> Value {
        json!({
            "type": "object",
            "properties": {"x": {"type": "integer"}},
            "required": ["x"],
            "additionalProperties": false,
        })
    }

    async fn call(&self, params: Value) -> Result<ToolResult, ToolError> {
        let x = params
            .get("x")
            .and_then(Value::as_i64)
            .ok_or_else(|| ToolError::invalid("missing x"))?;
        Ok(ToolResult::text(format!("got {x}")))
    }
}

struct BrokenTool;

#[async_trait]
impl Tool for BrokenTool {
    fn name(&self) -> &'static str {
        "broken"
    }

    fn description(&self) -> &'static str {
        "always fails."
    }

    fn input_schema(&self) -> Value {
        json!({"type":"object","additionalProperties": false})
    }

    async fn call(&self, _params: Value) -> Result<ToolResult, ToolError> {
        Err(ToolError::internal("exploded"))
    }
}

fn build_dispatcher() -> Dispatcher {
    let mut registry = ToolRegistry::new();
    registry.register(Box::new(FakeTool));
    registry.register(Box::new(BrokenTool));
    Dispatcher::new(registry)
}

fn request(id: i64, method: &str, params: Value) -> Request {
    Request {
        version: super::protocol::JsonRpcVersion,
        id: RequestId::Number(id),
        method: method.to_string(),
        params,
    }
}

#[tokio::test]
async fn initialize_returns_latest_protocol_version() {
    let dispatcher = build_dispatcher();
    let response = dispatcher
        .handle_request(request(
            1,
            "initialize",
            json!({
                "protocolVersion": "2024-11-05",
                "clientInfo": {"name": "test", "version": "0.0.1"},
                "capabilities": {},
            }),
        ))
        .await;
    let value = serde_json::to_value(&response).unwrap();
    assert_eq!(
        value.pointer("/result/protocolVersion").unwrap(),
        PROTOCOL_VERSION,
    );
    assert_eq!(
        value.pointer("/result/serverInfo/name").unwrap(),
        SERVER_NAME,
    );
    assert!(value.pointer("/result/capabilities/tools").is_some());
}

#[tokio::test]
async fn tools_list_returns_registered_metadata_in_order() {
    let dispatcher = build_dispatcher();
    let response = dispatcher
        .handle_request(request(2, "tools/list", json!({})))
        .await;
    let value = serde_json::to_value(&response).unwrap();
    let tools = value.pointer("/result/tools").unwrap().as_array().unwrap();
    assert_eq!(tools.len(), 2);
    assert_eq!(tools[0].get("name").unwrap(), "fake");
    assert_eq!(tools[1].get("name").unwrap(), "broken");
    assert_eq!(tools[0].pointer("/inputSchema/required/0").unwrap(), "x",);
}

#[tokio::test]
async fn tools_call_dispatches_to_tool_and_returns_text_content() {
    let dispatcher = build_dispatcher();
    let response = dispatcher
        .handle_request(request(
            3,
            "tools/call",
            json!({"name": "fake", "arguments": {"x": 42}}),
        ))
        .await;
    let value = serde_json::to_value(&response).unwrap();
    let content = value
        .pointer("/result/content")
        .and_then(Value::as_array)
        .unwrap();
    assert_eq!(content[0].get("type").unwrap(), "text");
    assert_eq!(content[0].get("text").unwrap(), "got 42");
    assert_eq!(value.pointer("/result/isError").unwrap(), false);
}

#[tokio::test]
async fn tools_call_unknown_tool_returns_invalid_params() {
    let dispatcher = build_dispatcher();
    let response = dispatcher
        .handle_request(request(
            4,
            "tools/call",
            json!({"name": "nope", "arguments": {}}),
        ))
        .await;
    let value = serde_json::to_value(&response).unwrap();
    assert_eq!(value.pointer("/error/code").unwrap(), -32602);
    assert!(
        value
            .pointer("/error/message")
            .unwrap()
            .as_str()
            .unwrap()
            .contains("unknown tool: nope"),
    );
}

#[tokio::test]
async fn tools_call_invalid_params_shape_returns_invalid_params_error() {
    let dispatcher = build_dispatcher();
    let response = dispatcher
        .handle_request(request(
            5,
            "tools/call",
            json!({"arguments": {"x": 1}}), // missing name field
        ))
        .await;
    let value = serde_json::to_value(&response).unwrap();
    assert_eq!(value.pointer("/error/code").unwrap(), -32602);
}

#[tokio::test]
async fn tool_internal_failure_reports_as_tool_result_is_error() {
    let dispatcher = build_dispatcher();
    let response = dispatcher
        .handle_request(request(
            6,
            "tools/call",
            json!({"name": "broken", "arguments": {}}),
        ))
        .await;
    let value = serde_json::to_value(&response).unwrap();
    assert_eq!(value.pointer("/result/isError").unwrap(), true);
    let text = value
        .pointer("/result/content/0/text")
        .and_then(Value::as_str)
        .unwrap();
    assert_eq!(text, "exploded");
}

#[tokio::test]
async fn unknown_method_returns_method_not_found() {
    let dispatcher = build_dispatcher();
    let response = dispatcher
        .handle_request(request(7, "something/else", json!({})))
        .await;
    let value = serde_json::to_value(&response).unwrap();
    assert_eq!(value.pointer("/error/code").unwrap(), -32601);
}
