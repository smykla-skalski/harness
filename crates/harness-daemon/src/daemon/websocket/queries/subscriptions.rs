use std::sync::{Arc, Mutex};

use super::{DaemonHttpState, WsRequest, WsResponse};
use crate::daemon::http::require_async_db;
use crate::daemon::service;
use crate::daemon::websocket::connection::ConnectionState;
use crate::daemon::websocket::frames::{error_response, ok_response};
use crate::daemon::websocket::mutations::dispatch_query_result;
use crate::daemon::websocket::params::extract_session_id;

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

    match require_async_db(state, "session subscribe snapshot") {
        Ok(async_db) => {
            service::broadcast_session_snapshot_async(&state.sender, &session_id, Some(async_db))
                .await;
            ok_response(&request.id, serde_json::json!({ "ok": true }))
        }
        Err(error) => dispatch_query_result(&request.id, Err::<serde_json::Value, _>(error)),
    }
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

    ok_response(&request.id, serde_json::json!({ "ok": true }))
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
    match require_async_db(state, "stream subscribe snapshot") {
        Ok(async_db) => {
            service::broadcast_sessions_updated_async(&state.sender, Some(async_db)).await;
            ok_response(&request.id, serde_json::json!({ "ok": true }))
        }
        Err(error) => dispatch_query_result(&request.id, Err::<serde_json::Value, _>(error)),
    }
}

pub(crate) fn handle_stream_unsubscribe(
    request: &WsRequest,
    connection: &Arc<Mutex<ConnectionState>>,
) -> WsResponse {
    {
        let mut state = connection.lock().expect("connection lock");
        state.global_subscription = false;
    }
    ok_response(&request.id, serde_json::json!({ "ok": true }))
}
