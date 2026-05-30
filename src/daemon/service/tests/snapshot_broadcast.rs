use super::*;

use crate::daemon::protocol::SessionExtensionsPayload;

fn drain_stream_events(receiver: &mut broadcast::Receiver<StreamEvent>) -> Vec<StreamEvent> {
    let mut events = Vec::new();
    while let Ok(event) = receiver.try_recv() {
        events.push(event);
    }
    events
}

#[test]
fn broadcast_session_snapshot_emits_sessions_core_and_extensions() {
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
            vec!["sessions_updated", "session_updated", "session_extensions"]
        );

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
fn broadcast_session_snapshot_skips_session_events_for_unknown_session() {
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

        let (sender, mut receiver) = broadcast::channel(16);
        broadcast_session_snapshot(&sender, "00000000-0000-0000-0000-000000000000", Some(&db));

        let events = drain_stream_events(&mut receiver);
        let event_names: Vec<_> = events.iter().map(|event| event.event.as_str()).collect();
        assert_eq!(
            event_names,
            vec!["sessions_updated"],
            "an unresolved session must not emit per-session events"
        );
    });
}
