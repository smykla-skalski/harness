use utoipa_axum::{router::OpenApiRouter, routes};

use crate::daemon::service;

use super::DaemonHttpState;

pub(super) mod mutations;
pub(super) mod review;

pub(super) use mutations::{
    post_task_assign, post_task_checkpoint, post_task_create, post_task_delete, post_task_drop,
    post_task_queue_policy, post_task_update,
};
pub(super) use review::{
    post_task_arbitrate, post_task_claim_review, post_task_respond_review,
    post_task_submit_for_review, post_task_submit_review,
};

pub(super) fn task_routes() -> OpenApiRouter<DaemonHttpState> {
    OpenApiRouter::new()
        .routes(routes!(post_task_create))
        .routes(routes!(post_task_delete))
        .routes(routes!(post_task_assign))
        .routes(routes!(post_task_drop))
        .routes(routes!(post_task_queue_policy))
        .routes(routes!(post_task_update))
        .routes(routes!(post_task_checkpoint))
        .routes(routes!(post_task_submit_for_review))
        .routes(routes!(post_task_claim_review))
        .routes(routes!(post_task_submit_review))
        .routes(routes!(post_task_respond_review))
        .routes(routes!(post_task_arbitrate))
}

async fn broadcast_task_snapshot(state: &DaemonHttpState, session_id: &str) {
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
