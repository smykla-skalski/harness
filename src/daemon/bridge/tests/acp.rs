use std::io::{BufRead as _, BufReader, Write as _};
use std::os::unix::net::UnixListener;
use std::thread;

use tempfile::tempdir;

use super::{BridgeClient, BridgeResponse};
use crate::daemon::agent_acp::{AcpAgentStartRequest, AcpPermissionDecision};
use crate::daemon::bridge::core::BridgeAcpEventBuffer;
use crate::daemon::protocol::StreamEvent;
use crate::errors::{CliError, CliErrorKind};

fn stream_event(event: &str, session_id: &str) -> StreamEvent {
    StreamEvent {
        event: event.to_string(),
        recorded_at: "2026-04-28T00:00:00Z".to_string(),
        session_id: Some(session_id.to_string()),
        payload: serde_json::json!({ "session_id": session_id }),
    }
}

#[test]
fn acp_event_buffer_requires_resync_after_epoch_or_continuity_change() {
    let mut buffer = BridgeAcpEventBuffer::new("epoch-a".to_string());
    buffer.push(stream_event("acp_agent_started", "sess-1"));

    let initial = buffer.events_since(None, None, None);
    assert_eq!(initial.bridge_epoch, "epoch-a");
    assert_eq!(initial.continuity, 0);
    assert!(!initial.requires_resync);

    let stale_epoch = buffer.events_since(Some(1), Some("epoch-old"), Some(0));
    assert!(stale_epoch.requires_resync);
    assert!(!stale_epoch.truncated);

    buffer.record_lag(3);
    let continuity_break = buffer.events_since(Some(1), Some("epoch-a"), Some(0));
    assert!(continuity_break.requires_resync);
    assert!(!continuity_break.truncated);

    let ahead_cursor = buffer.events_since(Some(99), Some("epoch-a"), Some(0));
    assert!(ahead_cursor.requires_resync);
    assert!(ahead_cursor.truncated);
}

#[test]
fn acp_event_buffer_initial_sync_does_not_require_resync_after_quiet_restart() {
    let buffer = BridgeAcpEventBuffer::new("epoch-b".to_string());

    let initial = buffer.events_since(None, None, None);
    assert_eq!(initial.bridge_epoch, "epoch-b");
    assert_eq!(initial.continuity, 0);
    assert!(!initial.requires_resync);
    assert!(!initial.truncated);
    assert!(initial.events.is_empty());
}

#[test]
fn acp_event_buffer_flags_truncation_when_history_evicted_before_first_poll() {
    let mut buffer = BridgeAcpEventBuffer::new("epoch-a".to_string());
    for idx in 0..(BridgeAcpEventBuffer::MAX_EVENTS as u64 + 1) {
        buffer.push(stream_event("acp_agent_started", &format!("sess-{idx}")));
    }

    let initial = buffer.events_since(Some(0), Some("epoch-a"), Some(0));
    assert!(initial.truncated);
    assert!(initial.requires_resync);
}

#[test]
fn agent_tui_attach_clears_rpc_timeouts_before_returning() {
    let dir = tempdir().expect("tempdir");
    let socket_path = dir.path().join("bridge.sock");
    let listener = UnixListener::bind(&socket_path).expect("bind socket");
    let server = thread::spawn(move || {
        let (mut stream, _) = listener.accept().expect("accept");
        let mut line = String::new();
        BufReader::new(stream.try_clone().expect("clone server stream"))
            .read_line(&mut line)
            .expect("read request");
        let response = serde_json::to_string(&BridgeResponse::empty_ok()).expect("serialize");
        stream
            .write_all(response.as_bytes())
            .and_then(|()| stream.write_all(b"\n"))
            .and_then(|()| stream.flush())
            .expect("write response");
    });

    let client = BridgeClient {
        socket_path,
        token: "test-token".to_string(),
    };
    let stream = client.agent_tui_attach("tui-1").expect("attach");
    assert_eq!(stream.read_timeout().expect("read timeout"), None);
    assert_eq!(stream.write_timeout().expect("write timeout"), None);
    server.join().expect("server thread");
}

#[test]
fn bridge_client_acp_events_since_uses_expected_capability_payload() {
    let dir = tempdir().expect("tempdir");
    let socket_path = dir.path().join("bridge.sock");
    let listener = UnixListener::bind(&socket_path).expect("bind socket");
    let server = thread::spawn(move || {
        let (mut stream, _) = listener.accept().expect("accept");
        let mut line = String::new();
        BufReader::new(stream.try_clone().expect("clone server stream"))
            .read_line(&mut line)
            .expect("read request");
        let request: serde_json::Value = serde_json::from_str(&line).expect("decode envelope");
        assert_eq!(request["request"]["operation"], "capability");
        assert_eq!(request["request"]["capability"], "acp");
        assert_eq!(request["request"]["action"], "events_since");
        assert_eq!(request["request"]["payload"]["after_seq"], 7);
        assert_eq!(request["request"]["payload"]["known_epoch"], "epoch-a");
        assert_eq!(request["request"]["payload"]["known_continuity"], 3);

        let payload = serde_json::json!({
            "bridge_epoch": "epoch-a",
            "continuity": 3,
            "next_seq": 8,
            "truncated": false,
            "requires_resync": false,
            "events": [],
        });
        let response = BridgeResponse::ok_payload(&payload).expect("response payload");
        let serialized = serde_json::to_string(&response).expect("serialize");
        stream
            .write_all(serialized.as_bytes())
            .and_then(|()| stream.write_all(b"\n"))
            .and_then(|()| stream.flush())
            .expect("write response");
    });

    let client = BridgeClient {
        socket_path,
        token: "test-token".to_string(),
    };
    let response = client
        .acp_events_since(Some(7), Some("epoch-a"), Some(3))
        .expect("events_since");
    assert_eq!(response.bridge_epoch, "epoch-a");
    assert_eq!(response.continuity, 3);
    assert_eq!(response.next_seq, 8);
    assert!(!response.requires_resync);
    server.join().expect("server thread");
}

#[test]
fn bridge_client_acp_methods_use_expected_capability_actions() {
    let dir = tempdir().expect("tempdir");
    let socket_path = dir.path().join("bridge.sock");
    let listener = UnixListener::bind(&socket_path).expect("bind socket");
    let server = thread::spawn(move || {
        let expected = [
            ("start", serde_json::json!({ "session_id": "sess-1" })),
            ("list", serde_json::json!({ "session_id": "sess-1" })),
            ("inspect", serde_json::json!({ "session_id": "sess-1" })),
            ("get", serde_json::json!({ "acp_id": "acp-1" })),
            ("stop", serde_json::json!({ "acp_id": "acp-1" })),
            (
                "resolve_permission",
                serde_json::json!({
                    "acp_id": "acp-1",
                    "batch_id": "batch-1",
                    "decision": {
                        "decision": "deny_all"
                    }
                }),
            ),
        ];
        for (action, payload_assert) in expected {
            let (mut stream, _) = listener.accept().expect("accept");
            let mut line = String::new();
            BufReader::new(stream.try_clone().expect("clone server stream"))
                .read_line(&mut line)
                .expect("read request");
            let request: serde_json::Value = serde_json::from_str(&line).expect("decode envelope");
            assert_eq!(request["request"]["operation"], "capability");
            assert_eq!(request["request"]["capability"], "acp");
            assert_eq!(request["request"]["action"], action);
            for (key, value) in payload_assert.as_object().expect("payload object") {
                assert_eq!(&request["request"]["payload"][key], value);
            }
            let response = BridgeResponse::error(&CliError::from(CliErrorKind::workflow_parse(
                "expected test failure",
            )));
            let serialized = serde_json::to_string(&response).expect("serialize");
            stream
                .write_all(serialized.as_bytes())
                .and_then(|()| stream.write_all(b"\n"))
                .and_then(|()| stream.flush())
                .expect("write response");
        }
    });

    let client = BridgeClient {
        socket_path,
        token: "test-token".to_string(),
    };
    let start_request = AcpAgentStartRequest {
        agent: "claude".to_string(),
        prompt: Some("hello".to_string()),
        project_dir: Some("/tmp/project".to_string()),
        record_permissions: false,
    };
    assert!(client.acp_start("sess-1", &start_request).is_err());
    assert!(client.acp_list("sess-1").is_err());
    assert!(client.acp_inspect(Some("sess-1")).is_err());
    assert!(client.acp_get("acp-1").is_err());
    assert!(client.acp_stop("acp-1").is_err());
    assert!(
        client
            .acp_resolve_permission("acp-1", "batch-1", &AcpPermissionDecision::DenyAll)
            .is_err()
    );
    server.join().expect("server thread");
}
