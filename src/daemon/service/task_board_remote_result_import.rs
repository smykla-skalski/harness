use std::path::Path;

use tokio::task::spawn_blocking;

use crate::daemon::db::{
    AsyncDaemonDb, TaskBoardRemoteResultImportRecord, TaskBoardRemoteResultImportRequest,
    TaskBoardRemoteResultImportState, db_error,
};
use crate::errors::{CliError, CliErrorKind};
use crate::git::bundle::{GitBundleImportEvidence, GitBundleImportPlan, GitBundleWorktreeState};
use crate::git::{GitError, GitResult};
use crate::task_board::TaskBoardWorkflowExecutionCas;

#[path = "task_board_remote_result_import/orchestration.rs"]
mod orchestration;
pub(crate) use orchestration::import_and_adopt_task_board_remote_implementation_result;

pub(crate) async fn import_task_board_remote_implementation_result(
    db: &AsyncDaemonDb,
    expected: &TaskBoardWorkflowExecutionCas,
    request: &TaskBoardRemoteResultImportRequest,
) -> Result<TaskBoardRemoteResultImportRecord, CliError> {
    let existing = db
        .task_board_remote_result_import(&request.assignment_id, request.fencing_epoch)
        .await?;
    if let Some(existing) = existing.as_ref() {
        require_record_matches_request(existing, request)?;
        match existing.state {
            TaskBoardRemoteResultImportState::Adopted => return Ok(existing.clone()),
            TaskBoardRemoteResultImportState::ManualRequired => {
                return Err(CliErrorKind::concurrent_modification(
                    "remote result import requires manual recovery",
                )
                .into());
            }
            TaskBoardRemoteResultImportState::Prepared
            | TaskBoardRemoteResultImportState::Applied => {}
        }
    }
    let plan = match plan_from_request(request) {
        Ok(plan) => plan,
        Err(error) => match existing.as_ref() {
            Some(record) if manual_git_failure(&error) => {
                return mark_or_retry(db, request, record, error).await;
            }
            _ => return Err(git_error(error)),
        },
    };
    let plan_evidence = match plan.evidence() {
        Ok(evidence) => evidence,
        Err(error) => match existing.as_ref() {
            Some(record) if manual_git_failure(&error) => {
                return mark_or_retry(db, request, record, error).await;
            }
            _ => return Err(git_error(error)),
        },
    };
    if let Err(error) = require_plan_matches_request(&plan_evidence, request) {
        match existing.as_ref() {
            Some(record) => return mark_or_retry(db, request, record, error).await,
            None => return Err(git_error(error)),
        }
    }
    let work = match db
        .prepare_task_board_remote_result_import(expected, request)
        .await
    {
        Ok(work) => work,
        Err(error) if error.code() == "WORKFLOW_CONCURRENT" => {
            if let Some(record) = existing.as_ref() {
                return mark_verification_failure(db, request, record, error).await;
            }
            return Err(error);
        }
        Err(error) => return Err(error),
    };
    if work.record.state == TaskBoardRemoteResultImportState::Adopted {
        return Ok(work.record);
    }
    if work.record.state == TaskBoardRemoteResultImportState::Applied {
        return verify_applied_import(db, request, &work.record, plan).await;
    }
    if work.record.state != TaskBoardRemoteResultImportState::Prepared {
        return Err(CliErrorKind::concurrent_modification(
            "remote result import requires manual recovery",
        )
        .into());
    }
    let import_sha256 = work.record.import_sha256.clone();
    let bundle = work.bundle;
    let apply_plan = plan.clone();
    let applied = spawn_blocking(move || apply_bundle(apply_plan, &bundle))
        .await
        .map_err(|error| {
            CliErrorKind::workflow_io(format!("remote result import worker failed: {error}"))
        })?;
    let git = match applied {
        Ok(git) => git,
        Err(error) => {
            return settle_git_failure(db, request, &work.record, plan, error).await;
        }
    };
    let applied_at = crate::workspace::utc_now();
    db.record_task_board_remote_result_import_applied(
        &request.assignment_id,
        request.fencing_epoch,
        &import_sha256,
        &git,
        &applied_at,
    )
    .await
}

pub(crate) async fn cleanup_task_board_remote_result_import(
    db: &AsyncDaemonDb,
    assignment_id: &str,
    fencing_epoch: u64,
) -> Result<(), CliError> {
    let record = db
        .task_board_remote_result_import(assignment_id, fencing_epoch)
        .await?
        .ok_or_else(|| {
            CliError::from(CliErrorKind::concurrent_modification(
                "remote result import journal disappeared before cleanup",
            ))
        })?;
    if record.state != TaskBoardRemoteResultImportState::Adopted {
        return Err(CliErrorKind::concurrent_modification(
            "remote result import ref cleanup requires adopted evidence",
        )
        .into());
    }
    let plan = plan_from_request(&record.request()).map_err(git_error)?;
    let evidence = plan.evidence().map_err(git_error)?;
    require_plan_matches_request(&evidence, &record.request()).map_err(git_error)?;
    spawn_blocking(move || plan.cleanup_import_ref().map_err(git_error))
        .await
        .map_err(|error| {
            CliErrorKind::workflow_io(format!("remote import ref cleanup worker failed: {error}"))
        })?
}

fn apply_bundle(plan: GitBundleImportPlan, bundle: &[u8]) -> GitResult<GitBundleImportEvidence> {
    plan.verify_and_import_bytes(bundle)?;
    for _ in 0..3 {
        if plan.state()? == GitBundleWorktreeState::AttachedResult {
            return plan.require_applied();
        }
        plan.advance_one()?;
    }
    plan.require_applied()
}

async fn verify_applied_import(
    db: &AsyncDaemonDb,
    request: &TaskBoardRemoteResultImportRequest,
    record: &TaskBoardRemoteResultImportRecord,
    plan: GitBundleImportPlan,
) -> Result<TaskBoardRemoteResultImportRecord, CliError> {
    let proof = spawn_blocking(move || plan.require_applied())
        .await
        .map_err(|error| {
            CliErrorKind::workflow_io(format!("remote result proof worker failed: {error}"))
        })?;
    match proof {
        Ok(git) => {
            db.record_task_board_remote_result_import_applied(
                &request.assignment_id,
                request.fencing_epoch,
                &record.import_sha256,
                &git,
                record
                    .applied_at
                    .as_deref()
                    .ok_or_else(|| db_error("applied result import has no timestamp"))?,
            )
            .await
        }
        Err(error) => mark_or_retry(db, request, record, error).await,
    }
}

async fn settle_git_failure(
    db: &AsyncDaemonDb,
    request: &TaskBoardRemoteResultImportRequest,
    record: &TaskBoardRemoteResultImportRecord,
    plan: GitBundleImportPlan,
    error: GitError,
) -> Result<TaskBoardRemoteResultImportRecord, CliError> {
    if matches!(&error, GitError::Mutation { .. }) {
        let proof = spawn_blocking(move || match plan.state()? {
            GitBundleWorktreeState::AttachedResult => plan.require_applied().map(Some),
            _ => Ok(None),
        })
        .await
        .map_err(|join| {
            CliErrorKind::workflow_io(format!("remote result recovery worker failed: {join}"))
        })?;
        match proof {
            Ok(Some(git)) => {
                return db
                    .record_task_board_remote_result_import_applied(
                        &request.assignment_id,
                        request.fencing_epoch,
                        &record.import_sha256,
                        &git,
                        &crate::workspace::utc_now(),
                    )
                    .await;
            }
            Ok(None) => return Err(git_error(error)),
            Err(proof_error) => return mark_or_retry(db, request, record, proof_error).await,
        }
    }
    mark_or_retry(db, request, record, error).await
}

async fn mark_or_retry(
    db: &AsyncDaemonDb,
    request: &TaskBoardRemoteResultImportRequest,
    record: &TaskBoardRemoteResultImportRecord,
    error: GitError,
) -> Result<TaskBoardRemoteResultImportRecord, CliError> {
    if !manual_git_failure(&error) {
        return Err(git_error(error));
    }
    let detail = error.to_string();
    db.mark_task_board_remote_result_import_manual_required(
        &request.assignment_id,
        request.fencing_epoch,
        &record.import_sha256,
        &detail,
        &crate::workspace::utc_now(),
    )
    .await?;
    Err(CliErrorKind::concurrent_modification(format!(
        "remote result import requires human review: {detail}"
    ))
    .into())
}

async fn mark_verification_failure(
    db: &AsyncDaemonDb,
    request: &TaskBoardRemoteResultImportRequest,
    record: &TaskBoardRemoteResultImportRecord,
    error: CliError,
) -> Result<TaskBoardRemoteResultImportRecord, CliError> {
    let detail = error.to_string();
    db.mark_task_board_remote_result_import_manual_required(
        &request.assignment_id,
        request.fencing_epoch,
        &record.import_sha256,
        &detail,
        &crate::workspace::utc_now(),
    )
    .await?;
    Err(CliErrorKind::concurrent_modification(format!(
        "remote result import requires human review: {detail}"
    ))
    .into())
}

fn plan_from_request(
    request: &TaskBoardRemoteResultImportRequest,
) -> GitResult<GitBundleImportPlan> {
    GitBundleImportPlan::new(
        Path::new(&request.worktree_path),
        request.branch_ref.clone(),
        request.base_revision.clone(),
        request.result_revision.clone(),
        request.advertised_ref.clone(),
        request.import_ref.clone(),
    )
}

fn manual_git_failure(error: &GitError) -> bool {
    matches!(
        error,
        GitError::Discover { .. } | GitError::Open { .. } | GitError::Unsafe { .. }
    )
}

fn require_plan_matches_request(
    git: &GitBundleImportEvidence,
    request: &TaskBoardRemoteResultImportRequest,
) -> GitResult<()> {
    let exact = git.worktree_path == request.worktree_path
        && git.git_dir == request.git_dir
        && git.common_git_dir == request.common_git_dir
        && git.branch_ref == request.branch_ref
        && git.base_revision == request.base_revision
        && git.result_revision == request.result_revision
        && git.advertised_ref == request.advertised_ref
        && git.import_ref == request.import_ref
        && git.object_format == request.object_format;
    if exact {
        Ok(())
    } else {
        Err(GitError::unsafe_state(
            Path::new(&request.worktree_path),
            "remote result import request differs from its exact Git worktree",
        ))
    }
}

fn require_record_matches_request(
    record: &TaskBoardRemoteResultImportRecord,
    request: &TaskBoardRemoteResultImportRequest,
) -> Result<(), CliError> {
    let exact = record.assignment_id == request.assignment_id
        && record.fencing_epoch == request.fencing_epoch
        && record.worktree_path == request.worktree_path
        && record.git_dir == request.git_dir
        && record.common_git_dir == request.common_git_dir
        && record.branch_ref == request.branch_ref
        && record.base_revision == request.base_revision
        && record.result_revision == request.result_revision
        && record.advertised_ref == request.advertised_ref
        && record.import_ref == request.import_ref
        && record.object_format == request.object_format;
    if exact {
        Ok(())
    } else {
        Err(CliErrorKind::concurrent_modification(
            "remote result import replay changed its frozen Git coordinates",
        )
        .into())
    }
}

fn git_error(error: crate::git::GitError) -> CliError {
    CliErrorKind::workflow_io(error.to_string()).into()
}

#[cfg(test)]
#[path = "task_board_remote_result_import/classification_tests.rs"]
mod classification_tests;
