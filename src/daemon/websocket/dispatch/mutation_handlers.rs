use crate::daemon::protocol::{
    ImproverApplyRequest, TaskArbitrateRequest, TaskClaimReviewRequest, TaskRespondReviewRequest,
    TaskSubmitForReviewRequest, TaskSubmitReviewRequest,
};

use super::{
    AgentRemoveRequest, DaemonHttpState, LeaderTransferRequest, ObserveSessionRequest,
    RoleChangeRequest, SessionEndRequest, SignalCancelRequest, SignalSendRequest,
    TaskAssignRequest, TaskCheckpointRequest, TaskCreateRequest, TaskDropRequest,
    TaskQueuePolicyRequest, TaskUpdateRequest, WsRequest, WsResponse,
    dispatch_mutation_prefer_async, dispatch_mutation_with_agent_prefer_async,
    dispatch_mutation_with_task_prefer_async, service,
};

pub(super) async fn dispatch_task_create(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> WsResponse {
    dispatch_mutation_prefer_async(
        request,
        state,
        |session_id, params, db| {
            let body: TaskCreateRequest = serde_json::from_value(params)?;
            service::create_task(&session_id, &body, db).map_err(Into::into)
        },
        |session_id, params, async_db| async move {
            let body: TaskCreateRequest = serde_json::from_value(params)?;
            service::create_task_async(&session_id, &body, &async_db)
                .await
                .map_err(Into::into)
        },
    )
    .await
}

pub(super) async fn dispatch_task_assign(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> WsResponse {
    dispatch_mutation_with_task_prefer_async(
        request,
        state,
        |session_id, task_id, params, db| {
            let body: TaskAssignRequest = serde_json::from_value(params)?;
            service::assign_task(&session_id, &task_id, &body, db).map_err(Into::into)
        },
        |session_id, task_id, params, async_db| async move {
            let body: TaskAssignRequest = serde_json::from_value(params)?;
            service::assign_task_async(&session_id, &task_id, &body, &async_db)
                .await
                .map_err(Into::into)
        },
    )
    .await
}

pub(super) async fn dispatch_task_drop(request: &WsRequest, state: &DaemonHttpState) -> WsResponse {
    dispatch_mutation_with_task_prefer_async(
        request,
        state,
        |session_id, task_id, params, db| {
            let body: TaskDropRequest = serde_json::from_value(params)?;
            service::drop_task(&session_id, &task_id, &body, db).map_err(Into::into)
        },
        |session_id, task_id, params, async_db| async move {
            let body: TaskDropRequest = serde_json::from_value(params)?;
            service::drop_task_async(&session_id, &task_id, &body, &async_db)
                .await
                .map_err(Into::into)
        },
    )
    .await
}

pub(super) async fn dispatch_task_queue_policy(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> WsResponse {
    dispatch_mutation_with_task_prefer_async(
        request,
        state,
        |session_id, task_id, params, db| {
            let body: TaskQueuePolicyRequest = serde_json::from_value(params)?;
            service::update_task_queue_policy(&session_id, &task_id, &body, db).map_err(Into::into)
        },
        |session_id, task_id, params, async_db| async move {
            let body: TaskQueuePolicyRequest = serde_json::from_value(params)?;
            service::update_task_queue_policy_async(&session_id, &task_id, &body, &async_db)
                .await
                .map_err(Into::into)
        },
    )
    .await
}

pub(super) async fn dispatch_task_update(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> WsResponse {
    dispatch_mutation_with_task_prefer_async(
        request,
        state,
        |session_id, task_id, params, db| {
            let body: TaskUpdateRequest = serde_json::from_value(params)?;
            service::update_task(&session_id, &task_id, &body, db).map_err(Into::into)
        },
        |session_id, task_id, params, async_db| async move {
            let body: TaskUpdateRequest = serde_json::from_value(params)?;
            service::update_task_async(&session_id, &task_id, &body, &async_db)
                .await
                .map_err(Into::into)
        },
    )
    .await
}

pub(super) async fn dispatch_task_checkpoint(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> WsResponse {
    dispatch_mutation_with_task_prefer_async(
        request,
        state,
        |session_id, task_id, params, db| {
            let body: TaskCheckpointRequest = serde_json::from_value(params)?;
            service::checkpoint_task(&session_id, &task_id, &body, db).map_err(Into::into)
        },
        |session_id, task_id, params, async_db| async move {
            let body: TaskCheckpointRequest = serde_json::from_value(params)?;
            service::checkpoint_task_async(&session_id, &task_id, &body, &async_db)
                .await
                .map_err(Into::into)
        },
    )
    .await
}

pub(super) async fn dispatch_agent_change_role(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> WsResponse {
    dispatch_mutation_with_agent_prefer_async(
        request,
        state,
        |session_id, agent_id, params, db| {
            let body: RoleChangeRequest = serde_json::from_value(params)?;
            service::change_role(&session_id, &agent_id, &body, db).map_err(Into::into)
        },
        |session_id, agent_id, params, async_db| async move {
            let body: RoleChangeRequest = serde_json::from_value(params)?;
            service::change_role_async(&session_id, &agent_id, &body, &async_db)
                .await
                .map_err(Into::into)
        },
    )
    .await
}

pub(super) async fn dispatch_agent_remove(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> WsResponse {
    dispatch_mutation_with_agent_prefer_async(
        request,
        state,
        |session_id, agent_id, params, db| {
            let body: AgentRemoveRequest = serde_json::from_value(params)?;
            service::remove_agent(&session_id, &agent_id, &body, db).map_err(Into::into)
        },
        |session_id, agent_id, params, async_db| async move {
            let body: AgentRemoveRequest = serde_json::from_value(params)?;
            service::remove_agent_async(&session_id, &agent_id, &body, &async_db)
                .await
                .map_err(Into::into)
        },
    )
    .await
}

pub(super) async fn dispatch_leader_transfer(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> WsResponse {
    dispatch_mutation_prefer_async(
        request,
        state,
        |session_id, params, db| {
            let body: LeaderTransferRequest = serde_json::from_value(params)?;
            service::transfer_leader(&session_id, &body, db).map_err(Into::into)
        },
        |session_id, params, async_db| async move {
            let body: LeaderTransferRequest = serde_json::from_value(params)?;
            service::transfer_leader_async(&session_id, &body, &async_db)
                .await
                .map_err(Into::into)
        },
    )
    .await
}

pub(super) async fn dispatch_session_end(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> WsResponse {
    dispatch_mutation_prefer_async(
        request,
        state,
        |session_id, params, db| {
            let body: SessionEndRequest = serde_json::from_value(params)?;
            service::end_session(&session_id, &body, db).map_err(Into::into)
        },
        |session_id, params, async_db| async move {
            let body: SessionEndRequest = serde_json::from_value(params)?;
            service::end_session_async(&session_id, &body, &async_db)
                .await
                .map_err(Into::into)
        },
    )
    .await
}

pub(super) async fn dispatch_signal_send(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> WsResponse {
    dispatch_mutation_prefer_async(
        request,
        state,
        |session_id, params, db| {
            let body: SignalSendRequest = serde_json::from_value(params)?;
            service::send_signal(&session_id, &body, db, Some(&state.agent_tui_manager))
                .map_err(Into::into)
        },
        |session_id, params, async_db| async move {
            let body: SignalSendRequest = serde_json::from_value(params)?;
            service::send_signal_async(
                &session_id,
                &body,
                &async_db,
                Some(&state.agent_tui_manager),
            )
            .await
            .map_err(Into::into)
        },
    )
    .await
}

pub(super) async fn dispatch_signal_cancel(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> WsResponse {
    dispatch_mutation_prefer_async(
        request,
        state,
        |session_id, params, db| {
            let body: SignalCancelRequest = serde_json::from_value(params)?;
            service::cancel_signal(&session_id, &body, db).map_err(Into::into)
        },
        |session_id, params, async_db| async move {
            let body: SignalCancelRequest = serde_json::from_value(params)?;
            service::cancel_signal_async(&session_id, &body, &async_db)
                .await
                .map_err(Into::into)
        },
    )
    .await
}

pub(super) async fn dispatch_session_observe(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> WsResponse {
    dispatch_mutation_prefer_async(
        request,
        state,
        |session_id, params, db| {
            let body: ObserveSessionRequest = serde_json::from_value(params)?;
            service::observe_session(&session_id, Some(&body), db).map_err(Into::into)
        },
        |session_id, params, async_db| async move {
            let body: ObserveSessionRequest = serde_json::from_value(params)?;
            service::observe_session_async(&session_id, Some(&body), &async_db)
                .await
                .map_err(Into::into)
        },
    )
    .await
}

pub(super) async fn dispatch_task_submit_for_review(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> WsResponse {
    dispatch_mutation_with_task_prefer_async(
        request,
        state,
        |session_id, task_id, params, db| {
            let body: TaskSubmitForReviewRequest = serde_json::from_value(params)?;
            service::submit_for_review(&session_id, &task_id, &body, db).map_err(Into::into)
        },
        |session_id, task_id, params, async_db| async move {
            let body: TaskSubmitForReviewRequest = serde_json::from_value(params)?;
            service::submit_for_review_async(&session_id, &task_id, &body, &async_db)
                .await
                .map_err(Into::into)
        },
    )
    .await
}

pub(super) async fn dispatch_task_claim_review(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> WsResponse {
    dispatch_mutation_with_task_prefer_async(
        request,
        state,
        |session_id, task_id, params, db| {
            let body: TaskClaimReviewRequest = serde_json::from_value(params)?;
            service::claim_review(&session_id, &task_id, &body, db).map_err(Into::into)
        },
        |session_id, task_id, params, async_db| async move {
            let body: TaskClaimReviewRequest = serde_json::from_value(params)?;
            service::claim_review_async(&session_id, &task_id, &body, &async_db)
                .await
                .map_err(Into::into)
        },
    )
    .await
}

pub(super) async fn dispatch_task_submit_review(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> WsResponse {
    dispatch_mutation_with_task_prefer_async(
        request,
        state,
        |session_id, task_id, params, db| {
            let body: TaskSubmitReviewRequest = serde_json::from_value(params)?;
            service::submit_review(&session_id, &task_id, &body, db).map_err(Into::into)
        },
        |session_id, task_id, params, async_db| async move {
            let body: TaskSubmitReviewRequest = serde_json::from_value(params)?;
            service::submit_review_async(&session_id, &task_id, &body, &async_db)
                .await
                .map_err(Into::into)
        },
    )
    .await
}

pub(super) async fn dispatch_task_respond_review(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> WsResponse {
    dispatch_mutation_with_task_prefer_async(
        request,
        state,
        |session_id, task_id, params, db| {
            let body: TaskRespondReviewRequest = serde_json::from_value(params)?;
            service::respond_review(&session_id, &task_id, &body, db).map_err(Into::into)
        },
        |session_id, task_id, params, async_db| async move {
            let body: TaskRespondReviewRequest = serde_json::from_value(params)?;
            service::respond_review_async(&session_id, &task_id, &body, &async_db)
                .await
                .map_err(Into::into)
        },
    )
    .await
}

pub(super) async fn dispatch_task_arbitrate(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> WsResponse {
    dispatch_mutation_with_task_prefer_async(
        request,
        state,
        |session_id, task_id, params, db| {
            let body: TaskArbitrateRequest = serde_json::from_value(params)?;
            service::arbitrate_review(&session_id, &task_id, &body, db).map_err(Into::into)
        },
        |session_id, task_id, params, async_db| async move {
            let body: TaskArbitrateRequest = serde_json::from_value(params)?;
            service::arbitrate_review_async(&session_id, &task_id, &body, &async_db)
                .await
                .map_err(Into::into)
        },
    )
    .await
}

pub(super) async fn dispatch_improver_apply(
    request: &WsRequest,
    state: &DaemonHttpState,
) -> WsResponse {
    use crate::daemon::protocol::bind_control_plane_actor_value;
    use crate::daemon::websocket::frames::{error_response, ok_response};

    let mut params = request.params.clone();
    bind_control_plane_actor_value(&mut params);
    let session_id = params
        .get("session_id")
        .and_then(|value| value.as_str())
        .unwrap_or_default()
        .to_string();
    let body: ImproverApplyRequest = match serde_json::from_value(params) {
        Ok(body) => body,
        Err(error) => {
            return error_response(
                &request.id,
                "INVALID_PARAM",
                &format!("invalid improver apply request: {error}"),
            );
        }
    };
    let result = if let Some(async_db) = state.async_db.get().cloned() {
        service::improver_apply_async(&session_id, &body, async_db.as_ref()).await
    } else {
        let db_guard = state.db.get().map(|db| db.lock().expect("db lock"));
        service::improver_apply(&session_id, &body, db_guard.as_deref())
    };
    match result {
        Ok(outcome) => match serde_json::to_value(outcome) {
            Ok(value) => ok_response(&request.id, value),
            Err(error) => error_response(
                &request.id,
                "SERIALIZE_ERROR",
                &format!("failed to serialize improver outcome: {error}"),
            ),
        },
        Err(error) => error_response(
            &request.id,
            "IMPROVER_APPLY_FAILED",
            &error.to_string(),
        ),
    }
}
