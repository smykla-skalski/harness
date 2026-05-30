use super::*;

use crate::daemon::protocol::{SessionExtensionsPayload, SessionsUpdatedDeltaPayload};

fn drain_stream_events(receiver: &mut broadcast::Receiver<StreamEvent>) -> Vec<StreamEvent> {
    let mut events = Vec::new();
    while let Ok(event) = receiver.try_recv() {
        events.push(event);
    }
    events
}

#[test]
fn broadcast_session_snapshot_emits_delta_core_and_extensions() {
    with_temp_project(|project| {
        let session = start_active_file_session(
            "snapshot broadcast",
            "resolved",
            project,
            Some("claude"),
            Some("5d2f1a7c-3e8b-5c4d-9a6f-2b1c3d4e5f60"),
        )
        .expect("start session");
        let db = setup_db_with_session(project, &session.session_id);

        let (sender, mut receiver) = broadcast::channel(16);
        broadcast_session_snapshot(&sender, &session.session_id, Some(&db));

        let events = drain_stream_events(&mut receiver);
        let event_names: Vec<_> = events.iter().map(|event| event.event.as_str()).collect();
        assert_eq!(
            event_names,
            vec!["sessions_updated_delta", "session_updated", "session_extensions"]
        );

        let delta: SessionsUpdatedDeltaPayload =
            serde_json::from_value(events[0].payload.clone()).expect("decode delta");
        assert_eq!(delta.changed.len(), 1, "exactly the mutated session changed");
        assert_eq!(delta.changed[0].session_id, session.session_id);
        assert!(delta.removed.is_empty(), "no session was removed");
        assert!(!delta.projects.is_empty(), "delta carries the project list");

        let updated: SessionUpdatedPayload =
            serde_json::from_value(events[1].payload.clone()).expect("decode session_updated");
        assert_eq!(updated.detail.session.session_id, session.session_id);
        assert!(
            updated.extensions_pending,
            "core update must flag pending extensions"
        );
        assert_eq!(events[1].session_id.as_deref(), Some(session.session_id.as_str()));

        let extensions: SessionExtensionsPayload =
            serde_json::from_value(events[2].payload.clone()).expect("decode session_extensions");
        assert_eq!(extensions.session_id, session.session_id);
        assert!(
            extensions.signals.is_some(),
            "extensions must carry the resolved signal list"
        );
    });
}

#[test]
fn broadcast_session_snapshot_emits_removed_delta_for_unknown_session() {
    with_temp_project(|project| {
        let session = start_active_file_session(
            "snapshot broadcast",
            "missing",
            project,
            Some("claude"),
            Some("5d2f1a7c-3e8b-5c4d-9a6f-2b1c3d4e5f61"),
        )
        .expect("start session");
        let db = setup_db_with_session(project, &session.session_id);

        let missing_id = "00000000-0000-0000-0000-000000000000";
        let (sender, mut receiver) = broadcast::channel(16);
        broadcast_session_snapshot(&sender, missing_id, Some(&db));

        let events = drain_stream_events(&mut receiver);
        let event_names: Vec<_> = events.iter().map(|event| event.event.as_str()).collect();
        assert_eq!(
            event_names,
            vec!["sessions_updated_delta"],
            "an unresolved session emits only a removal delta"
        );

        let delta: SessionsUpdatedDeltaPayload =
            serde_json::from_value(events[0].payload.clone()).expect("decode delta");
        assert!(delta.changed.is_empty(), "no session changed");
        assert_eq!(delta.removed, vec![missing_id.to_string()]);
    });
}
