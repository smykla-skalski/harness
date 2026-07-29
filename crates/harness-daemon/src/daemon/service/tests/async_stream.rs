use super::*;

#[test]
fn global_stream_initial_events_async_include_current_session_index() {
    with_temp_project(|project| {
        let state = start_active_file_session(
            "daemon async stream initial index payload",
            "",
            project,
            Some("claude"),
            Some("f2557b73-5008-517a-ba2e-3541b7663fe2"),
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
            Some("ea5c6cc6-4f61-5ccf-a7f3-b6499661aa0c"),
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

#[test]
fn typed_audit_writes_emit_global_push_events() {
    let runtime = tokio::runtime::Runtime::new().expect("runtime");
    runtime.block_on(async {
        let db_dir = tempdir().expect("tempdir");
        let db = Arc::new(
            crate::daemon::db::AsyncDaemonDb::connect(&db_dir.path().join("harness.db"))
                .await
                .expect("open async daemon db"),
        );
        install_test_observe_async_db(Arc::clone(&db));

        let sender = observe_sender().expect("observe sender");
        let mut receiver = sender.subscribe();
        let action_key = "audit.push.test";
        crate::daemon::audit_events::record_audit_event(
            Some(&db),
            crate::daemon::audit_events::AuditEventRecordDraft {
                source: "daemon",
                category: "lifecycle",
                kind: "daemon.push_test",
                severity: "info",
                outcome: "success",
                title: "Audit push test".into(),
                summary: "Audit event should reach global stream subscribers".into(),
                subject: Some("daemon".into()),
                actor: Some("harness-monitor".into()),
                correlation_id: None,
                action_key: Some(action_key.into()),
                payload_json: Some(serde_json::json!({ "push": true })),
                legacy_message: None,
                related_urls: Vec::new(),
            },
        )
        .await;

        let pushed = tokio::time::timeout(Duration::from_secs(1), async {
            loop {
                let event = receiver.recv().await.expect("receive audit push");
                if event.event == "audit_event"
                    && event.payload["action_key"].as_str() == Some(action_key)
                {
                    return event;
                }
            }
        })
        .await
        .expect("audit push event");

        assert_eq!(pushed.session_id, None);
        assert_eq!(pushed.payload["title"], "Audit push test");
        assert_eq!(pushed.payload["payload_json"]["push"], true);
    });
}
