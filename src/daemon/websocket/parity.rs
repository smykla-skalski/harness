use serde_json::json;

use crate::daemon::bridge::reconfigure_bridge;
use crate::daemon::db::ensure_shared_db;
use crate::daemon::http::{
    DaemonHttpState, adopt_session, adoption_error_status_and_body, ensure_codex_agent,
    ensure_terminal_agent, record_adopt_in_db,
};
use crate::daemon::protocol::{
    AdoptSessionRequest, AgentRuntimeSessionRegistrationRequest,
    AgentRuntimeSessionRegistrationResponse, CodexApprovalDecisionRequest, CodexRunRequest,
    CodexSteerRequest, HostBridgeReconfigureRequest, ManagedAgentSnapshot, SessionJoinRequest,
    SessionLeaveRequest, SessionMutationResponse, SessionTitleRequest, SignalAckRequest,
    VoiceAudioChunkRequest, VoiceSessionFinishRequest, VoiceSessionStartRequest,
    VoiceTranscriptUpdateRequest, WsErrorPayload, WsRequest, WsResponse,
    bind_control_plane_actor_value,
};
use crate::daemon::service;
use crate::daemon::voice::{append_audio_chunk, append_transcript, finish_session, start_session};
use crate::errors::CliError;
use crate::sandbox;
use crate::workspace::adopter::AdoptionOutcome;

use super::frames::{error_response, error_response_with_payload};
use super::mutations::{cli_error_response, dispatch_query_result};
use super::params::{extract_session_id, extract_string_param};

pub(crate) async fn dispatch_bridge_reconfigure(
    request: &WsRequest,
    _state: &DaemonHttpState,
) -> WsResponse {
    let body: HostBridgeReconfigureRequest = match serde_json::from_value(request.params.clone()) {
        Ok(body) => body,
        Err(error) => {
            return error_response(
                &request.id,
                "INVALID_PARAMS",
                &format!("failed to parse request params: {error}"),
            );
        }
    };

    dispatch_query_result(
        &request.id,
        reconfigure_bridge(&body.enable, &body.disable, body.force),
    )
}

pub(crate) async fn dispatch_session_adopt(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> WsResponse {
    let body: AdoptSessionRequest = match serde_json::from_value(request.params.clone()) {
        Ok(body) => body,
        Err(error) => {
            return error_response(
                &request.id,
                "INVALID_PARAMS",
                &format!("failed to parse request params: {error}"),
            );
        }
    };

    let result = {
        #[cfg(target_os = "macos")]
        {
            let input = if sandbox::resolver::is_sandboxed() {
                body.bookmark_id
                    .as_deref()
                    .unwrap_or(body.session_root.as_str())
            } else {
                body.session_root.as_str()
            };
            match sandbox::resolve_project_input(input) {
                Ok(session_root_scope) => adopt_session(session_root_scope.path()),
                Err(error) => return cli_error_response(&request.id, &error),
            }
        }

        #[cfg(not(target_os = "macos"))]
        {
            adopt_session(std::path::Path::new(&body.session_root))
        }
    };

    match result {
        Ok(outcome) => dispatch_session_adopt_success(request, state, outcome).await,
        Err(error) => {
            let (status, data) = adoption_error_status_and_body(&error);
            error_response_with_payload(
                &request.id,
                WsErrorPayload {
                    code: "SESSION_ADOPT_FAILED".into(),
                    message: error.to_string(),
                    details: vec![],
                    status_code: Some(status.as_u16()),
                    data: Some(data),
                },
            )
        }
    }
}

async fn dispatch_session_adopt_success(
    request: &WsRequest,
    state: &DaemonHttpState,
    outcome: AdoptionOutcome,
) -> WsResponse {
    record_adopt_in_db(state, &outcome).await;
    if let Some(async_db) = state.async_db.get() {
        service::broadcast_sessions_updated_async(&state.sender, Some(async_db.as_ref())).await;
    } else if let Ok(db) = ensure_shared_db(&state.db) {
        let db_guard = db.lock().expect("db lock");
        service::broadcast_sessions_updated(&state.sender, Some(&db_guard));
    }
    dispatch_query_result(
        &request.id,
        Ok::<_, CliError>(SessionMutationResponse {
            state: outcome.state,
        }),
    )
}

pub(crate) async fn dispatch_session_delete(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> WsResponse {
    let Some(session_id) = extract_session_id(&request.params) else {
        return error_response(&request.id, "MISSING_PARAM", "missing session_id");
    };

    let deleted = if let Some(async_db) = state.async_db.get() {
        match service::delete_session_direct_async(&session_id, async_db.as_ref()).await {
            Ok(deleted) => {
                if deleted {
                    service::broadcast_sessions_updated_async(
                        &state.sender,
                        Some(async_db.as_ref()),
                    )
                    .await;
                }
                deleted
            }
            Err(error) => return cli_error_response(&request.id, &error),
        }
    } else {
        match ensure_shared_db(&state.db).and_then(|db| {
            service::delete_session_direct(&session_id, Some(&db.lock().expect("db lock")))
        }) {
            Ok(deleted) => {
                if deleted && let Ok(db) = ensure_shared_db(&state.db) {
                    let db_guard = db.lock().expect("db lock");
                    service::broadcast_sessions_updated(&state.sender, Some(&db_guard));
                }
                deleted
            }
            Err(error) => return cli_error_response(&request.id, &error),
        }
    };

    if deleted {
        return dispatch_query_result(&request.id, Ok::<_, CliError>(json!({ "deleted": true })));
    }

    error_response_with_payload(
        &request.id,
        WsErrorPayload {
            code: "NOT_FOUND".into(),
            message: "session not found".into(),
            details: vec![],
            status_code: Some(404),
            data: Some(json!({ "error": "session not found" })),
        },
    )
}

pub(crate) async fn dispatch_session_join(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> WsResponse {
    let Some(session_id) = extract_session_id(&request.params) else {
        return error_response(&request.id, "MISSING_PARAM", "missing session_id");
    };
    let body: SessionJoinRequest = match serde_json::from_value(request.params.clone()) {
        Ok(body) => body,
        Err(error) => {
            return error_response(
                &request.id,
                "INVALID_PARAMS",
                &format!("failed to parse request params: {error}"),
            );
        }
    };

    let result = if let Some(async_db) = state.async_db.get() {
        service::join_session_direct_async(&session_id, &body, async_db.as_ref())
            .await
            .map(|state| SessionMutationResponse { state })
    } else {
        ensure_shared_db(&state.db).and_then(|db| {
            service::join_session_direct(&session_id, &body, Some(&db.lock().expect("db lock")))
                .map(|state| SessionMutationResponse { state })
        })
    };

    if result.is_ok() {
        broadcast_session_snapshot(state, &session_id).await;
    }
    dispatch_query_result(&request.id, result)
}

pub(crate) async fn dispatch_session_runtime_session(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> WsResponse {
    let Some(session_id) = extract_session_id(&request.params) else {
        return error_response(&request.id, "MISSING_PARAM", "missing session_id");
    };
    let body: AgentRuntimeSessionRegistrationRequest =
        match serde_json::from_value(request.params.clone()) {
            Ok(body) => body,
            Err(error) => {
                return error_response(
                    &request.id,
                    "INVALID_PARAMS",
                    &format!("failed to parse request params: {error}"),
                );
            }
        };

    let result = if let Some(async_db) = state.async_db.get() {
        service::register_agent_runtime_session_direct_async(&session_id, &body, async_db.as_ref())
            .await
            .map(|registered| AgentRuntimeSessionRegistrationResponse { registered })
    } else {
        let db_guard = state.db.get().map(|db| db.lock().expect("db lock"));
        service::register_agent_runtime_session_direct(&session_id, &body, db_guard.as_deref())
            .map(|registered| AgentRuntimeSessionRegistrationResponse { registered })
    };

    if result.as_ref().is_ok_and(|response| response.registered) {
        broadcast_session_snapshot(state, &session_id).await;
    }
    dispatch_query_result(&request.id, result)
}

pub(crate) async fn dispatch_session_title(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> WsResponse {
    let Some(session_id) = extract_session_id(&request.params) else {
        return error_response(&request.id, "MISSING_PARAM", "missing session_id");
    };
    let body: SessionTitleRequest = match serde_json::from_value(request.params.clone()) {
        Ok(body) => body,
        Err(error) => {
            return error_response(
                &request.id,
                "INVALID_PARAMS",
                &format!("failed to parse request params: {error}"),
            );
        }
    };

    let result = if let Some(async_db) = state.async_db.get() {
        service::update_session_title_direct_async(&session_id, &body, async_db.as_ref())
            .await
            .map(|state| SessionMutationResponse { state })
    } else {
        ensure_shared_db(&state.db).and_then(|db| {
            service::update_session_title_direct(&session_id, &body, &db.lock().expect("db lock"))
                .map(|state| SessionMutationResponse { state })
        })
    };

    if result.is_ok() {
        broadcast_session_snapshot(state, &session_id).await;
    }
    dispatch_query_result(&request.id, result)
}

pub(crate) async fn dispatch_session_leave(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> WsResponse {
    let Some(session_id) = extract_session_id(&request.params) else {
        return error_response(&request.id, "MISSING_PARAM", "missing session_id");
    };
    let body: SessionLeaveRequest = match serde_json::from_value(request.params.clone()) {
        Ok(body) => body,
        Err(error) => {
            return error_response(
                &request.id,
                "INVALID_PARAMS",
                &format!("failed to parse request params: {error}"),
            );
        }
    };

    let result = if let Some(async_db) = state.async_db.get() {
        service::leave_session_async(&session_id, &body, async_db.as_ref()).await
    } else {
        ensure_shared_db(&state.db).and_then(|db| {
            service::leave_session(&session_id, &body, Some(&db.lock().expect("db lock")))
        })
    };

    if result.is_ok() {
        broadcast_session_snapshot(state, &session_id).await;
    }
    dispatch_query_result(&request.id, result)
}

pub(crate) async fn dispatch_signal_ack(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> WsResponse {
    let Some(session_id) = extract_session_id(&request.params) else {
        return error_response(&request.id, "MISSING_PARAM", "missing session_id");
    };
    let body: SignalAckRequest = match serde_json::from_value(request.params.clone()) {
        Ok(body) => body,
        Err(error) => {
            return error_response(
                &request.id,
                "INVALID_PARAMS",
                &format!("failed to parse request params: {error}"),
            );
        }
    };

    let result = if let Some(async_db) = state.async_db.get() {
        service::record_signal_ack_direct_async(&session_id, &body, async_db.as_ref()).await
    } else {
        let db_guard = state.db.get().map(|db| db.lock().expect("db lock"));
        service::record_signal_ack_direct(&session_id, &body, db_guard.as_deref())
    };

    match result {
        Ok(()) => {
            broadcast_session_snapshot(state, &session_id).await;
            dispatch_query_result(&request.id, Ok::<_, CliError>(json!({ "ok": true })))
        }
        Err(error) => cli_error_response(&request.id, &error),
    }
}

pub(crate) async fn dispatch_managed_agent_start_terminal(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> WsResponse {
    let Some(session_id) = extract_session_id(&request.params) else {
        return error_response(&request.id, "MISSING_PARAM", "missing session_id");
    };
    let body = match serde_json::from_value(request.params.clone()) {
        Ok(body) => body,
        Err(error) => {
            return error_response(
                &request.id,
                "INVALID_PARAMS",
                &format!("failed to parse request params: {error}"),
            );
        }
    };
    let result = state
        .agent_tui_manager
        .start(&session_id, &body)
        .map(ManagedAgentSnapshot::Terminal);
    dispatch_managed_agent_response(request, state, result).await
}

pub(crate) async fn dispatch_managed_agent_start_codex(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> WsResponse {
    let Some(session_id) = extract_session_id(&request.params) else {
        return error_response(&request.id, "MISSING_PARAM", "missing session_id");
    };
    let mut params = request.params.clone();
    bind_control_plane_actor_value(&mut params);
    let body: CodexRunRequest = match serde_json::from_value(params) {
        Ok(body) => body,
        Err(error) => {
            return error_response(
                &request.id,
                "INVALID_PARAMS",
                &format!("failed to parse request params: {error}"),
            );
        }
    };
    let result = state
        .codex_controller
        .start_run(&session_id, &body)
        .map(ManagedAgentSnapshot::Codex);
    dispatch_managed_agent_response(request, state, result).await
}

pub(crate) async fn dispatch_managed_agent_input(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> WsResponse {
    let Some(agent_id) = extract_string_param(&request.params, "agent_id") else {
        return error_response(&request.id, "MISSING_PARAM", "missing agent_id");
    };
    let body = match serde_json::from_value(request.params.clone()) {
        Ok(body) => body,
        Err(error) => {
            return error_response(
                &request.id,
                "INVALID_PARAMS",
                &format!("failed to parse request params: {error}"),
            );
        }
    };
    let result = ensure_terminal_agent(state, &agent_id)
        .and_then(|()| state.agent_tui_manager.input(&agent_id, &body))
        .map(ManagedAgentSnapshot::Terminal);
    dispatch_managed_agent_response(request, state, result).await
}

pub(crate) async fn dispatch_managed_agent_resize(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> WsResponse {
    let Some(agent_id) = extract_string_param(&request.params, "agent_id") else {
        return error_response(&request.id, "MISSING_PARAM", "missing agent_id");
    };
    let body = match serde_json::from_value(request.params.clone()) {
        Ok(body) => body,
        Err(error) => {
            return error_response(
                &request.id,
                "INVALID_PARAMS",
                &format!("failed to parse request params: {error}"),
            );
        }
    };
    let result = ensure_terminal_agent(state, &agent_id)
        .and_then(|()| state.agent_tui_manager.resize(&agent_id, &body))
        .map(ManagedAgentSnapshot::Terminal);
    dispatch_managed_agent_response(request, state, result).await
}

pub(crate) async fn dispatch_managed_agent_stop(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> WsResponse {
    let Some(agent_id) = extract_string_param(&request.params, "agent_id") else {
        return error_response(&request.id, "MISSING_PARAM", "missing agent_id");
    };
    let result = ensure_terminal_agent(state, &agent_id)
        .and_then(|()| state.agent_tui_manager.stop(&agent_id))
        .map(ManagedAgentSnapshot::Terminal);
    dispatch_managed_agent_response(request, state, result).await
}

pub(crate) async fn dispatch_managed_agent_ready(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> WsResponse {
    let Some(agent_id) = extract_string_param(&request.params, "agent_id") else {
        return error_response(&request.id, "MISSING_PARAM", "missing agent_id");
    };
    let result = ensure_terminal_agent(state, &agent_id)
        .and_then(|()| state.agent_tui_manager.signal_ready(&agent_id))
        .map(ManagedAgentSnapshot::Terminal);
    dispatch_managed_agent_response(request, state, result).await
}

pub(crate) async fn dispatch_managed_agent_steer_codex(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> WsResponse {
    let Some(agent_id) = extract_string_param(&request.params, "agent_id") else {
        return error_response(&request.id, "MISSING_PARAM", "missing agent_id");
    };
    let body: CodexSteerRequest = match serde_json::from_value(request.params.clone()) {
        Ok(body) => body,
        Err(error) => {
            return error_response(
                &request.id,
                "INVALID_PARAMS",
                &format!("failed to parse request params: {error}"),
            );
        }
    };
    let result = ensure_codex_agent(state, &agent_id)
        .and_then(|()| state.codex_controller.steer(&agent_id, &body))
        .map(ManagedAgentSnapshot::Codex);
    dispatch_managed_agent_response(request, state, result).await
}

pub(crate) async fn dispatch_managed_agent_interrupt_codex(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> WsResponse {
    let Some(agent_id) = extract_string_param(&request.params, "agent_id") else {
        return error_response(&request.id, "MISSING_PARAM", "missing agent_id");
    };
    let result = ensure_codex_agent(state, &agent_id)
        .and_then(|()| state.codex_controller.interrupt(&agent_id))
        .map(ManagedAgentSnapshot::Codex);
    dispatch_managed_agent_response(request, state, result).await
}

pub(crate) async fn dispatch_managed_agent_resolve_codex_approval(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> WsResponse {
    let Some(agent_id) = extract_string_param(&request.params, "agent_id") else {
        return error_response(&request.id, "MISSING_PARAM", "missing agent_id");
    };
    let Some(approval_id) = extract_string_param(&request.params, "approval_id") else {
        return error_response(&request.id, "MISSING_PARAM", "missing approval_id");
    };
    let body: CodexApprovalDecisionRequest = match serde_json::from_value(request.params.clone()) {
        Ok(body) => body,
        Err(error) => {
            return error_response(
                &request.id,
                "INVALID_PARAMS",
                &format!("failed to parse request params: {error}"),
            );
        }
    };
    let result = ensure_codex_agent(state, &agent_id)
        .and_then(|()| {
            state
                .codex_controller
                .resolve_approval(&agent_id, &approval_id, &body)
        })
        .map(ManagedAgentSnapshot::Codex);
    dispatch_managed_agent_response(request, state, result).await
}

pub(crate) async fn dispatch_voice_start_session(
    request: &WsRequest,
    _state: &DaemonHttpState,
) -> WsResponse {
    let Some(session_id) = extract_session_id(&request.params) else {
        return error_response(&request.id, "MISSING_PARAM", "missing session_id");
    };
    let mut params = request.params.clone();
    bind_control_plane_actor_value(&mut params);
    let body: VoiceSessionStartRequest = match serde_json::from_value(params) {
        Ok(body) => body,
        Err(error) => {
            return error_response(
                &request.id,
                "INVALID_PARAMS",
                &format!("failed to parse request params: {error}"),
            );
        }
    };
    dispatch_query_result(&request.id, start_session(&session_id, &body))
}

pub(crate) async fn dispatch_voice_append_audio(
    request: &WsRequest,
    _state: &DaemonHttpState,
) -> WsResponse {
    let Some(voice_session_id) = extract_string_param(&request.params, "voice_session_id") else {
        return error_response(&request.id, "MISSING_PARAM", "missing voice_session_id");
    };
    let mut params = request.params.clone();
    bind_control_plane_actor_value(&mut params);
    let body: VoiceAudioChunkRequest = match serde_json::from_value(params) {
        Ok(body) => body,
        Err(error) => {
            return error_response(
                &request.id,
                "INVALID_PARAMS",
                &format!("failed to parse request params: {error}"),
            );
        }
    };
    dispatch_query_result(
        &request.id,
        append_audio_chunk(&voice_session_id, &body).await,
    )
}

pub(crate) async fn dispatch_voice_append_transcript(
    request: &WsRequest,
    _state: &DaemonHttpState,
) -> WsResponse {
    let Some(voice_session_id) = extract_string_param(&request.params, "voice_session_id") else {
        return error_response(&request.id, "MISSING_PARAM", "missing voice_session_id");
    };
    let mut params = request.params.clone();
    bind_control_plane_actor_value(&mut params);
    let body: VoiceTranscriptUpdateRequest = match serde_json::from_value(params) {
        Ok(body) => body,
        Err(error) => {
            return error_response(
                &request.id,
                "INVALID_PARAMS",
                &format!("failed to parse request params: {error}"),
            );
        }
    };
    dispatch_query_result(&request.id, append_transcript(&voice_session_id, &body))
}

pub(crate) async fn dispatch_voice_finish_session(
    request: &WsRequest,
    _state: &DaemonHttpState,
) -> WsResponse {
    let Some(voice_session_id) = extract_string_param(&request.params, "voice_session_id") else {
        return error_response(&request.id, "MISSING_PARAM", "missing voice_session_id");
    };
    let mut params = request.params.clone();
    bind_control_plane_actor_value(&mut params);
    let body: VoiceSessionFinishRequest = match serde_json::from_value(params) {
        Ok(body) => body,
        Err(error) => {
            return error_response(
                &request.id,
                "INVALID_PARAMS",
                &format!("failed to parse request params: {error}"),
            );
        }
    };
    dispatch_query_result(&request.id, finish_session(&voice_session_id, &body))
}

async fn dispatch_managed_agent_response(
    request: &WsRequest,
    state: &DaemonHttpState,
    result: Result<ManagedAgentSnapshot, CliError>,
) -> WsResponse {
    match result {
        Ok(snapshot) => {
            broadcast_session_snapshot(state, snapshot.session_id()).await;
            dispatch_query_result(&request.id, Ok::<_, CliError>(snapshot))
        }
        Err(error) => cli_error_response(&request.id, &error),
    }
}

async fn broadcast_session_snapshot(state: &DaemonHttpState, session_id: &str) {
    if let Some(async_db) = state.async_db.get() {
        service::broadcast_session_snapshot_async(
            &state.sender,
            session_id,
            Some(async_db.as_ref()),
        )
        .await;
        return;
    }
    let db_guard = state.db.get().map(|db| db.lock().expect("db lock"));
    service::broadcast_session_snapshot(&state.sender, session_id, db_guard.as_deref());
}
