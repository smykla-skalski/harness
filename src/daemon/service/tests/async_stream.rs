use super::*;

#[test]
fn global_stream_initial_events_async_include_current_session_index() {
    with_temp_project(|project| {
        let state = start_active_file_session(
            "daemon async stream initial index payload",
            "",
            project,
            Some("claude"),
            Some("daemon-async-stream-initial-index"),
        )
        .expect("start session");

        let db_dir = tempdir().expect("tempdir");
        let db_path = db_dir.path().join("harness.db");
        let db = crate::daemon::db::DaemonDb::open(&db_path).expect("open file db");
        let project_record = index::discovered_project_for_checkout(project);
        db.sync_project(&project_record).expect("sync project");
        db.sync_session(&project_record.project_id, &state)
            .expect("sync session");
        drop(db);

        let runtime = tokio::runtime::Runtime::new().expect("runtime");
        runtime.block_on(async {
            let async_db = crate::daemon::db::AsyncDaemonDb::connect(&db_path)
                .await
                .expect("open async daemon db");
            let events = global_stream_initial_events_async(Some(&async_db)).await;
            let snapshot = events
                .iter()
                .find(|event| event.event == "sessions_updated")
                .expect("sessions_updated event");
            let payload: SessionsUpdatedPayload =
                serde_json::from_value(snapshot.payload.clone()).expect("deserialize payload");

            assert_eq!(events[0].event, "ready");
            assert!(
                payload
                    .sessions
                    .iter()
                    .any(|session| session.session_id == state.session_id)
            );
        });
    });
}

#[test]
fn session_stream_initial_events_async_include_current_session_snapshot() {
    with_temp_project(|project| {
        let state = start_active_file_session(
            "daemon async stream initial session payload",
            "",
            project,
            Some("claude"),
            Some("daemon-async-stream-initial-session"),
        )
        .expect("start session");

        let db_dir = tempdir().expect("tempdir");
        let db_path = db_dir.path().join("harness.db");
        let db = crate::daemon::db::DaemonDb::open(&db_path).expect("open file db");
        let project_record = index::discovered_project_for_checkout(project);
        db.sync_project(&project_record).expect("sync project");
        db.sync_session(&project_record.project_id, &state)
            .expect("sync session");
        drop(db);

        let runtime = tokio::runtime::Runtime::new().expect("runtime");
        runtime.block_on(async {
            let async_db = crate::daemon::db::AsyncDaemonDb::connect(&db_path)
                .await
                .expect("open async daemon db");
            let events =
                session_stream_initial_events_async(&state.session_id, Some(&async_db)).await;
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
            assert!(
                events
                    .iter()
                    .any(|event| event.event == "session_extensions"),
                "expected session_extensions event"
            );
        });
    });
}
