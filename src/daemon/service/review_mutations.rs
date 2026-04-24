//! Daemon service facade for the Slice 3 review + improver workflow.
//!
//! Sync variants load + persist state through the file-backed Slice 2
//! facades and then bump the daemon change counter so subscribers pick
//! up the new session snapshot. Async variants apply the review state
//! mutation directly against the async daemon DB resolved state, then
//! save + bump. `improver_apply` is a filesystem-level operation and
//! does not touch session state.

use std::path::{Path, PathBuf};

use crate::daemon::index as daemon_index;
use crate::daemon::protocol::{
    ImproverApplyRequest, SessionDetail, TaskArbitrateRequest, TaskClaimReviewRequest,
    TaskRespondReviewRequest, TaskSubmitForReviewRequest, TaskSubmitReviewRequest,
};
use crate::errors::CliError;
use crate::session::service::{
    self as session_service, ImproverApplyOutcome, apply_arbitrate, apply_claim_review,
    apply_respond_review, apply_submit_for_review, apply_submit_review, arbitrate as svc_arbitrate,
    claim_review as svc_claim_review, generate_review_id, respond_review as svc_respond_review,
    submit_for_review as svc_submit_for_review, submit_review as svc_submit_review,
};
use crate::session::storage as session_storage;
use crate::session::types::{Review, TaskStatus};
use crate::workspace::utc_now;

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

fn bump_and_refresh(
    db: Option<&super::db::DaemonDb>,
    session_id: &str,
) -> Result<(), CliError> {
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
    svc_submit_for_review(
        session_id,
        task_id,
        &request.actor,
        request.summary.as_deref(),
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
    svc_submit_review(
        session_id,
        task_id,
        &request.actor,
        request.verdict,
        &request.summary,
        request.points.clone(),
        &project_dir,
    )?;
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
    _session_id: &str,
    request: &ImproverApplyRequest,
) -> Result<ImproverApplyOutcome, CliError> {
    let repo_root = Path::new(&request.project_dir);
    let rel = Path::new(&request.rel_path);
    let now = utc_now();
    if request.dry_run {
        let canonical = session_service::validate_skill_patch_path(repo_root, request.target, rel)?;
        return Ok(ImproverApplyOutcome {
            canonical_path: canonical,
            before_sha256: String::new(),
            after_sha256: String::new(),
            applied: false,
            backup_path: None,
            unified_diff: String::new(),
        });
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

async fn bump_async(
    async_db: &super::db::AsyncDaemonDb,
    session_id: &str,
) -> Result<(), CliError> {
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
    apply_submit_for_review(
        &mut resolved.state,
        task_id,
        &request.actor,
        request.summary.as_deref(),
        &now,
    )?;
    async_db
        .save_session_state(&resolved.project.project_id, &resolved.state)
        .await?;
    async_db
        .append_log_entry(&build_log_entry(
            session_id,
            session_service::log_task_status_changed(
                task_id,
                TaskStatus::InProgress,
                TaskStatus::AwaitingReview,
            ),
            Some(&request.actor),
            None,
        ))
        .await?;
    bump_async(async_db, session_id).await?;
    session_detail_from_async_daemon_db(session_id, async_db).await
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
    let mut resolved = resolve_async(async_db, session_id).await?;
    let now = utc_now();
    apply_claim_review(&mut resolved.state, task_id, &request.actor, &now)?;
    async_db
        .save_session_state(&resolved.project.project_id, &resolved.state)
        .await?;
    async_db
        .append_log_entry(&build_log_entry(
            session_id,
            session_service::log_task_status_changed(
                task_id,
                TaskStatus::AwaitingReview,
                TaskStatus::InReview,
            ),
            Some(&request.actor),
            None,
        ))
        .await?;
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
    let mut resolved = resolve_async(async_db, session_id).await?;
    let now = utc_now();
    let project_dir = resolved
        .project
        .project_dir
        .clone()
        .ok_or_else(|| session_not_found(session_id))?;
    let layout = session_storage::layout_from_project_dir(&project_dir, session_id)?;

    let round = resolved
        .state
        .tasks
        .get(task_id)
        .map_or(1, |task| task.review_round.saturating_add(1));
    let reviewer_runtime = resolved
        .state
        .agents
        .get(&request.actor)
        .map(|agent| agent.runtime.clone())
        .unwrap_or_default();
    let review = Review {
        review_id: generate_review_id(task_id),
        round,
        reviewer_agent_id: request.actor.clone(),
        reviewer_runtime,
        verdict: request.verdict,
        summary: request.summary.clone(),
        points: request.points.clone(),
        recorded_at: now.clone(),
    };
    session_storage::append_review(&layout, task_id, &review)?;
    let all_reviews = session_storage::load_reviews(&layout, task_id)?;

    let prev_status = resolved.state.tasks.get(task_id).map(|task| task.status);
    apply_submit_review(&mut resolved.state, task_id, &review, &all_reviews, &now)?;
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

