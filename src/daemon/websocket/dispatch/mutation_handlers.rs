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
