//! Daemon service facade for the Slice 3 review + improver workflow.
//!
//! Sync variants load + persist state through the file-backed Slice 2
//! facades and then bump the daemon change counter so subscribers pick
//! up the new session snapshot. Async variants apply the review state
//! mutation directly against the async daemon DB resolved state, then
//! save + bump. `improver_apply` is a filesystem-level operation and
//! does not touch session state.

use std::path::{Path, PathBuf};

use crate::agents::runtime::runtime_for_name;
use crate::daemon::index as daemon_index;
use crate::daemon::protocol::{
    ImproverApplyRequest, SessionDetail, TaskArbitrateRequest, TaskClaimReviewRequest,
    TaskRespondReviewRequest, TaskSubmitForReviewRequest, TaskSubmitReviewRequest,
};
use crate::errors::CliError;
use crate::session::roles::SessionAction;
use crate::session::service::{
    self as session_service, ImproverApplyOutcome, apply_arbitrate, apply_claim_review,
    apply_respond_review, apply_submit_for_review, arbitrate as svc_arbitrate,
    claim_review as svc_claim_review, maybe_emit_spawn_reviewer,
    respond_review as svc_respond_review,
    submit_for_review_with_persona as svc_submit_for_review_with_persona,
    submit_review as svc_submit_review, validate_submit_review,
};
use crate::session::storage as session_storage;
use crate::session::types::TaskStatus;
use crate::workspace::utc_now;

use super::review_submit_txn::apply_submit_review_in_txn;

use super::sessions::session_detail_from_async_daemon_db;
use super::{
    build_log_entry, effective_project_dir, index, project_dir_for_db_session, session_detail,
    session_not_found,
};

fn project_dir_from_db_or_index(
    db: Option<&super::db::DaemonDb>,
    session_id: &str,
) -> Result<PathBuf, CliError> {
    if let Some(db) = db {
        return project_dir_for_db_session(db, session_id);
    }
    let resolved = index::resolve_session(session_id)?;
    Ok(effective_project_dir(&resolved).to_path_buf())
}

fn bump_and_refresh(db: Option<&super::db::DaemonDb>, session_id: &str) -> Result<(), CliError> {
    if let Some(db) = db {
        db.load_session_state_for_mutation(session_id)?;
        db.bump_change(session_id)?;
        db.bump_change("global")?;
    }
    Ok(())
}

/// Submit a task for review (sync path).
///
/// # Errors
/// Returns `CliError` on state, storage, or db failure.
pub fn submit_for_review(
    session_id: &str,
    task_id: &str,
    request: &TaskSubmitForReviewRequest,
    db: Option<&super::db::DaemonDb>,
) -> Result<SessionDetail, CliError> {
    let project_dir = project_dir_from_db_or_index(db, session_id)?;
    svc_submit_for_review_with_persona(
        session_id,
        task_id,
        &request.actor,
        request.summary.as_deref(),
        request.suggested_persona.as_deref(),
        &project_dir,
    )?;
    bump_and_refresh(db, session_id)?;
    session_detail(session_id, db)
}

/// Claim a review slot (sync path).
///
/// # Errors
/// Returns `CliError` on state, storage, or db failure.
pub fn claim_review(
    session_id: &str,
    task_id: &str,
    request: &TaskClaimReviewRequest,
    db: Option<&super::db::DaemonDb>,
) -> Result<SessionDetail, CliError> {
    let project_dir = project_dir_from_db_or_index(db, session_id)?;
    svc_claim_review(session_id, task_id, &request.actor, &project_dir)?;
    bump_and_refresh(db, session_id)?;
    session_detail(session_id, db)
}

/// Submit a reviewer verdict (sync path).
///
/// # Errors
/// Returns `CliError` on state, storage, or db failure.
pub fn submit_review(
    session_id: &str,
    task_id: &str,
    request: &TaskSubmitReviewRequest,
    db: Option<&super::db::DaemonDb>,
) -> Result<SessionDetail, CliError> {
    let project_dir = project_dir_from_db_or_index(db, session_id)?;
    let review = svc_submit_review(
        session_id,
        task_id,
        &request.actor,
        request.verdict,
        &request.summary,
        request.points.clone(),
        &project_dir,
    )?;
    if let Some(db) = db {
        db.insert_task_review(session_id, task_id, &review)?;
    }
    bump_and_refresh(db, session_id)?;
    session_detail(session_id, db)
}

/// Worker response to reviewer feedback (sync path).
///
/// # Errors
/// Returns `CliError` on state, storage, or db failure.
pub fn respond_review(
    session_id: &str,
    task_id: &str,
    request: &TaskRespondReviewRequest,
    db: Option<&super::db::DaemonDb>,
) -> Result<SessionDetail, CliError> {
    let project_dir = project_dir_from_db_or_index(db, session_id)?;
    svc_respond_review(
        session_id,
        task_id,
        &request.actor,
        &request.agreed,
        &request.disputed,
        request.note.as_deref(),
        &project_dir,
    )?;
    bump_and_refresh(db, session_id)?;
    session_detail(session_id, db)
}

/// Leader arbitration verdict (sync path).
///
/// # Errors
/// Returns `CliError` on state, storage, or db failure.
pub fn arbitrate(
    session_id: &str,
    task_id: &str,
    request: &TaskArbitrateRequest,
    db: Option<&super::db::DaemonDb>,
) -> Result<SessionDetail, CliError> {
    let project_dir = project_dir_from_db_or_index(db, session_id)?;
    svc_arbitrate(
        session_id,
        task_id,
        &request.actor,
        request.verdict,
        &request.summary,
        &project_dir,
    )?;
    bump_and_refresh(db, session_id)?;
    session_detail(session_id, db)
}

/// Apply an improver patch to a canonical skill/plugin source.
///
/// Validates the target path, backs up the existing contents, writes
/// the new body atomically, and returns the outcome. On `dry_run` the
/// validation + diff still run but no files are modified.
///
/// # Errors
/// Returns `CliError` when the path is disallowed, the target is
/// missing, or the write fails.
pub fn improver_apply(
    session_id: &str,
    request: &ImproverApplyRequest,
) -> Result<ImproverApplyOutcome, CliError> {
    let resolved = index::resolve_session(session_id)?;
    session_service::require_permission(
        &resolved.state,
        &request.actor,
        SessionAction::ImproverApply,
    )?;
    let repo_root = effective_project_dir(&resolved);
    let rel = Path::new(&request.rel_path);
    let now = utc_now();
    if request.dry_run {
        return session_service::preview_improver_apply(
            repo_root,
            request.target,
            rel,
            &request.new_contents,
        );
    }
    session_service::apply_improver_apply(
        repo_root,
        request.target,
        rel,
        &request.new_contents,
        &request.issue_id,
        &now,
    )
}

// ============================================================================
// Async variants — apply state mutation against the resolved state in the
// async daemon DB, then persist + log + bump.
// ============================================================================

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
    let mut resolved = resolve_async(async_db, session_id).await?;
    let now = utc_now();
    apply_submit_for_review_to_resolved(&mut resolved, task_id, request, &now)?;
    async_db
        .save_session_state(&resolved.project.project_id, &resolved.state)
        .await?;
    append_submit_for_review_log(async_db, session_id, task_id, &request.actor).await?;
    maybe_materialize_spawn_reviewer_async(session_id, task_id, &resolved, &now, async_db).await?;
    bump_async(async_db, session_id).await?;
    session_detail_from_async_daemon_db(session_id, async_db).await
}

fn apply_submit_for_review_to_resolved(
    resolved: &mut daemon_index::ResolvedSession,
    task_id: &str,
    request: &TaskSubmitForReviewRequest,
    now: &str,
) -> Result<(), CliError> {
    apply_submit_for_review(
        &mut resolved.state,
        task_id,
        &request.actor,
        request.summary.as_deref(),
        now,
    )?;
    if let Some(persona) = request.suggested_persona.as_deref()
        && let Some(task) = resolved.state.tasks.get_mut(task_id)
    {
        task.suggested_persona = Some(persona.to_string());
    }
    Ok(())
}

async fn append_submit_for_review_log(
    async_db: &super::db::AsyncDaemonDb,
    session_id: &str,
    task_id: &str,
    actor_id: &str,
) -> Result<(), CliError> {
    async_db
        .append_log_entry(&build_log_entry(
            session_id,
            session_service::log_task_status_changed(
                task_id,
                TaskStatus::InProgress,
                TaskStatus::AwaitingReview,
            ),
            Some(actor_id),
            None,
        ))
        .await
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
            apply_claim_review(state, task_id, &request.actor, &now)?;
            let new_status = state.tasks.get(task_id).map(|task| task.status);
            Ok((prev_status, new_status))
        })
        .await?;
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
    let project_dir = resolved
        .project
        .project_dir
        .clone()
        .ok_or_else(|| session_not_found(session_id))?;
    let layout = session_storage::layout_from_project_dir(&project_dir, session_id)?;

    validate_submit_review(&resolved.state, task_id, &request.actor)?;
    let (prev_status, new_status, review) = async_db
        .update_session_state_immediate(session_id, |state| {
            apply_submit_review_in_txn(
                state, task_id, &request.actor, request.verdict,
                &request.summary, &request.points, &layout, &now,
            )
        })
        .await?;
    async_db
        .insert_task_review(session_id, task_id, &review)
        .await?;
    append_task_status_change_log(
        async_db, session_id, task_id, &request.actor, prev_status, new_status,
    )
    .await?;
    bump_async(async_db, session_id).await?;
    session_detail_from_async_daemon_db(session_id, async_db).await
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
    let mut resolved = resolve_async(async_db, session_id).await?;
    let now = utc_now();
    let prev_status = resolved.state.tasks.get(task_id).map(|task| task.status);
    apply_respond_review(
        &mut resolved.state,
        task_id,
        &request.actor,
        &request.agreed,
        &request.disputed,
        request.note.as_deref(),
        &now,
    )?;
    let new_status = resolved.state.tasks.get(task_id).map(|task| task.status);
    async_db
        .save_session_state(&resolved.project.project_id, &resolved.state)
        .await?;
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
    let mut resolved = resolve_async(async_db, session_id).await?;
    let now = utc_now();
    let prev_status = resolved.state.tasks.get(task_id).map(|task| task.status);
    apply_arbitrate(
        &mut resolved.state,
        task_id,
        &request.actor,
        request.verdict,
        &request.summary,
        &now,
    )?;
    let new_status = resolved.state.tasks.get(task_id).map(|task| task.status);
    async_db
        .save_session_state(&resolved.project.project_id, &resolved.state)
        .await?;
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
