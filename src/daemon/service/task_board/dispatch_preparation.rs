use std::path::{Path, PathBuf};
use std::time::Duration;

use futures_util::FutureExt;
use tokio::task::{JoinError, spawn_blocking};
use tokio::time::sleep;

use crate::daemon::db::{
    AsyncDaemonDb, ClaimedTaskBoardDispatchPreparation, ReservedTaskBoardDispatch,
};
use crate::daemon::protocol::{SessionStartRequest, TaskBoardDispatchRequest, TaskCreateRequest};
use crate::daemon::service::{
    build_log_entry, create_task_with_id_async, ensure_project_registered_async, session_service,
    start_session_direct_async,
};
use crate::errors::{CliError, CliErrorKind};
use crate::session::storage as session_storage;
use crate::session::types::{CONTROL_PLANE_ACTOR_ID, SessionState};
use crate::task_board::{
    DispatchAppliedTask, DispatchFailureKind, DispatchPlan, SessionIntent,
    TaskBoardReadOnlyWorkflowLaunch, TaskBoardWriteWorkflowLaunch,
};
use crate::workspace::adopter::SessionAdopter;
use crate::workspace::layout::SessionLayout;
use crate::workspace::worktree::WorktreeController;

const PREPARATION_HEARTBEAT_INTERVAL: Duration = Duration::from_secs(10);

pub(super) async fn reserve_and_prepare_task_board_dispatch(
    db: &AsyncDaemonDb,
    request: &TaskBoardDispatchRequest,
    plan: &DispatchPlan,
    hold_worker: bool,
) -> Result<DispatchAppliedTask, (DispatchFailureKind, CliError)> {
    let project_dir = dispatch_project_dir(request, plan)
        .map_err(|error| (DispatchFailureKind::CreateSession, error))?;
    let actor = request.actor.as_deref().unwrap_or(CONTROL_PLANE_ACTOR_ID);
    let reserved = db
        .reserve_task_board_dispatch(plan, actor, project_dir.as_deref(), hold_worker)
        .await
        .map_err(|error| (DispatchFailureKind::LinkItem, error))?;
    let (intent_id, _) = match reserved {
        ReservedTaskBoardDispatch::Applied(applied) => return Ok(*applied),
        ReservedTaskBoardDispatch::Blocked(admission) => {
            return Err((
                DispatchFailureKind::LinkItem,
                CliError::from(CliErrorKind::invalid_transition(
                    admission.refusal_message(),
                )),
            ));
        }
        ReservedTaskBoardDispatch::Preparing {
            intent_id,
            preparation,
        } => (intent_id, preparation),
    };
    let claim = db
        .claim_task_board_dispatch_preparation(&intent_id)
        .await
        .map_err(|error| (DispatchFailureKind::LinkItem, error))?
        .ok_or_else(|| {
            (
                DispatchFailureKind::LinkItem,
                CliError::from(CliErrorKind::workflow_io(format!(
                    "task-board dispatch preparation '{intent_id}' is already in progress"
                ))),
            )
        })?;
    let result = prepare_claimed_task_board_dispatch(db, &claim).await;
    if let Err((_, error)) = &result {
        let _ = db
            .release_task_board_dispatch_preparation(&claim, &error.to_string())
            .await;
    }
    result
}

pub(crate) async fn prepare_claimed_task_board_dispatch(
    db: &AsyncDaemonDb,
    claim: &ClaimedTaskBoardDispatchPreparation,
) -> Result<DispatchAppliedTask, (DispatchFailureKind, CliError)> {
    let mut heartbeat = tokio::spawn(maintain_preparation_claim(db.clone(), claim.clone()));
    let preparation = prepare_dispatch_side_effects(db, claim);
    tokio::pin!(preparation);
    let prepared = tokio::select! {
        result = &mut preparation => {
            heartbeat.abort();
            let _ = heartbeat.await;
            result
        }
        result = &mut heartbeat => {
            return Err((DispatchFailureKind::LinkItem, heartbeat_error(result)));
        }
    };
    let checkout = prepared?;
    db.complete_task_board_dispatch_preparation_with_workflow(
        claim,
        &checkout.branch,
        &checkout.worktree,
        checkout.read_only_workflow,
        checkout.write_workflow,
    )
    .await
    .map_err(|error| (DispatchFailureKind::LinkItem, error))
}

struct DispatchCheckout {
    branch: String,
    worktree: String,
    read_only_workflow: Option<TaskBoardReadOnlyWorkflowLaunch>,
    write_workflow: Option<Box<TaskBoardWriteWorkflowLaunch>>,
}

async fn prepare_dispatch_side_effects(
    db: &AsyncDaemonDb,
    claim: &ClaimedTaskBoardDispatchPreparation,
) -> Result<DispatchCheckout, (DispatchFailureKind, CliError)> {
    ensure_dispatch_session(db, claim)
        .await
        .map_err(|error| (DispatchFailureKind::CreateSession, error))?;
    ensure_dispatch_task(db, claim)
        .await
        .map_err(|error| (DispatchFailureKind::CreateTask, error))?;
    let resolved = db
        .resolve_session(&claim.preparation.session_id)
        .await
        .map_err(|error| (DispatchFailureKind::CreateSession, error))?
        .ok_or_else(|| {
            (
                DispatchFailureKind::CreateSession,
                CliError::from(CliErrorKind::session_not_active(format!(
                    "dispatch session '{}' no longer exists",
                    claim.preparation.session_id
                ))),
            )
        })?;
    let worktree = resolved.state.worktree_path.to_string_lossy().into_owned();
    let read_only_workflow = super::read_only_workflow_launch::prepare_read_only_workflow_launch(
        db,
        &claim.preparation.board_item_id,
        &claim.preparation.session_id,
        &worktree,
        claim.preparation.source_item_revision,
    )
    .boxed()
    .await
    .map_err(|error| (DispatchFailureKind::LinkItem, error))?;
    let write_workflow = super::write_workflow_launch::prepare_write_workflow_launch(
        db,
        &claim.preparation.board_item_id,
        &claim.preparation.workflow_execution_id,
        &worktree,
        claim.preparation.source_item_revision,
    )
    .boxed()
    .await
    .map_err(|error| (DispatchFailureKind::LinkItem, error))?;
    Ok(DispatchCheckout {
        branch: resolved.state.branch_ref,
        worktree,
        read_only_workflow,
        write_workflow,
    })
}

async fn maintain_preparation_claim(
    db: AsyncDaemonDb,
    claim: ClaimedTaskBoardDispatchPreparation,
) -> Result<(), CliError> {
    loop {
        sleep(PREPARATION_HEARTBEAT_INTERVAL).await;
        db.renew_task_board_dispatch_preparation(&claim).await?;
    }
}

fn heartbeat_error(result: Result<Result<(), CliError>, JoinError>) -> CliError {
    match result {
        Ok(Err(error)) => error,
        Ok(Ok(())) => CliErrorKind::workflow_io(
            "task-board dispatch preparation heartbeat ended unexpectedly",
        )
        .into(),
        Err(error) => CliErrorKind::workflow_io(format!(
            "task-board dispatch preparation heartbeat worker failed: {error}"
        ))
        .into(),
    }
}

async fn ensure_dispatch_session(
    db: &AsyncDaemonDb,
    claim: &ClaimedTaskBoardDispatchPreparation,
) -> Result<(), CliError> {
    let preparation = &claim.preparation;
    if db.resolve_session(&preparation.session_id).await?.is_some() {
        return Ok(());
    }
    let SessionIntent::Create { title, context, .. } = &preparation.plan.session else {
        return Err(CliErrorKind::session_not_active(format!(
            "dispatch session '{}' no longer exists",
            preparation.session_id
        ))
        .into());
    };
    let project_dir = preparation.project_dir.clone().ok_or_else(|| {
        CliErrorKind::workflow_io("task-board dispatch preparation has no project_dir")
    })?;
    if recover_prepared_session(db, claim, title, context.as_deref(), &project_dir).await? {
        return Ok(());
    }
    start_session_direct_async(
        &SessionStartRequest {
            title: title.clone(),
            context: context.clone().unwrap_or_else(|| title.clone()),
            session_id: Some(preparation.session_id.clone()),
            project_dir,
            policy_preset: None,
            base_ref: None,
        },
        db,
    )
    .await?;
    Ok(())
}

async fn recover_prepared_session(
    db: &AsyncDaemonDb,
    claim: &ClaimedTaskBoardDispatchPreparation,
    title: &str,
    context: Option<&str>,
    project_dir: &str,
) -> Result<bool, CliError> {
    let preparation = &claim.preparation;
    let recovery = PreparedSessionRecoveryRequest {
        session_id: preparation.session_id.clone(),
        title: title.to_string(),
        context: context.unwrap_or(title).to_string(),
        project_dir: project_dir.to_string(),
    };
    let recovered = spawn_blocking(move || recover_session_artifacts(&recovery))
        .await
        .map_err(|error| {
            CliErrorKind::workflow_io(format!("join dispatch recovery worker: {error}"))
        })??;
    let Some(recovered) = recovered else {
        return Ok(false);
    };
    let project_id = ensure_project_registered_async(db, &recovered.origin).await?;
    db.create_session_record(&project_id, &recovered.state)
        .await?;
    db.append_log_entry(&build_log_entry(
        &recovered.state.session_id,
        session_service::log_session_started(title, context.unwrap_or(title)),
        None,
        None,
    ))
    .await?;
    db.bump_change(&recovered.state.session_id).await?;
    db.bump_change("global").await?;
    Ok(true)
}

struct PreparedSessionRecoveryRequest {
    session_id: String,
    title: String,
    context: String,
    project_dir: String,
}

struct RecoveredPreparedSession {
    origin: PathBuf,
    state: SessionState,
}

fn recover_session_artifacts(
    request: &PreparedSessionRecoveryRequest,
) -> Result<Option<RecoveredPreparedSession>, CliError> {
    let origin = Path::new(&request.project_dir)
        .canonicalize()
        .map_err(|error| {
            CliErrorKind::workflow_io(format!("resolve prepared dispatch project: {error}"))
        })?;
    let layout = session_storage::layout_from_project_dir(&origin, &request.session_id)?;
    if !layout.state_file().exists() {
        clear_incomplete_session_artifacts(&origin, &layout)?;
        return Ok(None);
    }
    let probed = SessionAdopter::probe(&layout.session_root()).map_err(CliError::from)?;
    let state = probed.state();
    if state.session_id != request.session_id
        || state.title != request.title
        || state.context != request.context
        || state.origin_path != origin
    {
        return Err(CliErrorKind::session_agent_conflict(format!(
            "prepared dispatch session '{}' does not match its durable reservation",
            request.session_id
        ))
        .into());
    }
    session_storage::register_active(&layout)?;
    Ok(Some(RecoveredPreparedSession {
        origin,
        state: state.clone(),
    }))
}

fn clear_incomplete_session_artifacts(
    origin: &Path,
    layout: &SessionLayout,
) -> Result<(), CliError> {
    if layout.workspace().exists() {
        WorktreeController::destroy(origin, layout).map_err(|error| {
            CliErrorKind::workflow_io(format!(
                "remove incomplete prepared dispatch session: {error}"
            ))
        })?;
    } else if layout.session_root().exists() {
        fs_err::remove_dir_all(layout.session_root()).map_err(|error| {
            CliErrorKind::workflow_io(format!(
                "remove incomplete prepared dispatch directory: {error}"
            ))
        })?;
    }
    Ok(())
}

async fn ensure_dispatch_task(
    db: &AsyncDaemonDb,
    claim: &ClaimedTaskBoardDispatchPreparation,
) -> Result<(), CliError> {
    let preparation = &claim.preparation;
    let task = &preparation.plan.task;
    create_task_with_id_async(
        &preparation.session_id,
        &preparation.work_item_id,
        &TaskCreateRequest {
            actor: preparation.actor.clone(),
            title: task.title.clone(),
            context: task.context.clone(),
            severity: task.severity,
            suggested_fix: task.suggested_fix.clone(),
        },
        db,
    )
    .await?;
    Ok(())
}

fn dispatch_project_dir(
    request: &TaskBoardDispatchRequest,
    plan: &DispatchPlan,
) -> Result<Option<String>, CliError> {
    if matches!(plan.session, SessionIntent::Existing { .. }) {
        return Ok(None);
    }
    request.project_dir.clone().map(Some).ok_or_else(|| {
        CliErrorKind::workflow_io(
            "task-board dispatch requires project_dir when a session must be created",
        )
        .into()
    })
}
