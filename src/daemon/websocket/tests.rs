use axum::extract::ws::Message;

use super::ReplayBuffer;
use super::frames::serialize_response_frames;
use super::queries::dispatch_read_query;
use super::test_support::{seed_sample_timeline, test_http_state_with_db};
use crate::daemon::protocol::{WsRequest, WsResponse};

#[tokio::test]
async fn websocket_round_trip_smoke_covers_public_surface() {
    let mut replay_buffer = ReplayBuffer::new(4);
    let first_seq = replay_buffer.append("event-1".into());
    let second_seq = replay_buffer.append("event-2".into());
    assert_eq!(replay_buffer.current_seq(), 2);
    assert_eq!(
        replay_buffer.replay_since(first_seq),
        Some(vec![(second_seq, String::from("event-2"))])
    );

    let state = test_http_state_with_db();
    seed_sample_timeline(&state);
    let request = WsRequest {
        id: "req-smoke".into(),
        method: "session.timeline".into(),
        params: serde_json::json!({
            "session_id": "sess-test-1",
            "scope": "summary",
        }),
    };

    let response = dispatch_read_query(&request, &state).await;
    let frames = serialize_response_frames(&response).expect("serialize websocket response");
    assert_eq!(frames.len(), 1);

    let Message::Text(text) = &frames[0] else {
        panic!("expected inline websocket response frame");
    };
    let response: WsResponse = serde_json::from_str(text).expect("deserialize websocket response");
    assert_eq!(response.id, "req-smoke");
    assert!(response.error.is_none());
    assert_eq!(
        response
            .result
            .as_ref()
            .and_then(|result| result["revision"].as_i64()),
        Some(1)
    );
    assert_eq!(
        response
            .result
            .as_ref()
            .and_then(|result| result["entries"].as_array())
            .map(Vec::len),
        Some(1)
    );
    assert_eq!(
        response
            .result
            .as_ref()
            .and_then(|result| result["entries"].as_array())
            .and_then(|entries| entries.first())
            .and_then(|entry| entry["kind"].as_str()),
        Some("tool_result")
    );
}
