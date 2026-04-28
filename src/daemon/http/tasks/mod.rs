use axum::Router;
use axum::routing::post;

use crate::daemon::protocol::http_paths;
use crate::daemon::service;

use super::DaemonHttpState;

mod mutations;
mod review;

pub(super) use mutations::{
    post_task_assign, post_task_checkpoint, post_task_create, post_task_drop,
    post_task_queue_policy, post_task_update,
};
pub(super) use review::{
    post_task_arbitrate, post_task_claim_review, post_task_respond_review, post_task_submit_review,
    post_task_submit_for_review,
};

pub(super) fn task_routes() -> Router<DaemonHttpState> {
    Router::new()
        .route(http_paths::SESSION_TASK_CREATE, post(post_task_create))
        .route(http_paths::SESSION_TASK_ASSIGN, post(post_task_assign))
        .route(http_paths::SESSION_TASK_DROP, post(post_task_drop))
        .route(
            http_paths::SESSION_TASK_QUEUE_POLICY,
            post(post_task_queue_policy),
        )
        .route(http_paths::SESSION_TASK_UPDATE, post(post_task_update))
        .route(
            http_paths::SESSION_TASK_CHECKPOINT,
            post(post_task_checkpoint),
        )
        .route(
            http_paths::SESSION_TASK_SUBMIT_FOR_REVIEW,
            post(post_task_submit_for_review),
        )
        .route(
            http_paths::SESSION_TASK_CLAIM_REVIEW,
            post(post_task_claim_review),
        )
        .route(
            http_paths::SESSION_TASK_SUBMIT_REVIEW,
            post(post_task_submit_review),
        )
        .route(
            http_paths::SESSION_TASK_RESPOND_REVIEW,
            post(post_task_respond_review),
        )
        .route(
            http_paths::SESSION_TASK_ARBITRATE,
            post(post_task_arbitrate),
        )
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
