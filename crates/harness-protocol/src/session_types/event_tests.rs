use crate::agents::runtime::signal::AckResult;

use super::{SessionLogEntry, SessionRole, SessionSignalStatus, SessionTransition};

#[test]
fn session_transition_serde_tagged() {
    let entry = SessionLogEntry {
        sequence: 1,
        recorded_at: "2026-03-28T12:00:00Z".into(),
        session_id: "sess-test".into(),
        transition: SessionTransition::AgentJoined {
            agent_id: "codex-abc".into(),
            role: SessionRole::Worker,
            runtime: "codex".into(),
        },
        actor_id: Some("leader-1".into()),
        reason: None,
    };

    let json = serde_json::to_string(&entry).expect("serializes");
    assert!(json.contains("\"kind\":\"agent_joined\""));

    let parsed: SessionLogEntry = serde_json::from_str(&json).expect("deserializes");
    assert_eq!(parsed.sequence, 1);
}

#[test]
fn session_signal_status_maps_ack_results() {
    assert_eq!(
        SessionSignalStatus::from_ack_result(AckResult::Accepted),
        SessionSignalStatus::Delivered
    );
    assert_eq!(
        SessionSignalStatus::from_ack_result(AckResult::Rejected),
        SessionSignalStatus::Rejected
    );
    assert_eq!(
        SessionSignalStatus::from_ack_result(AckResult::Deferred),
        SessionSignalStatus::Deferred
    );
    assert_eq!(
        SessionSignalStatus::from_ack_result(AckResult::Expired),
        SessionSignalStatus::Expired
    );
}
