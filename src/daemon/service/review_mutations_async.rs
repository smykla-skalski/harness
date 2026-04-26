//! Async review + improver workflow mutations for the daemon service.
//!
//! Async variants apply the review state mutation directly against the async
//! daemon DB resolved state, then save + bump. Shared sync-path helpers live
//! in `review_mutations`.

use crate::agents::runtime::runtime_for_name;
use crate::daemon::index as daemon_index;
use crate::daemon::protocol::{
    SessionDetail, TaskArbitrateRequest, TaskClaimReviewRequest, TaskRespondReviewRequest,
    TaskSubmitForReviewRequest, TaskSubmitReviewRequest,
};
use crate::errors::CliError;
use crate::session::service::{
    self as session_service, apply_arbitrate, apply_claim_review, apply_respond_review,
    apply_submit_for_review, maybe_emit_spawn_reviewer, validate_submit_review,
};
use crate::session::storage as session_storage;
use crate::session::types::{SessionState, TaskStatus};
use crate::workspace::utc_now;

use super::review_submit_txn::{apply_submit_review_in_txn, prepare_submit_review};
use super::sessions::session_detail_from_async_daemon_db;
use super::{
    build_log_entry, effective_project_dir, session_not_found, sync_file_state_from_async_db,
};

async fn resolve_async(
    async_db: &super::db::AsyncDaemonDb,
    session_id: &str,
) -> Result<daemon_index::ResolvedSession, CliError> {
    async_db
        .resolve_session(session_id)
        .await?
        .ok_or_else(|| session_not_found(session_id))
}

async fn bump_async(async_db: &super::db::AsyncDaemonDb, session_id: &str) -> Result<(), CliError> {
    async_db.bump_change(session_id).await?;
    async_db.bump_change("global").await
}

/// Submit a task for review (async path).
///
/// # Errors
/// Returns `CliError` on state or db failure.
pub(crate) async fn submit_for_review_async(
    session_id: &str,
    task_id: &str,
    request: &TaskSubmitForReviewRequest,
    async_db: &super::db::AsyncDaemonDb,
) -> Result<SessionDetail, CliError> {
    let now = utc_now();
    let (prev_status, new_status) = async_db
        .update_session_state_immediate(session_id, |state| {
            let prev_status = state.tasks.get(task_id).map(|task| task.status);
            state.state_version += 1;
            apply_submit_for_review(
                state,
                task_id,
                &request.actor,
                request.summary.as_deref(),
                &now,
            )?;
            apply_suggested_persona(state, task_id, request.suggested_persona.as_deref());
            let new_status = state.tasks.get(task_id).map(|task| task.status);
            Ok((prev_status, new_status))
        })
        .await?;
    finalize_submit_for_review_async(
        session_id,
        task_id,
        &request.actor,
        prev_status,
        new_status,
        &now,
        async_db,
    )
    .await?;
    session_detail_from_async_daemon_db(session_id, async_db).await
}

async fn finalize_submit_for_review_async(
    session_id: &str,
    task_id: &str,
    actor: &str,
    prev_status: Option<TaskStatus>,
    new_status: Option<TaskStatus>,
    now: &str,
    async_db: &super::db::AsyncDaemonDb,
) -> Result<(), CliError> {
    sync_file_state_from_async_db(async_db, session_id).await?;
    append_task_status_change_log(
        async_db,
        session_id,
        task_id,
        actor,
        prev_status,
        new_status,
    )
    .await?;
    let resolved = resolve_async(async_db, session_id).await?;
    maybe_materialize_spawn_reviewer_async(session_id, task_id, &resolved, now, async_db).await?;
    bump_async(async_db, session_id).await
}

fn apply_suggested_persona(state: &mut SessionState, task_id: &str, persona: Option<&str>) {
    let Some(persona) = persona else { return };
    let Some(task) = state.tasks.get_mut(task_id) else {
        return;
    };
    task.suggested_persona = Some(persona.to_string());
}

async fn maybe_materialize_spawn_reviewer_async(
    session_id: &str,
    task_id: &str,
    resolved: &daemon_index::ResolvedSession,
    now: &str,
    async_db: &super::db::AsyncDaemonDb,
) -> Result<(), CliError> {
    let Some(record) = maybe_emit_spawn_reviewer(&resolved.state, task_id, now) else {
        return Ok(());
    };
    let Some(runtime) = runtime_for_name(&record.runtime) else {
        return Ok(());
    };
    let project_dir = effective_project_dir(resolved).to_path_buf();
    let target_session_id = resolved
        .state
        .agents
        .get(&record.agent_id)
        .and_then(|agent| agent.agent_session_id.clone())
        .unwrap_or_else(|| record.session_id.clone());
    runtime.write_signal(&project_dir, &target_session_id, &record.signal)?;
    async_db
        .append_log_entry(&build_log_entry(
            session_id,
            session_service::log_signal_sent(
                &record.signal.signal_id,
                &record.agent_id,
                &record.signal.command,
            ),
            None,
            None,
        ))
        .await?;
    Ok(())
}

/// Claim a review slot (async path).
///
/// # Errors
/// Returns `CliError` on state or db failure.
pub(crate) async fn claim_review_async(
    session_id: &str,
    task_id: &str,
    request: &TaskClaimReviewRequest,
    async_db: &super::db::AsyncDaemonDb,
) -> Result<SessionDetail, CliError> {
    let now = utc_now();
    let (prev_status, new_status) = async_db
        .update_session_state_immediate(session_id, |state| {
            let prev_status = state.tasks.get(task_id).map(|task| task.status);
            state.state_version += 1;
            apply_claim_review(state, task_id, &request.actor, &now)?;
            let new_status = state.tasks.get(task_id).map(|task| task.status);
            Ok((prev_status, new_status))
        })
        .await?;
    sync_file_state_from_async_db(async_db, session_id).await?;
    if let (Some(prev), Some(new)) = (prev_status, new_status)
        && prev != new
    {
        async_db
            .append_log_entry(&build_log_entry(
                session_id,
                session_service::log_task_status_changed(task_id, prev, new),
                Some(&request.actor),
                None,
            ))
            .await?;
    }
    bump_async(async_db, session_id).await?;
    session_detail_from_async_daemon_db(session_id, async_db).await
}

/// Submit a reviewer verdict (async path).
///
/// # Errors
/// Returns `CliError` on state, storage, or db failure.
pub(crate) async fn submit_review_async(
    session_id: &str,
    task_id: &str,
    request: &TaskSubmitReviewRequest,
    async_db: &super::db::AsyncDaemonDb,
) -> Result<SessionDetail, CliError> {
    let resolved = resolve_async(async_db, session_id).await?;
    let now = utc_now();
    // Append to reviews.jsonl + reload OUTSIDE the SQLite immediate txn so
    // the writer lock is not held across disk I/O. Crash-recovery is via
    // `rebuild_task_reviews` on daemon start.
    let prepared = validate_and_prepare_review(&resolved, session_id, task_id, request, &now)?;
    let (prev_status, new_status) = async_db
        .update_session_state_immediate(session_id, |state| {
            state.state_version += 1;
            apply_submit_review_in_txn(state, task_id, &request.actor, &prepared, &now)
        })
        .await?;
    finalize_submit_review_async(
        session_id,
        task_id,
        &request.actor,
        prev_status,
        new_status,
        &prepared,
        async_db,
    )
    .await?;
    session_detail_from_async_daemon_db(session_id, async_db).await
}

async fn finalize_submit_review_async(
    session_id: &str,
    task_id: &str,
    actor: &str,
    prev_status: Option<TaskStatus>,
    new_status: Option<TaskStatus>,
    prepared: &super::review_submit_txn::PreparedSubmitReview,
    async_db: &super::db::AsyncDaemonDb,
) -> Result<(), CliError> {
    async_db
        .insert_task_review(session_id, task_id, &prepared.review)
        .await?;
    sync_file_state_from_async_db(async_db, session_id).await?;
    append_task_status_change_log(
        async_db,
        session_id,
        task_id,
        actor,
        prev_status,
        new_status,
    )
    .await?;
    bump_async(async_db, session_id).await
}

fn validate_and_prepare_review(
    resolved: &daemon_index::ResolvedSession,
    session_id: &str,
    task_id: &str,
    request: &TaskSubmitReviewRequest,
    now: &str,
) -> Result<super::review_submit_txn::PreparedSubmitReview, CliError> {
    let project_dir = resolved
        .project
        .project_dir
        .clone()
        .ok_or_else(|| session_not_found(session_id))?;
    let layout = session_storage::layout_from_project_dir(&project_dir, session_id)?;
    validate_submit_review(&resolved.state, task_id, &request.actor)?;
    prepare_submit_review(
        &resolved.state,
        task_id,
        &request.actor,
        request.verdict,
        &request.summary,
        &request.points,
        &layout,
        now,
    )
}

async fn append_task_status_change_log(
    async_db: &super::db::AsyncDaemonDb,
    session_id: &str,
    task_id: &str,
    actor: &str,
    prev: Option<TaskStatus>,
    new: Option<TaskStatus>,
) -> Result<(), CliError> {
    if let (Some(prev), Some(new)) = (prev, new)
        && prev != new
    {
        async_db
            .append_log_entry(&build_log_entry(
                session_id,
                session_service::log_task_status_changed(task_id, prev, new),
                Some(actor),
                None,
            ))
            .await?;
    }
    Ok(())
}

/// Worker response to reviewer feedback (async path).
///
/// # Errors
/// Returns `CliError` on state or db failure.
pub(crate) async fn respond_review_async(
    session_id: &str,
    task_id: &str,
    request: &TaskRespondReviewRequest,
    async_db: &super::db::AsyncDaemonDb,
) -> Result<SessionDetail, CliError> {
    let now = utc_now();
    let (prev_status, new_status) = async_db
        .update_session_state_immediate(session_id, |state| {
            let prev_status = state.tasks.get(task_id).map(|task| task.status);
            state.state_version += 1;
            apply_respond_review(
                state,
                task_id,
                &request.actor,
                &request.agreed,
                &request.disputed,
                request.note.as_deref(),
                &now,
            )?;
            let new_status = state.tasks.get(task_id).map(|task| task.status);
            Ok((prev_status, new_status))
        })
        .await?;
    sync_file_state_from_async_db(async_db, session_id).await?;
    if let (Some(prev), Some(new)) = (prev_status, new_status)
        && prev != new
    {
        async_db
            .append_log_entry(&build_log_entry(
                session_id,
                session_service::log_task_status_changed(task_id, prev, new),
                Some(&request.actor),
                None,
            ))
            .await?;
    }
    bump_async(async_db, session_id).await?;
    session_detail_from_async_daemon_db(session_id, async_db).await
}

/// Leader arbitration verdict (async path).
///
/// # Errors
/// Returns `CliError` on state or db failure.
pub(crate) async fn arbitrate_async(
    session_id: &str,
    task_id: &str,
    request: &TaskArbitrateRequest,
    async_db: &super::db::AsyncDaemonDb,
) -> Result<SessionDetail, CliError> {
    let now = utc_now();
    let (prev_status, new_status) = async_db
        .update_session_state_immediate(session_id, |state| {
            let prev_status = state.tasks.get(task_id).map(|task| task.status);
            state.state_version += 1;
            apply_arbitrate(
                state,
                task_id,
                &request.actor,
                request.verdict,
                &request.summary,
                &now,
            )?;
            let new_status = state.tasks.get(task_id).map(|task| task.status);
            Ok((prev_status, new_status))
        })
        .await?;
    sync_file_state_from_async_db(async_db, session_id).await?;
    if let (Some(prev), Some(new)) = (prev_status, new_status)
        && prev != new
    {
        async_db
            .append_log_entry(&build_log_entry(
                session_id,
                session_service::log_task_status_changed(task_id, prev, new),
                Some(&request.actor),
                None,
            ))
            .await?;
    }
    bump_async(async_db, session_id).await?;
    session_detail_from_async_daemon_db(session_id, async_db).await
}
