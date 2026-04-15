#[tokio::test]
async fn load_global_initial_events_uses_async_db_when_sync_db_is_unavailable() {
    let state = super::async_reads::test_http_state_with_async_db_only().await;

    let events = super::super::stream::load_global_initial_events(&state)
        .await
        .expect("load global initial events");

    assert_eq!(
        events.first().map(|event| event.event.as_str()),
        Some("ready")
    );
    assert!(
        events.iter().any(|event| event.event == "sessions_updated"),
        "expected sessions_updated event"
    );
}

#[tokio::test]
async fn load_session_initial_events_uses_async_db_when_sync_db_is_unavailable() {
    let state = super::async_reads::test_http_state_with_async_db_timeline_only().await;

    let events = super::super::stream::load_session_initial_events(&state, "sess-test-1")
        .await
        .expect("load session initial events");

    assert_eq!(
        events.first().map(|event| event.event.as_str()),
        Some("ready")
    );
    assert!(
        events.iter().any(|event| event.event == "session_updated"),
        "expected session_updated event"
    );
    assert!(
        events
            .iter()
            .any(|event| event.event == "session_extensions"),
        "expected session_extensions event"
    );
}
