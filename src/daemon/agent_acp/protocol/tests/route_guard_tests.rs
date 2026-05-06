use super::*;
use crate::daemon::agent_acp::protocol::session_guard::RouteTarget;

#[test]
fn session_route_guard_rejects_before_initialization() {
    let guard = SessionRouteGuard::default();
    let Err(error) = guard.ensure_known(&SessionId::new("acp-session-1")) else {
        unreachable!("guard should reject before initialization");
    };
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
    guard.start_session(
        &SessionId::new("acp-session-1"),
        route_target("eadbcb3e-6ef7-53d2-ad56-0347cb7189fc"),
    );
    let Err(error) = guard.ensure_known(&SessionId::new("acp-session-2")) else {
        unreachable!("guard should reject unknown session id");
    };
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
    guard.start_session(
        &session_id,
        route_target("eadbcb3e-6ef7-53d2-ad56-0347cb7189fc"),
    );
    let Ok(target) = guard.ensure_known(&session_id) else {
        unreachable!("guard should accept expected session id");
    };
    assert_eq!(target.acp_id, "agent-eadbcb3e-6ef7-53d2-ad56-0347cb7189fc");
    assert_eq!(target.session_id, "eadbcb3e-6ef7-53d2-ad56-0347cb7189fc");
}

#[test]
fn session_route_guard_rejects_after_session_end() {
    let guard = SessionRouteGuard::default();
    let session_id = SessionId::new("acp-session-1");
    guard.start_session(
        &session_id,
        route_target("eadbcb3e-6ef7-53d2-ad56-0347cb7189fc"),
    );
    guard.stop_session(&session_id);
    let Err(error) = guard.ensure_known(&session_id) else {
        unreachable!("guard should reject removed session id");
    };
    assert_eq!(error.reason, session_guard::RouteRejectReason::AlreadyEnded);
    assert_eq!(error.client.code, session_guard::ACP_STALE_SESSION_ID);
    assert!(error.client.message.contains("already ended"));
}

#[test]
fn session_route_guard_accepts_multiple_session_ids() {
    let guard = SessionRouteGuard::default();
    guard.start_session(
        &SessionId::new("acp-session-1"),
        route_target("eadbcb3e-6ef7-53d2-ad56-0347cb7189fc"),
    );
    guard.start_session(
        &SessionId::new("acp-session-2"),
        route_target("00b4a39f-719e-5418-abe8-eb3ab6ea614d"),
    );

    assert_eq!(
        {
            let Ok(target) = guard.ensure_known(&SessionId::new("acp-session-1")) else {
                unreachable!("first session");
            };
            target
        },
        route_target("eadbcb3e-6ef7-53d2-ad56-0347cb7189fc")
    );
    assert_eq!(
        {
            let Ok(target) = guard.ensure_known(&SessionId::new("acp-session-2")) else {
                unreachable!("second session");
            };
            target
        },
        route_target("00b4a39f-719e-5418-abe8-eb3ab6ea614d")
    );
}

#[test]
fn session_route_guard_removes_one_route_without_poisoning_siblings() {
    let guard = SessionRouteGuard::default();
    let first = SessionId::new("acp-session-1");
    let second = SessionId::new("acp-session-2");
    guard.start_session(&first, route_target("eadbcb3e-6ef7-53d2-ad56-0347cb7189fc"));
    guard.start_session(
        &second,
        route_target("00b4a39f-719e-5418-abe8-eb3ab6ea614d"),
    );

    guard.stop_session(&first);

    assert!(
        guard.ensure_known(&first).is_err(),
        "removed route should be stale"
    );
    assert_eq!(
        {
            let Ok(target) = guard.ensure_known(&second) else {
                unreachable!("sibling route remains active");
            };
            target
        },
        route_target("00b4a39f-719e-5418-abe8-eb3ab6ea614d")
    );
}

#[test]
fn session_route_guard_classifies_ended_route_with_live_sibling() {
    let guard = SessionRouteGuard::default();
    let first = SessionId::new("acp-session-1");
    let second = SessionId::new("acp-session-2");
    guard.start_session(&first, route_target("eadbcb3e-6ef7-53d2-ad56-0347cb7189fc"));
    guard.start_session(
        &second,
        route_target("00b4a39f-719e-5418-abe8-eb3ab6ea614d"),
    );

    guard.stop_session(&first);

    let Err(error) = guard.ensure_known(&first) else {
        unreachable!("ended route should remain classified");
    };
    assert_eq!(error.reason, session_guard::RouteRejectReason::AlreadyEnded);
    assert_eq!(
        {
            let Ok(target) = guard.ensure_known(&second) else {
                unreachable!("sibling route remains active");
            };
            target
        },
        route_target("00b4a39f-719e-5418-abe8-eb3ab6ea614d")
    );
}

#[test]
fn session_route_guard_reuse_clears_ended_tombstone() {
    let guard = SessionRouteGuard::default();
    let protocol_session = SessionId::new("acp-session-1");
    guard.start_session(
        &protocol_session,
        route_target("eadbcb3e-6ef7-53d2-ad56-0347cb7189fc"),
    );
    guard.stop_session(&protocol_session);

    guard.start_session(
        &protocol_session,
        route_target("00b4a39f-719e-5418-abe8-eb3ab6ea614d"),
    );

    assert_eq!(
        {
            let Ok(target) = guard.ensure_known(&protocol_session) else {
                unreachable!("reused route should be live");
            };
            target
        },
        route_target("00b4a39f-719e-5418-abe8-eb3ab6ea614d")
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

    let Err(expired) = guard.ensure_known(&SessionId::new("acp-session-0")) else {
        unreachable!("oldest tombstone should expire");
    };
    assert_eq!(expired.reason, session_guard::RouteRejectReason::Unknown);
    let Err(retained) = guard.ensure_known(&SessionId::new("acp-session-259")) else {
        unreachable!("newest tombstone should remain");
    };
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

    let Ok(()) = route_session_notification(&guard, &notification_tx, notification).await else {
        unreachable!("expired tombstone notification should be benign");
    };

    assert!(notifications.try_recv().is_err());
}

#[test]
fn session_route_guard_removes_route_by_logical_target() {
    let guard = SessionRouteGuard::default();
    let first = SessionId::new("acp-session-1");
    let second = SessionId::new("acp-session-2");
    let first_target = route_target("eadbcb3e-6ef7-53d2-ad56-0347cb7189fc");
    let second_target = route_target("00b4a39f-719e-5418-abe8-eb3ab6ea614d");
    guard.start_session(&first, first_target.clone());
    guard.start_session(&second, second_target.clone());

    let Some(stopped_session) = guard.stop_target(&first_target) else {
        unreachable!("removed ACP id");
    };
    assert_eq!(stopped_session, first);
    assert!(guard.ensure_known(&first).is_err());
    assert_eq!(
        {
            let Ok(target) = guard.ensure_known(&second) else {
                unreachable!("sibling remains");
            };
            target
        },
        second_target
    );
}

fn route_target(session_id: &str) -> RouteTarget {
    RouteTarget {
        acp_id: format!("agent-{session_id}"),
        session_id: session_id.to_string(),
    }
}
