use axum::extract::{Query, State};
use axum::http::StatusCode;
use serde_json::Value;

use super::*;
use crate::daemon::http::core::{get_diagnostics, get_projects};
use crate::daemon::http::sessions::{
    SessionScopeQuery, get_session, get_sessions, get_timeline,
};

#[tokio::test]
async fn get_projects_uses_async_db_when_sync_db_is_unavailable() {
    let state = test_http_state_with_async_db_only().await;

    let response = get_projects(auth_headers(), State(state)).await;

    let (status, body) = response_json(response).await;
    assert_eq!(status, StatusCode::OK);
    let Value::Array(projects) = body else {
        panic!("expected project summary array response");
    };
    assert_eq!(projects.len(), 1);
    assert_eq!(projects[0]["name"].as_str(), Some("harness"));
    assert_eq!(projects[0]["total_session_count"].as_u64(), Some(1));
}

#[tokio::test]
async fn get_sessions_uses_async_db_when_sync_db_is_unavailable() {
    let state = test_http_state_with_async_db_only().await;

    let response = get_sessions(auth_headers(), State(state)).await;

    let (status, body) = response_json(response).await;
    assert_eq!(status, StatusCode::OK);
    let Value::Array(sessions) = body else {
        panic!("expected session summary array response");
    };
    assert_eq!(sessions.len(), 1);
    assert_eq!(sessions[0]["session_id"].as_str(), Some("sess-test-1"));
}

#[tokio::test]
async fn get_session_core_uses_async_db_when_sync_db_is_unavailable() {
    let state = test_http_state_with_async_db_only().await;

    let response = get_session(
        axum::extract::Path("sess-test-1".to_owned()),
        Query(SessionScopeQuery::with_scope("core")),
        auth_headers(),
        State(state),
    )
    .await;

    let (status, body) = response_json(response).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(body["session"]["session_id"].as_str(), Some("sess-test-1"));
    let Value::Array(agents) = body["agents"].clone() else {
        panic!("expected agent array response");
    };
    assert_eq!(agents.len(), 1);
}

#[tokio::test]
async fn get_session_full_detail_uses_async_db_when_sync_db_is_unavailable() {
    let state = test_http_state_with_async_db_only().await;

    let response = get_session(
        axum::extract::Path("sess-test-1".to_owned()),
        Query(SessionScopeQuery::default()),
        auth_headers(),
        State(state),
    )
    .await;

    let (status, body) = response_json(response).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(body["session"]["session_id"].as_str(), Some("sess-test-1"));
}

#[tokio::test]
async fn get_diagnostics_uses_async_db_when_sync_db_is_unavailable() {
    let state = test_http_state_with_async_db_only().await;

    let response = get_diagnostics(auth_headers(), State(state)).await;

    let (status, body) = response_json(response).await;
    assert_eq!(status, StatusCode::OK);
    assert!(body["recent_events"].is_array());
}

#[tokio::test]
async fn get_timeline_uses_async_db_when_sync_db_is_unavailable() {
    let state = test_http_state_with_async_db_timeline_only().await;

    let response = get_timeline(
        axum::extract::Path("sess-test-1".to_owned()),
        Query(SessionScopeQuery::with_scope("summary")),
        auth_headers(),
        State(state),
    )
    .await;

    let (status, body) = response_json(response).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(body["revision"].as_i64(), Some(1));
    assert_eq!(body["total_count"].as_u64(), Some(1));
    let Value::Array(entries) = body["entries"].clone() else {
        panic!("expected timeline entries array response");
    };
    assert_eq!(entries.len(), 1);
    assert_eq!(entries[0]["payload"], serde_json::json!({}));
}
