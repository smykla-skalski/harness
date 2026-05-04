use std::sync::{Arc, Mutex, MutexGuard};

use serde_json::json;

use crate::daemon::agent_acp::{AcpAgentStartRequest, AcpPermissionDecision};
use crate::daemon::bridge::reconfigure_bridge;
use crate::daemon::db::{DaemonDb, ensure_shared_db};
use crate::daemon::http::{
    DaemonHttpState, adopt_session, adoption_error_status_and_body, ensure_acp_agent,
    ensure_codex_agent, ensure_terminal_agent, record_adopt_in_db,
};
use crate::daemon::protocol::{
    AdoptSessionRequest, AgentRuntimeSessionRegistrationRequest,
    AgentRuntimeSessionRegistrationResponse, CodexApprovalDecisionRequest, CodexRunRequest,
    CodexSteerRequest, HostBridgeReconfigureRequest, ManagedAgentSnapshot, SessionArchiveRequest,
    SessionJoinRequest, SessionLeaveRequest, SessionMutationResponse, SessionTitleRequest,
    SignalAckRequest, VoiceAudioChunkRequest, VoiceSessionFinishRequest, VoiceSessionStartRequest,
    VoiceTranscriptUpdateRequest, WsErrorPayload, WsRequest, WsResponse,
    bind_control_plane_actor_value,
};
use crate::daemon::service;
use crate::daemon::voice::{append_audio_chunk, append_transcript, finish_session, start_session};
use crate::errors::{CliError, CliErrorKind};
use crate::sandbox;
use crate::workspace::adopter::AdoptionOutcome;

use super::frames::{error_response, error_response_with_payload};
use super::mutations::{cli_error_response, dispatch_query_result};
use super::params::{extract_session_id, extract_string_param};

mod managed_agents;
#[cfg(test)]
mod tests;
mod voice;

pub(crate) use self::managed_agents::{
    dispatch_managed_agent_input, dispatch_managed_agent_interrupt_codex,
    dispatch_managed_agent_ready, dispatch_managed_agent_resize,
    dispatch_managed_agent_resolve_acp_permission, dispatch_managed_agent_resolve_codex_approval,
    dispatch_managed_agent_start_acp, dispatch_managed_agent_start_codex,
    dispatch_managed_agent_start_terminal, dispatch_managed_agent_steer_codex,
    dispatch_managed_agent_stop, dispatch_managed_agent_stop_acp,
};
pub(crate) use self::voice::{
    dispatch_voice_append_audio, dispatch_voice_append_transcript, dispatch_voice_finish_session,
    dispatch_voice_start_session,
};

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
    if let Err(error) = record_adopt_in_db(state, &outcome).await {
        return cli_error_response(&request.id, &error);
    }
    if let Some(async_db) = state.async_db.get() {
        service::broadcast_sessions_updated_async(&state.sender, Some(async_db.as_ref())).await;
    } else if let Err(error) = broadcast_sessions_updated_sync(state) {
        return cli_error_response(&request.id, &error);
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
        match with_shared_db(state, |db| {
            service::delete_session_direct(&session_id, Some(db))
        }) {
            Ok(deleted) => {
                if deleted && let Err(error) = broadcast_sessions_updated_sync(state) {
                    return cli_error_response(&request.id, &error);
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

pub(crate) async fn dispatch_session_archive(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> WsResponse {
    let Some(session_id) = extract_session_id(&request.params) else {
        return error_response(&request.id, "MISSING_PARAM", "missing session_id");
    };
    let mut params = request.params.clone();
    bind_control_plane_actor_value(&mut params);
    let body: SessionArchiveRequest = match serde_json::from_value(params) {
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
        service::archive_session_async(&session_id, &body, async_db.as_ref()).await
    } else {
        with_shared_db(state, |db| {
            service::archive_session(&session_id, &body, Some(db))
        })
    };
    if result.is_ok() {
        if let Some(async_db) = state.async_db.get() {
            service::broadcast_sessions_updated_async(&state.sender, Some(async_db.as_ref())).await;
        } else if let Err(error) = broadcast_sessions_updated_sync(state) {
            return cli_error_response(&request.id, &error);
        }
    }
    dispatch_query_result(&request.id, result)
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
        with_shared_db(state, |db| {
            service::join_session_direct(&session_id, &body, Some(db))
                .map(|state| SessionMutationResponse { state })
        })
    };

    if result.is_ok()
        && let Err(error) = broadcast_session_snapshot(state, &session_id).await
    {
        return cli_error_response(&request.id, &error);
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
        let db_guard = match sync_db_guard(state) {
            Ok(db_guard) => db_guard,
            Err(error) => return cli_error_response(&request.id, &error),
        };
        service::register_agent_runtime_session_direct(&session_id, &body, db_guard.as_deref())
            .map(|registered| AgentRuntimeSessionRegistrationResponse { registered })
    };

    if result.as_ref().is_ok_and(|response| response.registered)
        && let Err(error) = broadcast_session_snapshot(state, &session_id).await
    {
        return cli_error_response(&request.id, &error);
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
        with_shared_db(state, |db| {
            service::update_session_title_direct(&session_id, &body, db)
                .map(|state| SessionMutationResponse { state })
        })
    };

    if result.is_ok()
        && let Err(error) = broadcast_session_snapshot(state, &session_id).await
    {
        return cli_error_response(&request.id, &error);
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
        with_shared_db(state, |db| {
            service::leave_session(&session_id, &body, Some(db))
        })
    };

    if result.is_ok()
        && let Err(error) = broadcast_session_snapshot(state, &session_id).await
    {
        return cli_error_response(&request.id, &error);
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
        let db_guard = match sync_db_guard(state) {
            Ok(db_guard) => db_guard,
            Err(error) => return cli_error_response(&request.id, &error),
        };
        service::record_signal_ack_direct(&session_id, &body, db_guard.as_deref())
    };

    match result {
        Ok(()) => {
            if let Err(error) = broadcast_session_snapshot(state, &session_id).await {
                return cli_error_response(&request.id, &error);
            }
            dispatch_query_result(&request.id, Ok::<_, CliError>(json!({ "ok": true })))
        }
        Err(error) => cli_error_response(&request.id, &error),
    }
}

async fn dispatch_managed_agent_response(
    request: &WsRequest,
    state: &DaemonHttpState,
    result: Result<ManagedAgentSnapshot, CliError>,
) -> WsResponse {
    match result {
        Ok(snapshot) => {
            if let Err(error) = broadcast_session_snapshot(state, snapshot.session_id()).await {
                return cli_error_response(&request.id, &error);
            }
            dispatch_query_result(&request.id, Ok::<_, CliError>(snapshot))
        }
        Err(error) => cli_error_response(&request.id, &error),
    }
}

async fn broadcast_session_snapshot(
    state: &DaemonHttpState,
    session_id: &str,
) -> Result<(), CliError> {
    if let Some(async_db) = state.async_db.get() {
        service::broadcast_session_snapshot_async(
            &state.sender,
            session_id,
            Some(async_db.as_ref()),
        )
        .await;
        return Ok(());
    }
    let db_guard = sync_db_guard(state)?;
    service::broadcast_session_snapshot(&state.sender, session_id, db_guard.as_deref());
    Ok(())
}

fn lock_db(db: &Arc<Mutex<DaemonDb>>) -> Result<MutexGuard<'_, DaemonDb>, CliError> {
    db.lock().map_err(|error| {
        CliErrorKind::workflow_io(format!("daemon database lock poisoned: {error}")).into()
    })
}

fn sync_db_guard(state: &DaemonHttpState) -> Result<Option<MutexGuard<'_, DaemonDb>>, CliError> {
    state.db.get().map(lock_db).transpose()
}

fn with_shared_db<T>(
    state: &DaemonHttpState,
    action: impl FnOnce(&DaemonDb) -> Result<T, CliError>,
) -> Result<T, CliError> {
    let db = ensure_shared_db(&state.db)?;
    let db_guard = lock_db(&db)?;
    action(&db_guard)
}

fn broadcast_sessions_updated_sync(state: &DaemonHttpState) -> Result<(), CliError> {
    with_shared_db(state, |db| {
        service::broadcast_sessions_updated(&state.sender, Some(db));
        Ok(())
    })
}
