use serde_json::json;

use super::{
    ContentBlock, ErrorCode, ErrorObject, Notification, Request, RequestId, Response, ToolResult,
};

#[test]
fn request_deserializes_numeric_id_and_params() {
    let raw = r#"{"jsonrpc":"2.0","id":7,"method":"tools/list","params":{}}"#;
    let req: Request = serde_json::from_str(raw).expect("parse request");
    assert_eq!(req.method, "tools/list");
    assert_eq!(req.id, RequestId::Number(7));
    assert_eq!(req.params, json!({}));
}

#[test]
fn request_deserializes_string_id() {
    let raw = r#"{"jsonrpc":"2.0","id":"abc","method":"ping","params":null}"#;
    let req: Request = serde_json::from_str(raw).expect("parse request");
    assert_eq!(req.id, RequestId::String("abc".into()));
    assert!(req.params.is_null());
}

#[test]
fn request_missing_params_defaults_to_null() {
    let raw = r#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#;
    let req: Request = serde_json::from_str(raw).expect("parse request");
    assert!(req.params.is_null());
}

#[test]
fn request_rejects_wrong_jsonrpc_version() {
    let raw = r#"{"jsonrpc":"1.0","id":1,"method":"ping","params":{}}"#;
    let err = serde_json::from_str::<Request>(raw).expect_err("should reject v1.0");
    let msg = err.to_string();
    assert!(msg.contains("jsonrpc"), "unexpected message: {msg}");
}

#[test]
fn notification_has_no_id() {
    let raw = r#"{"jsonrpc":"2.0","method":"notifications/initialized","params":{}}"#;
    let note: Notification = serde_json::from_str(raw).expect("parse notification");
    assert_eq!(note.method, "notifications/initialized");
}

#[test]
fn response_success_serializes_with_result() {
    let resp = Response::success(RequestId::Number(3), json!({"ok": true}));
    let wire = serde_json::to_value(&resp).expect("serialize");
    assert_eq!(
        wire,
        json!({"jsonrpc":"2.0","id":3,"result":{"ok":true}}),
    );
}

#[test]
fn response_error_serializes_with_error_object() {
    let resp = Response::error(
        RequestId::String("q".into()),
        ErrorObject::new(ErrorCode::MethodNotFound, "unknown method".into()),
    );
    let wire = serde_json::to_value(&resp).expect("serialize");
    assert_eq!(
        wire,
        json!({
            "jsonrpc": "2.0",
            "id": "q",
            "error": {"code": -32601, "message": "unknown method"},
        }),
    );
}

#[test]
fn error_code_numbers_match_jsonrpc_spec() {
    assert_eq!(i32::from(ErrorCode::ParseError), -32700);
    assert_eq!(i32::from(ErrorCode::InvalidRequest), -32600);
    assert_eq!(i32::from(ErrorCode::MethodNotFound), -32601);
    assert_eq!(i32::from(ErrorCode::InvalidParams), -32602);
    assert_eq!(i32::from(ErrorCode::InternalError), -32603);
}

#[test]
fn error_code_custom_passes_through() {
    assert_eq!(i32::from(ErrorCode::Custom(-32001)), -32001);
}

#[test]
fn tool_result_text_serializes_content_array() {
    let result = ToolResult::text("hello");
    let wire = serde_json::to_value(&result).expect("serialize");
    assert_eq!(
        wire,
        json!({"content":[{"type":"text","text":"hello"}],"isError":false}),
    );
}

#[test]
fn tool_result_error_marks_is_error() {
    let result = ToolResult::error("boom");
    let wire = serde_json::to_value(&result).expect("serialize");
    assert_eq!(
        wire,
        json!({"content":[{"type":"text","text":"boom"}],"isError":true}),
    );
}

#[test]
fn tool_result_image_embeds_base64_and_mime() {
    let result = ToolResult::image(b"PNGDATA".to_vec(), "image/png");
    let wire = serde_json::to_value(&result).expect("serialize");
    let content = wire.get("content").and_then(|v| v.as_array()).unwrap();
    assert_eq!(content.len(), 1);
    assert_eq!(content[0].get("type").unwrap(), "image");
    assert_eq!(content[0].get("mimeType").unwrap(), "image/png");
    assert!(content[0].get("data").unwrap().is_string());
}

#[test]
fn content_block_text_roundtrip() {
    let block = ContentBlock::text("hi");
    let wire = serde_json::to_value(&block).unwrap();
    let back: ContentBlock = serde_json::from_value(wire).unwrap();
    assert_eq!(block, back);
}
