use std::sync::{Arc, Mutex, OnceLock};

use tokio::sync::broadcast;

use crate::daemon::db::DaemonDb;
use crate::daemon::http::AsyncDaemonDbSlot;
use crate::daemon::http::DaemonHttpState;
use crate::daemon::protocol::{StreamEvent, TimelineWindowRequest, WsRequest, WsResponse};
use crate::daemon::read_cache::run_canonical_db_read;
use crate::daemon::service;

use super::connection::ConnectionState;
use super::frames::error_response;
use super::mutations::{dispatch_query, dispatch_query_result};
use super::params::{
    extract_cursor_param, extract_i64_param, extract_session_id, extract_string_param,
    extract_u64_param,
};

pub(crate) async fn dispatch_read_query(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> WsResponse {
    if let Some(response) = dispatch_daemon_read_query(request, state).await {
        return response;
    }

    if let Some(response) = dispatch_session_read_query(request, state).await {
        return response;
    }

    error_response(&request.id, "UNKNOWN_METHOD", "unexpected read method")
}

async fn dispatch_daemon_read_query(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> Option<WsResponse> {
    match request.method.as_str() {
        "health" => Some(dispatch_health_query(&request.id, state).await),
        "diagnostics" => Some(dispatch_diagnostics_query(&request.id, state).await),
        "daemon.stop" => Some(dispatch_query(&request.id, service::request_shutdown)),
        "daemon.log_level" => Some(dispatch_query(&request.id, service::get_log_level)),
        "projects" => Some(dispatch_projects_query(&request.id, state).await),
        "sessions" => Some(dispatch_sessions_query(&request.id, state).await),
        _ => None,
    }
}

async fn dispatch_session_read_query(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> Option<WsResponse> {
    match request.method.as_str() {
        "session.detail" => Some(dispatch_session_detail_query(request, state).await),
        "session.timeline" => Some(dispatch_session_timeline_query(request, state).await),
        "session.agent_tuis" => Some(dispatch_session_agent_tuis_query(request, state)),
        "agent_tui.detail" => Some(dispatch_agent_tui_detail_query(request, state)),
        _ => None,
    }
}

async fn dispatch_projects_query(request_id: &str, state: &DaemonHttpState) -> WsResponse {
    let result = if let Some(async_db) = state.async_db.get() {
        service::list_projects_async(Some(async_db.as_ref())).await
    } else {
        run_canonical_db_read(&state.db, state.db_path.clone(), "projects", |db| {
            service::list_projects(Some(db))
        })
        .await
    };
    dispatch_query_result(request_id, result)
}

async fn dispatch_sessions_query(request_id: &str, state: &DaemonHttpState) -> WsResponse {
    let result = if let Some(async_db) = state.async_db.get() {
        service::list_sessions_async(true, Some(async_db.as_ref())).await
    } else {
        run_canonical_db_read(&state.db, state.db_path.clone(), "sessions", |db| {
            service::list_sessions(true, Some(db))
        })
        .await
    };
    dispatch_query_result(request_id, result)
}

async fn dispatch_session_detail_query(request: &WsRequest, state: &DaemonHttpState) -> WsResponse {
    let Some(session_id) = extract_session_id(&request.params) else {
        return error_response(&request.id, "MISSING_PARAM", "missing session_id");
    };

    let scope = extract_string_param(&request.params, "scope");
    if scope.as_deref() == Some("core") {
        return dispatch_session_detail_core_query(&request.id, state, session_id).await;
    }

    let result = if let Some(async_db) = state.async_db.get() {
        service::session_detail_async(&session_id, Some(async_db.as_ref())).await
    } else {
        run_canonical_db_read(&state.db, state.db_path.clone(), "session detail", {
            let session_id = session_id.clone();
            move |db| service::session_detail(&session_id, Some(db))
        })
        .await
    };
    dispatch_query_result(&request.id, result)
}

async fn dispatch_session_detail_core_query(
    request_id: &str,
    state: &DaemonHttpState,
    session_id: String,
) -> WsResponse {
    let result = if let Some(async_db) = state.async_db.get() {
        service::session_detail_core_async(&session_id, Some(async_db.as_ref())).await
    } else {
        run_canonical_db_read(&state.db, state.db_path.clone(), "session detail core", {
            let session_id = session_id.clone();
            move |db| service::session_detail_core(&session_id, Some(db))
        })
        .await
    };
    let response = dispatch_query_result(request_id, result);
    schedule_extensions_push(&state.sender, &state.db, &state.async_db, &session_id);
    response
}

async fn dispatch_session_timeline_query(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> WsResponse {
    let Some(session_id) = extract_session_id(&request.params) else {
        return error_response(&request.id, "MISSING_PARAM", "missing session_id");
    };
    let timeline_request = timeline_window_request_from_ws(request);

    dispatch_query_result(
        &request.id,
        if let Some(async_db) = state.async_db.get() {
            service::session_timeline_window_async(
                &session_id,
                &timeline_request,
                Some(async_db.as_ref()),
            )
            .await
        } else {
            run_canonical_db_read(&state.db, state.db_path.clone(), "session timeline", {
                let session_id = session_id.clone();
                let timeline_request = timeline_request.clone();
                move |db| service::session_timeline_window(&session_id, &timeline_request, Some(db))
            })
            .await
        },
    )
}

fn timeline_window_request_from_ws(request: &WsRequest) -> TimelineWindowRequest {
    TimelineWindowRequest {
        scope: extract_string_param(&request.params, "scope"),
        limit: extract_u64_param(&request.params, "limit")
            .and_then(|value| usize::try_from(value).ok()),
        before: extract_cursor_param(&request.params, "before"),
        after: extract_cursor_param(&request.params, "after"),
        known_revision: extract_i64_param(&request.params, "known_revision"),
    }
}

fn dispatch_session_agent_tuis_query(request: &WsRequest, state: &DaemonHttpState) -> WsResponse {
    let Some(session_id) = extract_session_id(&request.params) else {
        return error_response(&request.id, "MISSING_PARAM", "missing session_id");
    };

    dispatch_query_result(
        &request.id,
        state
            .agent_tui_manager
            .list(&session_id)
            .map(|response| response.tuis),
    )
}

fn dispatch_agent_tui_detail_query(request: &WsRequest, state: &DaemonHttpState) -> WsResponse {
    let Some(tui_id) = extract_string_param(&request.params, "tui_id") else {
        return error_response(&request.id, "MISSING_PARAM", "missing tui_id");
    };

    dispatch_query_result(&request.id, state.agent_tui_manager.get(&tui_id))
}

async fn dispatch_health_query(request_id: &str, state: &DaemonHttpState) -> WsResponse {
    if let Some(async_db) = state.async_db.get() {
        return dispatch_query_result(
            request_id,
            service::health_response_async(&state.manifest, Some(async_db.as_ref())).await,
        );
    }

    let manifest = state.manifest.clone();
    dispatch_query_result(
        request_id,
        run_canonical_db_read(&state.db, state.db_path.clone(), "health", {
            move |db| service::health_response(&manifest, Some(db))
        })
        .await,
    )
}

async fn dispatch_diagnostics_query(request_id: &str, state: &DaemonHttpState) -> WsResponse {
    if let Some(async_db) = state.async_db.get() {
        return dispatch_query_result(
            request_id,
            service::diagnostics_report_async(Some(async_db.as_ref())).await,
        );
    }

    dispatch_query_result(
        request_id,
        run_canonical_db_read(&state.db, state.db_path.clone(), "diagnostics", |db| {
            service::diagnostics_report(Some(db))
        })
        .await,
    )
}

fn schedule_extensions_push(
    sender: &broadcast::Sender<StreamEvent>,
    db: &Arc<OnceLock<Arc<Mutex<DaemonDb>>>>,
    async_db: &AsyncDaemonDbSlot,
    session_id: &str,
) {
    use tokio::task::{spawn, spawn_blocking};

    let sender = sender.clone();
    let db = db.clone();
    let async_db = async_db.get().cloned();
    let session_id = session_id.to_string();
    spawn(async move {
        if let Some(async_db) = async_db {
            service::broadcast_session_extensions_async(
                &sender,
                &session_id,
                Some(async_db.as_ref()),
            )
            .await;
            return;
        }
        let result = spawn_blocking(move || {
            let db_guard = db
                .get()
                .map(|db: &Arc<Mutex<DaemonDb>>| db.lock().expect("db lock"));
            let db_ref = db_guard.as_deref();
            service::session_extensions_event(&session_id, db_ref)
        })
        .await;
        if let Ok(Ok(event)) = result {
            let _ = sender.send(event);
        }
    });
}

pub(crate) async fn handle_session_subscribe(
    request: &WsRequest,
    state: &DaemonHttpState,
    connection: &Arc<Mutex<ConnectionState>>,
) -> WsResponse {
    let Some(session_id) = extract_session_id(&request.params) else {
        return error_response(&request.id, "MISSING_PARAM", "missing session_id");
    };

    {
        let mut state = connection.lock().expect("connection lock");
        state.session_subscriptions.insert(session_id.clone());
    }

    if let Some(async_db) = state.async_db.get() {
        service::broadcast_session_snapshot_async(
            &state.sender,
            &session_id,
            Some(async_db.as_ref()),
        )
        .await;
        return super::frames::ok_response(&request.id, serde_json::json!({ "ok": true }));
    }

    let sender = state.sender.clone();
    let _ = run_canonical_db_read(
        &state.db,
        state.db_path.clone(),
        "session subscribe snapshot",
        {
            let session_id = session_id.clone();
            let sender = sender.clone();
            move |db| {
                service::broadcast_session_snapshot(&sender, &session_id, Some(db));
                Ok(())
            }
        },
    )
    .await;

    super::frames::ok_response(&request.id, serde_json::json!({ "ok": true }))
}

pub(crate) fn handle_session_unsubscribe(
    request: &WsRequest,
    connection: &Arc<Mutex<ConnectionState>>,
) -> WsResponse {
    let Some(session_id) = extract_session_id(&request.params) else {
        return error_response(&request.id, "MISSING_PARAM", "missing session_id");
    };

    {
        let mut state = connection.lock().expect("connection lock");
        state.session_subscriptions.remove(&session_id);
    }

    super::frames::ok_response(&request.id, serde_json::json!({ "ok": true }))
}

pub(crate) async fn handle_stream_subscribe(
    request: &WsRequest,
    state: &DaemonHttpState,
    connection: &Arc<Mutex<ConnectionState>>,
) -> WsResponse {
    {
        let mut state = connection.lock().expect("connection lock");
        state.global_subscription = true;
    }
    if let Some(async_db) = state.async_db.get() {
        service::broadcast_sessions_updated_async(&state.sender, Some(async_db.as_ref())).await;
        return super::frames::ok_response(&request.id, serde_json::json!({ "ok": true }));
    }
    let db_guard = state
        .db
        .get()
        .map(|db: &Arc<Mutex<DaemonDb>>| db.lock().expect("db lock"));
    let db_ref = db_guard.as_deref();
    service::broadcast_sessions_updated(&state.sender, db_ref);
    super::frames::ok_response(&request.id, serde_json::json!({ "ok": true }))
}

pub(crate) fn handle_stream_unsubscribe(
    request: &WsRequest,
    connection: &Arc<Mutex<ConnectionState>>,
) -> WsResponse {
    {
        let mut state = connection.lock().expect("connection lock");
        state.global_subscription = false;
    }
    super::frames::ok_response(&request.id, serde_json::json!({ "ok": true }))
}

#[cfg(test)]
mod tests {
    use serde_json::Value;

    use super::super::test_support::{
        seed_sample_agent_tui, seed_sample_timeline, test_http_state_with_async_db_timeline,
        test_http_state_with_db,
    };
    use super::*;
    use crate::daemon::protocol::WsRequest;

    #[tokio::test]
    async fn dispatch_read_query_health_succeeds_when_db_lock_is_held() {
        let state = test_http_state_with_db();
        let db = state.db.get().expect("db slot").clone();
        let _db_guard = db.lock().expect("db lock");
        let request = WsRequest {
            id: "req-1".into(),
            method: "health".into(),
            params: serde_json::json!({}),
        };

        let response = dispatch_read_query(&request, &state).await;

        assert_eq!(response.id, "req-1");
        assert!(response.error.is_none());
        assert_eq!(
            response
                .result
                .expect("health response")
                .get("status")
                .and_then(Value::as_str),
            Some("ok")
        );
    }

    #[tokio::test]
    async fn dispatch_read_query_session_agent_tuis_returns_snapshot_array() {
        let state = test_http_state_with_db();
        seed_sample_agent_tui(&state, "tui-1", "2026-04-13T19:10:00Z");
        let request = WsRequest {
            id: "req-agent-tuis".into(),
            method: "session.agent_tuis".into(),
            params: serde_json::json!({ "session_id": "sess-test-1" }),
        };

        let response = dispatch_read_query(&request, &state).await;

        assert!(response.error.is_none());
        let result = response.result.expect("agent tui list response");
        let Value::Array(entries) = result else {
            panic!("expected websocket agent tui list result to be an array");
        };
        assert_eq!(entries.len(), 1);
        assert_eq!(entries[0]["tui_id"].as_str(), Some("tui-1"));
    }

    #[tokio::test]
    async fn dispatch_read_query_agent_tui_detail_returns_snapshot() {
        let state = test_http_state_with_db();
        seed_sample_agent_tui(&state, "tui-2", "2026-04-13T19:11:00Z");
        let request = WsRequest {
            id: "req-agent-tui".into(),
            method: "agent_tui.detail".into(),
            params: serde_json::json!({ "tui_id": "tui-2" }),
        };

        let response = dispatch_read_query(&request, &state).await;

        assert!(response.error.is_none());
        let result = response.result.expect("agent tui response");
        assert_eq!(result["tui_id"].as_str(), Some("tui-2"));
        assert_eq!(result["session_id"].as_str(), Some("sess-test-1"));
    }

    #[tokio::test]
    async fn dispatch_read_query_session_timeline_summary_scope_returns_window_metadata() {
        let state = test_http_state_with_db();
        seed_sample_timeline(&state);
        let request = WsRequest {
            id: "req-timeline-summary".into(),
            method: "session.timeline".into(),
            params: serde_json::json!({
                "session_id": "sess-test-1",
                "scope": "summary",
            }),
        };

        let response = dispatch_read_query(&request, &state).await;

        assert!(response.error.is_none());
        let result = response.result.expect("timeline response");
        assert_eq!(result["revision"].as_i64(), Some(1));
        assert_eq!(result["total_count"].as_u64(), Some(1));
        assert_eq!(result["unchanged"].as_bool(), Some(false));
        let Value::Array(entries) = result["entries"].clone() else {
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

    #[tokio::test]
    async fn dispatch_read_query_session_timeline_uses_async_db_when_sync_db_is_unavailable() {
        let state = test_http_state_with_async_db_timeline().await;
        let request = WsRequest {
            id: "req-timeline-async".into(),
            method: "session.timeline".into(),
            params: serde_json::json!({
                "session_id": "sess-test-1",
                "scope": "summary",
            }),
        };

        let response = dispatch_read_query(&request, &state).await;

        assert!(response.error.is_none());
        let result = response.result.expect("timeline response");
        assert_eq!(result["revision"].as_i64(), Some(1));
        assert_eq!(result["total_count"].as_u64(), Some(1));
        let Value::Array(entries) = result["entries"].clone() else {
            panic!("expected timeline entries array response");
        };
        assert_eq!(entries.len(), 1);
        assert_eq!(entries[0]["payload"], serde_json::json!({}));
    }
}
