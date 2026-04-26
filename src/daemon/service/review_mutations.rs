//! Daemon service facade for the Slice 3 review + improver workflow (sync path).
//!
//! Sync variants load + persist state through the file-backed Slice 2
//! facades and then bump the daemon change counter so subscribers pick
//! up the new session snapshot. Async variants live in `review_mutations_async`.

use std::path::PathBuf;

use crate::daemon::protocol::{
    SessionDetail, TaskArbitrateRequest, TaskClaimReviewRequest, TaskRespondReviewRequest,
    TaskSubmitForReviewRequest, TaskSubmitReviewRequest,
};
use crate::errors::CliError;
use crate::session::service::{
    arbitrate as svc_arbitrate, claim_review as svc_claim_review,
    respond_review as svc_respond_review,
    submit_for_review_with_persona as svc_submit_for_review_with_persona,
    submit_review as svc_submit_review,
};

use super::{
    effective_project_dir, index, project_dir_for_db_session, session_detail,
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

