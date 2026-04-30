use super::*;

#[test]
fn session_route_guard_rejects_before_initialization() {
    let guard = SessionRouteGuard::default();
    let error = guard
        .ensure_known(&SessionId::new("acp-session-1"))
        .expect_err("guard should reject before initialization");
    assert_eq!(
        error.reason,
        session_guard::RouteRejectReason::NotInitialized
    );
    assert_eq!(error.client.code, session_guard::ACP_STALE_SESSION_ID);
    assert!(
        error.client.message.contains("stale_session_id"),
        "unexpected message: {}",
        error.client.message
    );
}

#[test]
fn session_route_guard_rejects_stale_session_id() {
    let guard = SessionRouteGuard::default();
    guard.start_session(&SessionId::new("acp-session-1"), route_target("sess-1"));
    let error = guard
        .ensure_known(&SessionId::new("acp-session-2"))
        .expect_err("guard should reject unknown session id");
    assert_eq!(error.reason, session_guard::RouteRejectReason::Unknown);
    assert_eq!(error.client.code, session_guard::ACP_STALE_SESSION_ID);
    assert!(
        error.client.message.contains("stale_session_id"),
        "unexpected message: {}",
        error.client.message
    );
}

#[test]
fn session_route_guard_accepts_expected_session_id() {
    let guard = SessionRouteGuard::default();
    let session_id = SessionId::new("acp-session-1");
    guard.start_session(&session_id, route_target("sess-1"));
    let target = guard
        .ensure_known(&session_id)
        .expect("guard should accept expected session id");
    assert_eq!(target.acp_id, "agent-sess-1");
    assert_eq!(target.session_id, "sess-1");
}

#[test]
fn session_route_guard_rejects_after_session_end() {
    let guard = SessionRouteGuard::default();
    let session_id = SessionId::new("acp-session-1");
    guard.start_session(&session_id, route_target("sess-1"));
    guard.stop_session(&session_id);
    let error = guard
        .ensure_known(&session_id)
        .expect_err("guard should reject removed session id");
    assert_eq!(error.reason, session_guard::RouteRejectReason::AlreadyEnded);
    assert_eq!(error.client.code, session_guard::ACP_STALE_SESSION_ID);
    assert!(error.client.message.contains("already ended"));
}

#[test]
fn session_route_guard_accepts_multiple_session_ids() {
    let guard = SessionRouteGuard::default();
    guard.start_session(&SessionId::new("acp-session-1"), route_target("sess-1"));
    guard.start_session(&SessionId::new("acp-session-2"), route_target("sess-2"));

    assert_eq!(
        guard
            .ensure_known(&SessionId::new("acp-session-1"))
            .expect("first session"),
        route_target("sess-1")
    );
    assert_eq!(
        guard
            .ensure_known(&SessionId::new("acp-session-2"))
            .expect("second session"),
        route_target("sess-2")
    );
}

#[test]
fn session_route_guard_removes_one_route_without_poisoning_siblings() {
    let guard = SessionRouteGuard::default();
    let first = SessionId::new("acp-session-1");
    let second = SessionId::new("acp-session-2");
    guard.start_session(&first, route_target("sess-1"));
    guard.start_session(&second, route_target("sess-2"));

    guard.stop_session(&first);

    assert!(
        guard.ensure_known(&first).is_err(),
        "removed route should be stale"
    );
    assert_eq!(
        guard
            .ensure_known(&second)
            .expect("sibling route remains active"),
        route_target("sess-2")
    );
}

#[test]
fn session_route_guard_classifies_ended_route_with_live_sibling() {
    let guard = SessionRouteGuard::default();
    let first = SessionId::new("acp-session-1");
    let second = SessionId::new("acp-session-2");
    guard.start_session(&first, route_target("sess-1"));
    guard.start_session(&second, route_target("sess-2"));

    guard.stop_session(&first);

    let error = guard
        .ensure_known(&first)
        .expect_err("ended route should remain classified");
    assert_eq!(error.reason, session_guard::RouteRejectReason::AlreadyEnded);
    assert_eq!(
        guard
            .ensure_known(&second)
            .expect("sibling route remains active"),
        route_target("sess-2")
    );
}

#[test]
fn session_route_guard_reuse_clears_ended_tombstone() {
    let guard = SessionRouteGuard::default();
    let protocol_session = SessionId::new("acp-session-1");
    guard.start_session(&protocol_session, route_target("sess-1"));
    guard.stop_session(&protocol_session);

    guard.start_session(&protocol_session, route_target("sess-2"));

    assert_eq!(
        guard
            .ensure_known(&protocol_session)
            .expect("reused route should be live"),
        route_target("sess-2")
    );
}

#[test]
fn session_route_guard_bounds_ended_tombstones() {
    let guard = SessionRouteGuard::default();
    for index in 0..260 {
        let session = SessionId::new(format!("acp-session-{index}"));
        guard.start_session(&session, route_target(&format!("sess-{index}")));
        guard.stop_session(&session);
    }
    guard.start_session(
        &SessionId::new("acp-session-live"),
        route_target("sess-live"),
    );

    let expired = guard
        .ensure_known(&SessionId::new("acp-session-0"))
        .expect_err("oldest tombstone should expire");
    assert_eq!(expired.reason, session_guard::RouteRejectReason::Unknown);
    let retained = guard
        .ensure_known(&SessionId::new("acp-session-259"))
        .expect_err("newest tombstone should remain");
    assert_eq!(
        retained.reason,
        session_guard::RouteRejectReason::AlreadyEnded
    );
}

#[tokio::test]
async fn expired_tombstone_notification_is_dropped_without_protocol_error() {
    let guard = SessionRouteGuard::default();
    for index in 0..260 {
        let session = SessionId::new(format!("acp-session-{index}"));
        guard.start_session(&session, route_target(&format!("sess-{index}")));
        guard.stop_session(&session);
    }
    guard.start_session(
        &SessionId::new("acp-session-live"),
        route_target("sess-live"),
    );
    let (notification_tx, mut notifications) = mpsc::channel(1);
    let notification = SessionNotification::new(
        SessionId::new("acp-session-0"),
        SessionUpdate::AgentMessageChunk(ContentChunk::new(ContentBlock::Text(TextContent::new(
            "too late",
        )))),
    );

    route_session_notification(&guard, &notification_tx, notification)
        .await
        .expect("expired tombstone notification should be benign");

    assert!(notifications.try_recv().is_err());
}

#[test]
fn session_route_guard_removes_route_by_logical_target() {
    let guard = SessionRouteGuard::default();
    let first = SessionId::new("acp-session-1");
    let second = SessionId::new("acp-session-2");
    let first_target = route_target("sess-1");
    let second_target = route_target("sess-2");
    guard.start_session(&first, first_target.clone());
    guard.start_session(&second, second_target.clone());

    assert_eq!(
        guard.stop_target(&first_target).expect("removed ACP id"),
        first
    );
    assert!(guard.ensure_known(&first).is_err());
    assert_eq!(
        guard.ensure_known(&second).expect("sibling remains"),
        second_target
    );
}

fn route_target(session_id: &str) -> RouteTarget {
    RouteTarget {
        acp_id: format!("agent-{session_id}"),
        session_id: session_id.to_string(),
    }
}
