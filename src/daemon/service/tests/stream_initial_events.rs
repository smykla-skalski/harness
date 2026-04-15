use super::*;

#[test]
fn sessions_updated_event_includes_projects_and_sessions() {
    with_temp_project(|project| {
        let state = session_service::start_session(
            "daemon stream index payload",
            "",
            project,
            Some("claude"),
            Some("daemon-stream-index"),
        )
        .expect("start session");

        let event = sessions_updated_event(None).expect("sessions updated event");
        let payload: SessionsUpdatedPayload =
            serde_json::from_value(event.payload).expect("deserialize payload");

        assert_eq!(event.event, "sessions_updated");
        assert!(event.session_id.is_none());
        assert_eq!(payload.projects.len(), 1);
        assert_eq!(payload.sessions.len(), 1);
        assert_eq!(payload.sessions[0].session_id, state.session_id);
    });
}

#[test]
fn global_stream_initial_events_include_current_session_index() {
    with_temp_project(|project| {
        let state = session_service::start_session(
            "daemon stream initial index payload",
            "",
            project,
            Some("claude"),
            Some("daemon-stream-initial-index"),
        )
        .expect("start session");

        let events = global_stream_initial_events(None);
        let snapshot = events
            .iter()
            .find(|event| event.event == "sessions_updated")
            .expect("sessions_updated event");
        let payload: SessionsUpdatedPayload =
            serde_json::from_value(snapshot.payload.clone()).expect("deserialize payload");

        assert_eq!(events[0].event, "ready");
        assert!(events[0].session_id.is_none());
        assert!(
            payload
                .sessions
                .iter()
                .any(|session| session.session_id == state.session_id)
        );
    });
}

#[test]
fn session_stream_initial_events_include_current_session_snapshot() {
    with_temp_project(|project| {
        let state = session_service::start_session(
            "daemon stream initial session payload",
            "",
            project,
            Some("claude"),
            Some("daemon-stream-initial-session"),
        )
        .expect("start session");

        let events = session_stream_initial_events(&state.session_id, None);
        let update = events
            .iter()
            .find(|event| event.event == "session_updated")
            .expect("session_updated event");
        let payload: SessionUpdatedPayload =
            serde_json::from_value(update.payload.clone()).expect("deserialize payload");

        assert_eq!(events[0].event, "ready");
        assert_eq!(
            events[0].session_id.as_deref(),
            Some(state.session_id.as_str())
        );
        assert_eq!(
            update.session_id.as_deref(),
            Some(state.session_id.as_str())
        );
        assert_eq!(payload.detail.session.session_id, state.session_id);
        assert!(payload.extensions_pending);
    });
}

#[test]
fn session_updated_event_includes_detail_without_timeline() {
    with_temp_project(|project| {
        let state = session_service::start_session(
            "daemon stream session payload",
            "",
            project,
            Some("claude"),
            Some("daemon-stream-session"),
        )
        .expect("start session");
        let leader_id = state.leader_id.expect("leader id");
        append_project_ledger_entry(project);
        session_service::create_task(
            &state.session_id,
            "materialize timeline",
            None,
            crate::session::types::TaskSeverity::Medium,
            &leader_id,
            project,
        )
        .expect("create task");

        let event = session_updated_event(&state.session_id, None).expect("session updated event");
        let payload: SessionUpdatedPayload =
            serde_json::from_value(event.payload).expect("deserialize payload");

        assert_eq!(event.event, "session_updated");
        assert_eq!(event.session_id.as_deref(), Some(state.session_id.as_str()));
        assert_eq!(payload.detail.session.session_id, state.session_id);
        assert!(payload.timeline.is_none());
    });
}
