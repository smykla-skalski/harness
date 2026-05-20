use std::sync::{Arc, Mutex};

use crate::daemon::http::DaemonHttpState;
use crate::daemon::protocol::{WsRequest, WsResponse, ws_methods};

use super::super::connection::ConnectionState;
use super::super::dependency_updates::dispatch_dependency_updates_method;
use super::super::frames::ok_response;
use super::super::mutations::{dispatch_session_start, dispatch_set_log_level};
use super::super::parity::{
    dispatch_bridge_reconfigure, dispatch_managed_agent_input,
    dispatch_managed_agent_interrupt_codex, dispatch_managed_agent_ready,
    dispatch_managed_agent_resize, dispatch_managed_agent_resolve_acp_permission,
    dispatch_managed_agent_resolve_codex_approval, dispatch_managed_agent_start_acp,
    dispatch_managed_agent_start_codex, dispatch_managed_agent_start_terminal,
    dispatch_managed_agent_prompt_acp, dispatch_managed_agent_steer_codex,
    dispatch_managed_agent_stop, dispatch_managed_agent_stop_acp, dispatch_session_adopt,
    dispatch_session_archive,
    dispatch_session_delete, dispatch_session_join, dispatch_session_leave,
    dispatch_session_runtime_session, dispatch_session_title, dispatch_signal_ack,
    dispatch_voice_append_audio, dispatch_voice_append_transcript, dispatch_voice_finish_session,
    dispatch_voice_start_session,
};
use super::super::queries::{
    dispatch_read_query, handle_session_subscribe, handle_session_unsubscribe,
    handle_stream_subscribe, handle_stream_unsubscribe,
};
use super::super::task_board::dispatch_task_board_method;
use super::mutation_handlers::{
    dispatch_agent_change_role, dispatch_agent_remove, dispatch_improver_apply,
    dispatch_leader_transfer, dispatch_session_end, dispatch_session_observe,
    dispatch_signal_cancel, dispatch_signal_send, dispatch_task_arbitrate, dispatch_task_assign,
    dispatch_task_checkpoint, dispatch_task_claim_review, dispatch_task_create,
    dispatch_task_delete, dispatch_task_drop, dispatch_task_queue_policy,
    dispatch_task_respond_review, dispatch_task_submit_for_review, dispatch_task_submit_review,
    dispatch_task_update,
};

pub(super) async fn dispatch_known_method(
    request: &WsRequest,
    state: &DaemonHttpState,
    connection: &Arc<Mutex<ConnectionState>>,
) -> Option<WsResponse> {
    if let Some(response) = dispatch_dependency_updates_method(request, state).await {
        return Some(response);
    }
    if let Some(response) = dispatch_task_board_method(request, state).await {
        return Some(response);
    }
    if let Some(response) = dispatch_core_method(request, state, connection).await {
        return Some(response);
    }
    if let Some(response) = dispatch_collaboration_mutation(request, state).await {
        return Some(response);
    }
    dispatch_runtime_mutation(request, state).await
}

async fn dispatch_collaboration_mutation(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> Option<WsResponse> {
    if let Some(response) = dispatch_task_mutation(request, state).await {
        return Some(response);
    }
    if let Some(response) = dispatch_agent_mutation(request, state).await {
        return Some(response);
    }
    dispatch_session_mutation(request, state).await
}

async fn dispatch_runtime_mutation(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> Option<WsResponse> {
    if let Some(response) = dispatch_managed_agent_mutation(request, state).await {
        return Some(response);
    }
    dispatch_voice_mutation(request, state).await
}

async fn dispatch_core_method(
    request: &WsRequest,
    state: &DaemonHttpState,
    connection: &Arc<Mutex<ConnectionState>>,
) -> Option<WsResponse> {
    if let Some(response) = dispatch_misc_method(request, state, connection).await {
        return Some(response);
    }
    dispatch_read_method(request, state).await
}

async fn dispatch_misc_method(
    request: &WsRequest,
    state: &DaemonHttpState,
    connection: &Arc<Mutex<ConnectionState>>,
) -> Option<WsResponse> {
    match request.method.as_str() {
        ws_methods::PING => Some(ok_response(
            &request.id,
            serde_json::json!({ "pong": true }),
        )),
        ws_methods::DAEMON_SET_LOG_LEVEL => Some(dispatch_set_log_level(request, state)),
        ws_methods::SESSION_SUBSCRIBE => {
            Some(handle_session_subscribe(request, state, connection).await)
        }
        ws_methods::SESSION_UNSUBSCRIBE => Some(handle_session_unsubscribe(request, connection)),
        ws_methods::STREAM_SUBSCRIBE => {
            Some(handle_stream_subscribe(request, state, connection).await)
        }
        ws_methods::STREAM_UNSUBSCRIBE => Some(handle_stream_unsubscribe(request, connection)),
        _ => None,
    }
}

async fn dispatch_read_method(request: &WsRequest, state: &DaemonHttpState) -> Option<WsResponse> {
    if matches!(
        request.method.as_str(),
        ws_methods::HEALTH
            | ws_methods::DIAGNOSTICS
            | ws_methods::CONFIG
            | ws_methods::DAEMON_STOP
            | ws_methods::DAEMON_LOG_LEVEL
            | ws_methods::PROJECTS
            | ws_methods::SESSIONS
            | ws_methods::RUNTIME_SESSION_RESOLVE
            | ws_methods::RUNTIMES_PROBE
            | ws_methods::SESSION_DETAIL
            | ws_methods::SESSION_TIMELINE
            | ws_methods::SESSION_MANAGED_AGENTS
            | ws_methods::MANAGED_AGENT_DETAIL
            | ws_methods::MANAGED_AGENTS_CODEX_INSPECT
            | ws_methods::MANAGED_AGENTS_CODEX_TRANSCRIPT
            | ws_methods::MANAGED_AGENTS_ACP_INSPECT
            | ws_methods::MANAGED_AGENTS_ACP_TRANSCRIPT
    ) {
        Some(dispatch_read_query(request, state).await)
    } else {
        None
    }
}

async fn dispatch_task_mutation(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> Option<WsResponse> {
    if let Some(response) = dispatch_task_work_mutation(request, state).await {
        return Some(response);
    }
    if let Some(response) = dispatch_task_review_mutation(request, state).await {
        return Some(response);
    }
    dispatch_task_lifecycle_mutation(request, state).await
}

async fn dispatch_task_review_mutation(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> Option<WsResponse> {
    if let Some(response) = dispatch_task_review_primary(request, state).await {
        return Some(response);
    }
    dispatch_task_review_terminal(request, state).await
}

async fn dispatch_task_review_primary(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> Option<WsResponse> {
    match request.method.as_str() {
        ws_methods::TASK_SUBMIT_FOR_REVIEW => {
            Some(dispatch_task_submit_for_review(request, state).await)
        }
        ws_methods::TASK_CLAIM_REVIEW => Some(dispatch_task_claim_review(request, state).await),
        ws_methods::TASK_SUBMIT_REVIEW => Some(dispatch_task_submit_review(request, state).await),
        _ => None,
    }
}

async fn dispatch_task_review_terminal(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> Option<WsResponse> {
    match request.method.as_str() {
        ws_methods::TASK_RESPOND_REVIEW => Some(dispatch_task_respond_review(request, state).await),
        ws_methods::TASK_ARBITRATE => Some(dispatch_task_arbitrate(request, state).await),
        ws_methods::IMPROVER_APPLY => Some(dispatch_improver_apply(request, state).await),
        _ => None,
    }
}

async fn dispatch_task_work_mutation(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> Option<WsResponse> {
    match request.method.as_str() {
        ws_methods::TASK_CREATE => Some(dispatch_task_create(request, state).await),
        ws_methods::TASK_DELETE => Some(dispatch_task_delete(request, state).await),
        ws_methods::TASK_ASSIGN => Some(dispatch_task_assign(request, state).await),
        ws_methods::TASK_CHECKPOINT => Some(dispatch_task_checkpoint(request, state).await),
        _ => None,
    }
}

async fn dispatch_task_lifecycle_mutation(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> Option<WsResponse> {
    match request.method.as_str() {
        ws_methods::TASK_DROP => Some(dispatch_task_drop(request, state).await),
        ws_methods::TASK_QUEUE_POLICY => Some(dispatch_task_queue_policy(request, state).await),
        ws_methods::TASK_UPDATE => Some(dispatch_task_update(request, state).await),
        _ => None,
    }
}

async fn dispatch_agent_mutation(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> Option<WsResponse> {
    match request.method.as_str() {
        ws_methods::AGENT_CHANGE_ROLE => Some(dispatch_agent_change_role(request, state).await),
        ws_methods::AGENT_REMOVE => Some(dispatch_agent_remove(request, state).await),
        _ => None,
    }
}

async fn dispatch_session_mutation(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> Option<WsResponse> {
    if let Some(response) = dispatch_session_control_mutation(request, state).await {
        return Some(response);
    }
    dispatch_session_signal_mutation(request, state).await
}

async fn dispatch_session_control_mutation(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> Option<WsResponse> {
    if let Some(response) = dispatch_session_setup_mutation(request, state).await {
        return Some(response);
    }
    dispatch_session_teardown_mutation(request, state).await
}

async fn dispatch_session_setup_mutation(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> Option<WsResponse> {
    if let Some(response) = dispatch_session_creation_mutation(request, state).await {
        return Some(response);
    }
    dispatch_session_registration_mutation(request, state).await
}

async fn dispatch_session_creation_mutation(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> Option<WsResponse> {
    match request.method.as_str() {
        ws_methods::SESSION_START => Some(dispatch_session_start(request, state).await),
        ws_methods::SESSION_ADOPT => Some(dispatch_session_adopt(request, state).await),
        ws_methods::SESSION_DELETE => Some(dispatch_session_delete(request, state).await),
        _ => None,
    }
}

async fn dispatch_session_registration_mutation(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> Option<WsResponse> {
    match request.method.as_str() {
        ws_methods::SESSION_JOIN => Some(dispatch_session_join(request, state).await),
        ws_methods::SESSION_RUNTIME_SESSION => {
            Some(dispatch_session_runtime_session(request, state).await)
        }
        ws_methods::SESSION_TITLE => Some(dispatch_session_title(request, state).await),
        _ => None,
    }
}

async fn dispatch_session_teardown_mutation(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> Option<WsResponse> {
    match request.method.as_str() {
        ws_methods::LEADER_TRANSFER => Some(dispatch_leader_transfer(request, state).await),
        ws_methods::SESSION_END => Some(dispatch_session_end(request, state).await),
        ws_methods::SESSION_ARCHIVE => Some(dispatch_session_archive(request, state).await),
        ws_methods::SESSION_LEAVE => Some(dispatch_session_leave(request, state).await),
        ws_methods::BRIDGE_RECONFIGURE => Some(dispatch_bridge_reconfigure(request, state).await),
        _ => None,
    }
}

async fn dispatch_session_signal_mutation(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> Option<WsResponse> {
    match request.method.as_str() {
        ws_methods::SIGNAL_SEND => Some(dispatch_signal_send(request, state).await),
        ws_methods::SIGNAL_CANCEL => Some(dispatch_signal_cancel(request, state).await),
        ws_methods::SIGNAL_ACK => Some(dispatch_signal_ack(request, state).await),
        ws_methods::SESSION_OBSERVE => Some(dispatch_session_observe(request, state).await),
        _ => None,
    }
}

async fn dispatch_managed_agent_mutation(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> Option<WsResponse> {
    if let Some(response) = dispatch_terminal_managed_agent_mutation(request, state).await {
        return Some(response);
    }
    if let Some(response) = dispatch_codex_managed_agent_mutation(request, state).await {
        return Some(response);
    }
    dispatch_acp_managed_agent_mutation(request, state).await
}

async fn dispatch_terminal_managed_agent_mutation(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> Option<WsResponse> {
    match request.method.as_str() {
        ws_methods::MANAGED_AGENT_START_TERMINAL => {
            Some(dispatch_managed_agent_start_terminal(request, state).await)
        }
        ws_methods::MANAGED_AGENT_INPUT => Some(dispatch_managed_agent_input(request, state).await),
        ws_methods::MANAGED_AGENT_RESIZE => {
            Some(dispatch_managed_agent_resize(request, state).await)
        }
        ws_methods::MANAGED_AGENT_STOP => Some(dispatch_managed_agent_stop(request, state).await),
        ws_methods::MANAGED_AGENT_READY => Some(dispatch_managed_agent_ready(request, state).await),
        _ => None,
    }
}

async fn dispatch_codex_managed_agent_mutation(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> Option<WsResponse> {
    match request.method.as_str() {
        ws_methods::MANAGED_AGENT_START_CODEX => {
            Some(dispatch_managed_agent_start_codex(request, state).await)
        }
        ws_methods::MANAGED_AGENT_STEER_CODEX => {
            Some(dispatch_managed_agent_steer_codex(request, state).await)
        }
        ws_methods::MANAGED_AGENT_INTERRUPT_CODEX => {
            Some(dispatch_managed_agent_interrupt_codex(request, state).await)
        }
        ws_methods::MANAGED_AGENT_RESOLVE_CODEX_APPROVAL => {
            Some(dispatch_managed_agent_resolve_codex_approval(request, state).await)
        }
        _ => None,
    }
}

async fn dispatch_acp_managed_agent_mutation(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> Option<WsResponse> {
    match request.method.as_str() {
        ws_methods::MANAGED_AGENT_START_ACP => {
            Some(dispatch_managed_agent_start_acp(request, state).await)
        }
        ws_methods::MANAGED_AGENT_STOP_ACP => {
            Some(dispatch_managed_agent_stop_acp(request, state).await)
        }
        ws_methods::MANAGED_AGENT_PROMPT_ACP => {
            Some(dispatch_managed_agent_prompt_acp(request, state).await)
        }
        ws_methods::MANAGED_AGENT_RESOLVE_ACP_PERMISSION => {
            Some(dispatch_managed_agent_resolve_acp_permission(request, state).await)
        }
        _ => None,
    }
}

async fn dispatch_voice_mutation(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> Option<WsResponse> {
    match request.method.as_str() {
        ws_methods::VOICE_START_SESSION => Some(dispatch_voice_start_session(request, state).await),
        ws_methods::VOICE_APPEND_AUDIO => Some(dispatch_voice_append_audio(request, state).await),
        ws_methods::VOICE_APPEND_TRANSCRIPT => {
            Some(dispatch_voice_append_transcript(request, state).await)
        }
        ws_methods::VOICE_FINISH_SESSION => {
            Some(dispatch_voice_finish_session(request, state).await)
        }
        _ => None,
    }
}
