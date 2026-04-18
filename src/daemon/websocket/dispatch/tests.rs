use super::*;
use crate::daemon::protocol::WsRequest;

#[test]
fn websocket_activity_logging_uses_debug_level() {
    assert_eq!(ws_activity_log_level(), tracing::Level::DEBUG);
}

#[test]
fn ws_request_deserialization() {
    let json = r#"{"id":"abc-123","method":"health","params":{}}"#;
    let request: WsRequest = serde_json::from_str(json).expect("deserialize");
    assert_eq!(request.id, "abc-123");
    assert_eq!(request.method, "health");
}
