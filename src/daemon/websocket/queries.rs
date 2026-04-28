use std::cmp::Reverse;
use std::sync::{Arc, Mutex};

use tokio::sync::broadcast;

use crate::agents::acp::probe::probe_acp_agents_cached;
use crate::daemon::http::{AsyncDaemonDbSlot, DaemonHttpState, require_async_db};
use crate::daemon::protocol::{
    ManagedAgentListResponse, ManagedAgentSnapshot, StreamEvent, TimelineWindowRequest, WsRequest,
    WsResponse, ws_methods,
};
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
        ws_methods::HEALTH => Some(dispatch_health_query(&request.id, state).await),
        ws_methods::DIAGNOSTICS => Some(dispatch_diagnostics_query(&request.id, state).await),
        ws_methods::DAEMON_STOP => Some(dispatch_daemon_stop_query(&request.id, state)),
        ws_methods::DAEMON_LOG_LEVEL => Some(dispatch_query(&request.id, service::get_log_level)),
        ws_methods::PROJECTS => Some(dispatch_projects_query(&request.id, state).await),
        ws_methods::SESSIONS => Some(dispatch_sessions_query(&request.id, state).await),
        ws_methods::RUNTIME_SESSION_RESOLVE => {
            Some(dispatch_runtime_session_resolve_query(request, state).await)
        }
        ws_methods::RUNTIMES_PROBE => Some(dispatch_runtimes_probe_query(&request.id)),
        _ => None,
    }
}

fn dispatch_daemon_stop_query(request_id: &str, state: &DaemonHttpState) -> WsResponse {
    state.acp_agent_manager.shutdown_all();
    dispatch_query(request_id, service::request_shutdown)
}

async fn dispatch_session_read_query(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> Option<WsResponse> {
    match request.method.as_str() {
        ws_methods::SESSION_DETAIL => Some(dispatch_session_detail_query(request, state).await),
        ws_methods::SESSION_TIMELINE => Some(dispatch_session_timeline_query(request, state).await),
        ws_methods::SESSION_MANAGED_AGENTS => {
            Some(dispatch_session_managed_agents_query(request, state))
        }
        ws_methods::MANAGED_AGENT_DETAIL => {
            Some(dispatch_managed_agent_detail_query(request, state))
        }
        ws_methods::MANAGED_AGENTS_ACP_INSPECT => Some(dispatch_acp_inspect_query(request, state)),
        _ => None,
    }
}

fn dispatch_runtimes_probe_query(request_id: &str) -> WsResponse {
    dispatch_query_result(request_id, Ok(probe_acp_agents_cached()))
}

async fn dispatch_projects_query(request_id: &str, state: &DaemonHttpState) -> WsResponse {
    let result = match require_async_db(state, "projects") {
        Ok(async_db) => service::list_projects_async(Some(async_db)).await,
        Err(error) => Err(error),
    };
    dispatch_query_result(request_id, result)
}

async fn dispatch_sessions_query(request_id: &str, state: &DaemonHttpState) -> WsResponse {
    let result = match require_async_db(state, "sessions") {
        Ok(async_db) => service::list_sessions_async(true, Some(async_db)).await,
        Err(error) => Err(error),
    };
    dispatch_query_result(request_id, result)
}

async fn dispatch_runtime_session_resolve_query(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> WsResponse {
    use crate::daemon::protocol::RuntimeSessionResolutionResponse;

    let Some(runtime_name) = extract_string_param(&request.params, "runtime_name") else {
        return error_response(&request.id, "MISSING_PARAM", "missing runtime_name");
    };
    let Some(runtime_session_id) = extract_string_param(&request.params, "runtime_session_id")
    else {
        return error_response(&request.id, "MISSING_PARAM", "missing runtime_session_id");
    };
    let result = match require_async_db(state, "runtime session resolution") {
        Ok(async_db) => service::resolve_runtime_session_agent_async(
            &runtime_name,
            &runtime_session_id,
            Some(async_db),
        )
        .await
        .map(|resolved| RuntimeSessionResolutionResponse { resolved }),
        Err(error) => Err(error),
    };
    dispatch_query_result(&request.id, result)
}

async fn dispatch_session_detail_query(request: &WsRequest, state: &DaemonHttpState) -> WsResponse {
    let Some(session_id) = extract_session_id(&request.params) else {
        return error_response(&request.id, "MISSING_PARAM", "missing session_id");
    };

    let scope = extract_string_param(&request.params, "scope");
    if scope.as_deref() == Some("core") {
        return dispatch_session_detail_core_query(&request.id, state, session_id).await;
    }

    let result = match require_async_db(state, "session detail") {
        Ok(async_db) => service::session_detail_async(&session_id, Some(async_db)).await,
        Err(error) => Err(error),
    };
    dispatch_query_result(&request.id, result)
}

async fn dispatch_session_detail_core_query(
    request_id: &str,
    state: &DaemonHttpState,
    session_id: String,
) -> WsResponse {
    let result = match require_async_db(state, "session detail core") {
        Ok(async_db) => service::session_detail_core_async(&session_id, Some(async_db)).await,
        Err(error) => Err(error),
    };
    let response = dispatch_query_result(request_id, result);
    schedule_extensions_push(&state.sender, &state.async_db, &session_id);
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
        match require_async_db(state, "session timeline") {
            Ok(async_db) => {
                service::session_timeline_window_async(
                    &session_id,
                    &timeline_request,
                    Some(async_db),
                )
                .await
            }
            Err(error) => Err(error),
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

fn dispatch_session_managed_agents_query(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> WsResponse {
    let Some(session_id) = extract_session_id(&request.params) else {
        return error_response(&request.id, "MISSING_PARAM", "missing session_id");
    };

    let mut agents: Vec<_> = match state.agent_tui_manager.list(&session_id) {
        Ok(response) => response
            .tuis
            .into_iter()
            .map(ManagedAgentSnapshot::Terminal)
            .collect(),
        Err(error) => {
            return dispatch_query_result::<ManagedAgentListResponse>(&request.id, Err(error));
        }
    };
    let codex_agents = match state.codex_controller.list_runs(&session_id) {
        Ok(response) => response.runs.into_iter().map(ManagedAgentSnapshot::Codex),
        Err(error) => {
            return dispatch_query_result::<ManagedAgentListResponse>(&request.id, Err(error));
        }
    };
    agents.extend(codex_agents);
    let acp_agents = match state.acp_agent_manager.list(&session_id) {
        Ok(response) => response.into_iter().map(ManagedAgentSnapshot::Acp),
        Err(error) => {
            return dispatch_query_result::<ManagedAgentListResponse>(&request.id, Err(error));
        }
    };
    agents.extend(acp_agents);
    agents.sort_by_key(|agent| {
        (
            Reverse(agent.updated_at().to_string()),
            agent.session_id().to_string(),
            agent.agent_id().to_string(),
        )
    });
    dispatch_query_result(&request.id, Ok(ManagedAgentListResponse { agents }))
}

fn dispatch_managed_agent_detail_query(request: &WsRequest, state: &DaemonHttpState) -> WsResponse {
    let Some(agent_id) = extract_string_param(&request.params, "agent_id") else {
        return error_response(&request.id, "MISSING_PARAM", "missing agent_id");
    };

    if let Ok(snapshot) = state.agent_tui_manager.get(&agent_id) {
        return dispatch_query_result(&request.id, Ok(ManagedAgentSnapshot::Terminal(snapshot)));
    }
    if let Ok(snapshot) = state.codex_controller.run(&agent_id) {
        return dispatch_query_result(&request.id, Ok(ManagedAgentSnapshot::Codex(snapshot)));
    }
    dispatch_query_result(
        &request.id,
        state
            .acp_agent_manager
            .get(&agent_id)
            .map(ManagedAgentSnapshot::Acp),
    )
}

fn dispatch_acp_inspect_query(request: &WsRequest, state: &DaemonHttpState) -> WsResponse {
    let session_id = extract_string_param(&request.params, "session_id");
    dispatch_query_result(
        &request.id,
        Ok(state.acp_agent_manager.inspect(session_id.as_deref())),
    )
}

async fn dispatch_health_query(request_id: &str, state: &DaemonHttpState) -> WsResponse {
    dispatch_query_result(
        request_id,
        match require_async_db(state, "health") {
            Ok(async_db) => service::health_response_async(&state.manifest, Some(async_db)).await,
            Err(error) => Err(error),
        },
    )
}

async fn dispatch_diagnostics_query(request_id: &str, state: &DaemonHttpState) -> WsResponse {
    dispatch_query_result(
        request_id,
        match require_async_db(state, "diagnostics") {
            Ok(async_db) => service::diagnostics_report_async(Some(async_db)).await,
            Err(error) => Err(error),
        },
    )
}

fn schedule_extensions_push(
    sender: &broadcast::Sender<StreamEvent>,
    async_db: &AsyncDaemonDbSlot,
    session_id: &str,
) {
    use tokio::task::spawn;

    let sender = sender.clone();
    let session_id = session_id.to_string();
    let Some(async_db) = async_db.get().cloned() else {
        return;
    };
    spawn(async move {
        service::broadcast_session_extensions_async(&sender, &session_id, Some(async_db.as_ref()))
            .await;
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

    match require_async_db(state, "session subscribe snapshot") {
        Ok(async_db) => {
            service::broadcast_session_snapshot_async(&state.sender, &session_id, Some(async_db))
                .await;
            super::frames::ok_response(&request.id, serde_json::json!({ "ok": true }))
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
    match require_async_db(state, "stream subscribe snapshot") {
        Ok(async_db) => {
            service::broadcast_sessions_updated_async(&state.sender, Some(async_db)).await;
            super::frames::ok_response(&request.id, serde_json::json!({ "ok": true }))
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
    super::frames::ok_response(&request.id, serde_json::json!({ "ok": true }))
}

#[cfg(test)]
mod tests;
