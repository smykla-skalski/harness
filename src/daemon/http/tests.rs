use crate::daemon::protocol::{ObserveSessionRequest, SessionEndRequest};
use crate::errors::CliErrorKind;
use crate::session::types::CONTROL_PLANE_ACTOR_ID;
use axum::extract::{Query, State};
use axum::http::{HeaderMap, StatusCode};
use serde_json::Value;

use super::DaemonHttpState;
use super::agents::{post_remove_agent, post_role_change, post_transfer_leader};
use super::auth::authorize_control_request;
use super::core::{
    RuntimeSessionResolutionQuery, get_diagnostics, get_health, get_ready,
    get_runtime_session_resolution,
};
use super::response::{extract_request_id, request_activity_log_level};
use super::runtime_session::post_runtime_session;
use super::sessions::{
    SessionScopeQuery, get_timeline, post_end_session, post_observe_session, post_session_join,
    post_session_start, post_session_title,
};
use super::signals::{post_cancel_signal, post_send_signal, post_signal_ack};
use super::tasks::{
    post_task_assign, post_task_checkpoint, post_task_create, post_task_drop,
    post_task_queue_policy, post_task_update,
};

mod async_agent_mutations;
mod async_lifecycle_mutations;
mod async_mutations;
mod async_observe;
mod async_reads;
mod async_signal_mutations;
mod async_stream;
mod decode_failure_telemetry;
mod session_archive_tests;
mod shutdown;
mod support;
mod task_board;
mod task_board_crud;
mod task_board_parity;
mod task_board_route_parity;
mod task_review;
mod telemetry;

pub(in crate::daemon::http) use support::*;

#[tokio::test]
async fn map_json_maps_codex_unavailable_to_503() {
    let error = CliErrorKind::codex_server_unavailable("ws://127.0.0.1:4500").into();
    let (status, body) = response_body(Err(error)).await;

    assert_eq!(status, StatusCode::SERVICE_UNAVAILABLE);
    assert_eq!(body["error"], "codex-unavailable");
    assert_eq!(body["endpoint"], "ws://127.0.0.1:4500");
    assert_eq!(body["hint"], "run: harness bridge start");
}

#[tokio::test]
async fn map_json_maps_acp_disabled_to_503() {
    let error = CliErrorKind::acp_disabled().into();
    let (status, body) = response_body(Err(error)).await;

    assert_eq!(status, StatusCode::SERVICE_UNAVAILABLE);
    assert_eq!(body["error"]["code"], "ACP_DISABLED");
}

#[tokio::test]
async fn map_json_maps_session_scope_denied_to_403() {
    let error =
        CliErrorKind::session_scope_denied("agent 'x' belongs to a different session").into();
    let (status, body) = response_body(Err(error)).await;

    assert_eq!(status, StatusCode::FORBIDDEN);
    assert_eq!(body["error"]["code"], "SESSION_SCOPE_DENIED");
}

#[test]
fn request_logging_uses_debug_activity_level() {
    assert_eq!(request_activity_log_level(), tracing::Level::DEBUG);
}

#[test]
fn extract_request_id_preserves_supplied_header() {
    let mut headers = HeaderMap::new();
    headers.insert(
        "x-request-id",
        "req-123".parse().expect("request id header"),
    );

    assert_eq!(extract_request_id(&headers), "req-123");
}

#[test]
fn extract_request_id_generates_fallback_when_header_missing() {
    let first = extract_request_id(&HeaderMap::new());
    let second = extract_request_id(&HeaderMap::new());

    assert!(first.starts_with("daemon-"));
    assert!(second.starts_with("daemon-"));
    assert_ne!(first, second);
}

#[tokio::test]
async fn http_round_trip_smoke_covers_public_surface() {
    let state = test_http_state_with_db();
    let db = state.db.get().expect("db slot").clone();
    {
        let db = db.lock().expect("db lock");
        let project = sample_project();
        db.sync_project(&project).expect("sync project");
        db.save_session_state(&project.project_id, &sample_session_state())
            .expect("save session state");
        db.sync_conversation_events(
            "f9d5e4d8-cbf0-5a86-a4fb-7ea71f7116e4",
            "codex-worker",
            "codex",
            &[sample_tool_result_event()],
        )
        .expect("sync conversation events");
    }

    let health = get_health(auth_headers(), State(state.clone())).await;
    assert_eq!(health.status(), StatusCode::OK);

    let diagnostics = get_diagnostics(auth_headers(), State(state.clone())).await;
    assert_eq!(diagnostics.status(), StatusCode::OK);

    let timeline = get_timeline(
        axum::extract::Path("f9d5e4d8-cbf0-5a86-a4fb-7ea71f7116e4".to_owned()),
        Query(SessionScopeQuery::with_scope("summary")),
        auth_headers(),
        State(state.clone()),
    )
    .await;
    let (timeline_status, timeline_body) = response_json(timeline).await;
    assert_eq!(timeline_status, StatusCode::OK);
    assert_eq!(timeline_body["revision"].as_i64(), Some(1));
    assert_eq!(timeline_body["total_count"].as_u64(), Some(1));

    let mut request = SessionEndRequest {
        actor: "spoofed-leader".into(),
    };
    authorize_control_request(&auth_headers(), &state, &mut request).expect("authorize request");
    assert_eq!(request.actor, CONTROL_PLANE_ACTOR_ID);

    let (conflict_status, conflict_body) = response_body(Err(
        CliErrorKind::session_agent_conflict("agent-tui still active").into(),
    ))
    .await;
    assert_eq!(conflict_status, StatusCode::CONFLICT);
    assert_eq!(conflict_body["error"]["code"], "KSRCLI092");
    assert_eq!(request_activity_log_level(), tracing::Level::DEBUG);
}

#[tokio::test]
async fn map_json_maps_sandbox_disabled_to_501() {
    let error = CliErrorKind::sandbox_feature_disabled("codex.stdio").into();
    let (status, body) = response_body(Err(error)).await;

    assert_eq!(status, StatusCode::NOT_IMPLEMENTED);
    assert_eq!(body["error"], "sandbox-disabled");
    assert_eq!(body["feature"], "codex.stdio");
}

#[tokio::test]
async fn map_json_maps_other_errors_to_400() {
    let error = CliErrorKind::workflow_parse("bad request").into();
    let (status, body) = response_body(Err(error)).await;

    assert_eq!(status, StatusCode::BAD_REQUEST);
    assert!(body["error"]["code"].as_str().is_some());
}

#[tokio::test]
async fn map_json_maps_session_agent_conflict_to_409() {
    let error = CliErrorKind::session_agent_conflict("agent-tui still active").into();
    let (status, body) = response_body(Err(error)).await;

    assert_eq!(status, StatusCode::CONFLICT);
    assert_eq!(body["error"]["code"], "KSRCLI092");
}

#[tokio::test]
async fn get_health_requires_auth() {
    let response = get_health(HeaderMap::new(), State(test_http_state_with_db())).await;

    assert_eq!(response.status(), StatusCode::UNAUTHORIZED);
}

#[tokio::test]
async fn get_health_responds_when_db_lock_is_held() {
    let state = test_http_state_with_db();
    let db = state.db.get().expect("db slot").clone();
    let _db_guard = db.lock().expect("db lock");

    let response = get_health(auth_headers(), State(state)).await;

    assert_eq!(response.status(), StatusCode::OK);
}

#[tokio::test]
async fn get_ready_requires_auth() {
    let response = get_ready(HeaderMap::new(), State(test_http_state_with_db())).await;

    assert_eq!(response.status(), StatusCode::UNAUTHORIZED);
}

#[tokio::test]
async fn get_runtime_session_resolution_requires_auth() {
    let response = get_runtime_session_resolution(
        HeaderMap::new(),
        State(test_http_state_with_db()),
        Query(RuntimeSessionResolutionQuery {
            runtime_name: "codex".into(),
            runtime_session_id: "anything".into(),
        }),
    )
    .await;

    assert_eq!(response.status(), StatusCode::UNAUTHORIZED);
}

#[tokio::test]
async fn get_runtime_session_resolution_returns_null_resolved_when_nothing_matches() {
    let response = get_runtime_session_resolution(
        auth_headers(),
        State(test_http_state_with_db()),
        Query(RuntimeSessionResolutionQuery {
            runtime_name: "codex".into(),
            runtime_session_id: "missing-runtime-session".into(),
        }),
    )
    .await;

    let (status, body) = response_json(response).await;
    assert_eq!(status, StatusCode::OK);
    assert!(body["resolved"].is_null());
}

#[tokio::test]
async fn get_ready_returns_ok_without_querying_database() {
    let state = test_http_state_with_db();
    let expected_epoch = state.daemon_epoch.clone();
    // Hold the sync DB lock for the whole call: if the handler ran any DB
    // work it would deadlock; this proves the probe is DB-free.
    let db = state.db.get().expect("db slot").clone();
    let _db_guard = db.lock().expect("db lock");

    let response = get_ready(auth_headers(), State(state)).await;

    let (status, body) = response_json(response).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(body["ready"].as_bool(), Some(true));
    assert_eq!(body["daemon_epoch"].as_str(), Some(expected_epoch.as_str()));
}

#[tokio::test]
async fn get_diagnostics_responds_when_db_lock_is_held() {
    let state = test_http_state_with_db();
    let db = state.db.get().expect("db slot").clone();
    let _db_guard = db.lock().expect("db lock");

    let response = get_diagnostics(auth_headers(), State(state)).await;

    assert_eq!(response.status(), StatusCode::OK);
}

#[tokio::test]
async fn get_timeline_summary_scope_returns_window_metadata() {
    let state = test_http_state_with_db();
    let db = state.db.get().expect("db slot").clone();
    {
        let db = db.lock().expect("db lock");
        let project = sample_project();
        db.sync_project(&project).expect("sync project");
        db.save_session_state(&project.project_id, &sample_session_state())
            .expect("save session state");
        db.sync_conversation_events(
            "f9d5e4d8-cbf0-5a86-a4fb-7ea71f7116e4",
            "codex-worker",
            "codex",
            &[sample_tool_result_event()],
        )
        .expect("sync conversation events");
    }

    let response = get_timeline(
        axum::extract::Path("f9d5e4d8-cbf0-5a86-a4fb-7ea71f7116e4".to_owned()),
        Query(SessionScopeQuery::with_scope("summary")),
        auth_headers(),
        State(state),
    )
    .await;

    let (status, body) = response_json(response).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(body["revision"].as_i64(), Some(1));
    assert_eq!(body["total_count"].as_u64(), Some(1));
    assert_eq!(body["unchanged"].as_bool(), Some(false));
    let Value::Array(entries) = body["entries"].clone() else {
        panic!("expected timeline entries array response");
    };
    assert_eq!(entries.len(), 1);
    assert_eq!(entries[0]["kind"].as_str(), Some("tool_result"));
    assert_eq!(
        entries[0]["summary"].as_str(),
        Some("codex-worker received a result from Bash")
    );
    assert_eq!(entries[0]["payload"], serde_json::json!({}));
}

#[test]
fn authorize_control_request_rebinds_client_actor() {
    let state = test_http_state_with_db();
    let mut request = SessionEndRequest {
        actor: "spoofed-leader".into(),
    };

    authorize_control_request(&auth_headers(), &state, &mut request).expect("authorize request");

    assert_eq!(request.actor, CONTROL_PLANE_ACTOR_ID);
}
