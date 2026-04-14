use std::mem;

use axum::extract::ws::Message;
use base64::Engine as _;
use base64::engine::general_purpose::STANDARD as BASE64_STANDARD;
use serde_json::Value;

use super::{
    MAX_INLINE_WS_TEXT_BYTES, MAX_SEMANTIC_WS_ARRAY_BATCH_BYTES, MAX_SEMANTIC_WS_ARRAY_BATCH_ITEMS,
    WS_CHUNK_DATA_BYTES,
};
use crate::daemon::protocol::{WsChunkFrame, WsErrorPayload, WsPushEvent, WsResponse};

pub(crate) fn ok_response(request_id: &str, result: Value) -> WsResponse {
    WsResponse {
        id: request_id.into(),
        result: Some(result),
        error: None,
        batch_index: None,
        batch_count: None,
    }
}

pub(crate) fn error_response(request_id: &str, code: &str, message: &str) -> WsResponse {
    WsResponse {
        id: request_id.into(),
        result: None,
        error: Some(WsErrorPayload {
            code: code.into(),
            message: message.into(),
            details: vec![],
        }),
        batch_index: None,
        batch_count: None,
    }
}

pub(crate) fn serialize_response_frames(
    response: &WsResponse,
) -> Result<Vec<Message>, serde_json::Error> {
    if let Some(frames) = serialize_semantic_array_response_frames(response)? {
        return Ok(frames);
    }
    serialize_ws_frames(response, &format!("response:{}", response.id))
}

fn serialize_semantic_array_response_frames(
    response: &WsResponse,
) -> Result<Option<Vec<Message>>, serde_json::Error> {
    let Some(Value::Array(items)) = response.result.as_ref() else {
        return Ok(None);
    };
    if response.error.is_some() || items.is_empty() {
        return Ok(None);
    }

    let batches = build_semantic_array_batches(&items)?;
    if batches.len() <= 1 {
        return Ok(None);
    }

    let batch_count = batches.len();
    let mut frames = Vec::with_capacity(batch_count);
    for (batch_index, batch_items) in batches.into_iter().enumerate() {
        let batch_response = WsResponse {
            id: response.id.clone(),
            result: Some(Value::Array(batch_items)),
            error: None,
            batch_index: Some(batch_index),
            batch_count: Some(batch_count),
        };
        frames.extend(serialize_ws_frames(
            &batch_response,
            &format!("response:{}:batch:{batch_index}", response.id),
        )?);
    }
    Ok(Some(frames))
}

pub(crate) fn build_semantic_array_batches(
    items: &[Value],
) -> Result<Vec<Vec<Value>>, serde_json::Error> {
    let mut batches = Vec::new();
    let mut current = Vec::new();
    let mut current_bytes = 0usize;

    for item in items {
        let item_bytes = serde_json::to_vec(item)?.len();
        let reached_item_limit = current.len() >= MAX_SEMANTIC_WS_ARRAY_BATCH_ITEMS;
        let reached_byte_limit =
            !current.is_empty() && current_bytes + item_bytes > MAX_SEMANTIC_WS_ARRAY_BATCH_BYTES;
        if reached_item_limit || reached_byte_limit {
            batches.push(mem::take(&mut current));
            current_bytes = 0;
        }

        current.push(item.clone());
        current_bytes += item_bytes;
    }

    if !current.is_empty() {
        batches.push(current);
    }

    Ok(batches)
}

pub(crate) fn serialize_push_frames(push: &WsPushEvent) -> Result<Vec<Message>, serde_json::Error> {
    serialize_ws_frames(push, &format!("push:{}", push.seq))
}

fn serialize_ws_frames(
    frame: &impl serde::Serialize,
    chunk_id: &str,
) -> Result<Vec<Message>, serde_json::Error> {
    let serialized = serde_json::to_string(frame)?;
    Ok(chunk_serialized_text(serialized, chunk_id))
}

fn chunk_serialized_text(serialized: String, chunk_id: &str) -> Vec<Message> {
    if serialized.len() <= MAX_INLINE_WS_TEXT_BYTES {
        return vec![Message::text(serialized)];
    }

    let bytes = serialized.into_bytes();
    let chunk_count = bytes.len().div_ceil(WS_CHUNK_DATA_BYTES);
    bytes
        .chunks(WS_CHUNK_DATA_BYTES)
        .enumerate()
        .map(|(chunk_index, chunk)| {
            let frame = WsChunkFrame {
                chunk_id: chunk_id.to_string(),
                chunk_index,
                chunk_count,
                chunk_base64: BASE64_STANDARD.encode(chunk),
            };
            Message::text(serde_json::to_string(&frame).expect("serialize ws chunk frame"))
        })
        .collect()
}

pub(crate) fn serialize_error_response_frames(
    request_id: Option<&str>,
    code: &str,
    message: &str,
) -> Vec<Message> {
    let response = WsResponse {
        id: request_id.unwrap_or("").into(),
        result: None,
        error: Some(WsErrorPayload {
            code: code.into(),
            message: message.into(),
            details: vec![],
        }),
        batch_index: None,
        batch_count: None,
    };
    serialize_response_frames(&response).unwrap_or_else(|_| vec![Message::text("{}")])
}

#[cfg(test)]
mod tests {
    use axum::extract::ws::Message;
    use serde_json::{Value, json};

    use super::*;
    use crate::daemon::protocol::{WsPushEvent, WsResponse};

    #[test]
    fn ws_response_serialization() {
        let response = ok_response("req-1", json!({ "status": "ok" }));
        let json = serde_json::to_string(&response).expect("serialize");
        assert!(json.contains(r#""id":"req-1""#));
        assert!(json.contains(r#""status":"ok""#));
        assert!(!json.contains("error"));
    }

    #[test]
    fn ws_error_response_serialization() {
        let response = error_response("req-2", "NOT_FOUND", "session not found");
        let json = serde_json::to_string(&response).expect("serialize");
        assert!(json.contains(r#""code":"NOT_FOUND""#));
        assert!(!json.contains("result"));
    }

    #[test]
    fn oversized_ws_responses_are_chunked() {
        let response = ok_response(
            "req-large",
            json!({
                "timeline": "x".repeat(300_000),
            }),
        );

        let frames = serialize_response_frames(&response).expect("serialize response frames");

        assert!(
            frames.len() > 1,
            "large response should be split into chunks"
        );
    }

    #[test]
    fn oversized_ws_push_events_are_chunked() {
        let push = WsPushEvent {
            event: "session_extensions".into(),
            recorded_at: "2026-04-13T00:00:00Z".into(),
            session_id: Some("sess-large".into()),
            payload: json!({
                "agent_activity": "x".repeat(300_000),
            }),
            seq: 7,
        };

        let frames = serialize_push_frames(&push).expect("serialize push frames");

        assert!(
            frames.len() > 1,
            "large push event should be split into chunks"
        );
    }

    #[test]
    fn large_array_responses_use_semantic_batches_before_binary_chunking() {
        let items: Vec<Value> = (0..320)
            .map(|index| {
                json!({
                    "entry_id": format!("entry-{index}"),
                    "summary": "x".repeat(2_048),
                })
            })
            .collect();
        let response = WsResponse {
            id: "req-array".into(),
            result: Some(Value::Array(items)),
            error: None,
            batch_index: None,
            batch_count: None,
        };

        let frames = serialize_response_frames(&response).expect("serialize response frames");

        assert!(
            frames.len() > 1,
            "large array response should be split into semantic batches"
        );
        let mut seen_indices = Vec::new();
        let mut expected_batch_count = None;
        for frame in frames {
            let Message::Text(text) = frame else {
                panic!("semantic batches should stay as JSON text frames");
            };
            let response: WsResponse =
                serde_json::from_str(&text).expect("deserialize semantic response batch");
            let batch_index = response.batch_index.expect("batch index");
            let batch_count = response.batch_count.expect("batch count");
            let result = response.result.expect("batch result");
            assert!(
                matches!(result, Value::Array(_)),
                "each semantic batch should carry displayable array entries"
            );
            if let Some(expected) = expected_batch_count {
                assert_eq!(batch_count, expected);
            } else {
                expected_batch_count = Some(batch_count);
            }
            seen_indices.push(batch_index);
        }
        seen_indices.sort_unstable();
        assert_eq!(
            seen_indices,
            (0..expected_batch_count.expect("semantic batch count")).collect::<Vec<_>>()
        );
    }
}
