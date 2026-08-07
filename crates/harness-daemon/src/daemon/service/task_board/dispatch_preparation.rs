use std::path::PathBuf;
use std::time::Duration;

use futures_util::FutureExt;
use tokio::task::{JoinError, spawn_blocking};
use tokio::time::sleep;

use crate::daemon::db::prelude::*;
use crate::daemon::db::task_board::prelude::*;
use crate::daemon::db::{
    ClaimedTaskBoardDispatchPreparation, ReservedTaskBoardDispatch, TaskBoardPreparationClaim,
    TaskBoardPreparationUnavailable,
};
use crate::daemon::db_handle::AsyncDaemonDbHandle;
use crate::daemon::protocol::{TaskBoardDispatchRequest, TaskCreateRequest};
use crate::daemon::service::create_task_with_id_async;
use crate::session::types::CONTROL_PLANE_ACTOR_ID;
use crate::task_board::{
    DispatchAppliedTask, DispatchFailureKind, DispatchPlan, SessionIntent,
    TaskBoardReadOnlyWorkflowLaunch, TaskBoardWriteWorkflowLaunch,
};
use harness_kernel::errors::{CliError, CliErrorKind};

const PREPARATION_HEARTBEAT_INTERVAL: Duration = Duration::from_secs(10);

pub(super) async fn reserve_and_prepare_task_board_dispatch(
    db: &AsyncDaemonDbHandle,
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
    let claim = match db
        .attempt_task_board_dispatch_preparation_claim(&intent_id)
        .await
        .map_err(|error| (DispatchFailureKind::LinkItem, error))?
    {
        TaskBoardPreparationClaim::Claimed(claim) => *claim,
        TaskBoardPreparationClaim::Unavailable(reason) => {
            return Err((
                DispatchFailureKind::LinkItem,
                CliError::from(CliErrorKind::workflow_io(unavailable_preparation_message(
                    &intent_id, &reason,
                ))),
            ));
        }
    };
    let result = Box::pin(prepare_claimed_task_board_dispatch(db, &claim)).await;
    if let Err((_, error)) = &result {
        let _ = db
            .release_task_board_dispatch_preparation(&claim, &error.to_string())
            .await;
    }
    result
}

/// Names what actually stopped the dispatch. Only a live claim is contention;
/// a preparation waiting out a backoff has a failure behind it, and reporting
/// all of these as "already in progress" hid that failure entirely.
fn unavailable_preparation_message(
    intent_id: &str,
    reason: &TaskBoardPreparationUnavailable,
) -> String {
    match reason {
        TaskBoardPreparationUnavailable::Missing => {
            format!("task-board dispatch preparation '{intent_id}' no longer exists")
        }
        TaskBoardPreparationUnavailable::HeldByWorker => {
            format!("task-board dispatch preparation '{intent_id}' is already in progress")
        }
        TaskBoardPreparationUnavailable::WaitingToRetry {
            seconds_remaining,
            last_error: Some(last_error),
        } => format!(
            "task-board dispatch preparation '{intent_id}' failed and retries in {seconds_remaining}s: {last_error}"
        ),
        TaskBoardPreparationUnavailable::WaitingToRetry {
            seconds_remaining, ..
        } => {
            format!("task-board dispatch preparation '{intent_id}' retries in {seconds_remaining}s")
        }
        TaskBoardPreparationUnavailable::Settled { status } => format!(
            "task-board dispatch preparation '{intent_id}' already left preparation with status '{status}'"
        ),
    }
}

pub(crate) async fn prepare_claimed_task_board_dispatch(
    db: &AsyncDaemonDbHandle,
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
    // The workspace id is only known once the checkout exists, so publication
    // reads it off a claim carrying what preparation just learned rather than
    // what reservation guessed.
    let mut claim = claim.clone();
    claim.preparation.workspace_id = checkout.workspace_id;
    db.complete_task_board_dispatch_preparation_with_workflow(
        &claim,
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
    workspace_id: Option<String>,
    read_only_workflow: Option<TaskBoardReadOnlyWorkflowLaunch>,
    write_workflow: Option<Box<TaskBoardWriteWorkflowLaunch>>,
}

async fn prepare_dispatch_side_effects(
    db: &AsyncDaemonDbHandle,
    claim: &ClaimedTaskBoardDispatchPreparation,
) -> Result<DispatchCheckout, (DispatchFailureKind, CliError)> {
    let owner = prepare_dispatch_owner(db, claim).await?;
    let read_only_workflow = super::read_only_workflow_launch::prepare_read_only_workflow_launch(
        db,
        &claim.preparation.board_item_id,
        &owner.launch_owner_id,
        &owner.worktree,
        claim.preparation.source_item_revision,
    )
    .boxed()
    .await
    .map_err(|error| (DispatchFailureKind::LinkItem, error))?;
    let write_workflow = super::write_workflow_launch::prepare_write_workflow_launch(
        db,
        &claim.preparation.board_item_id,
        &owner.launch_owner_id,
        &claim.preparation.work_item_id,
        &claim.preparation.workflow_execution_id,
        &owner.worktree,
        claim.preparation.source_item_revision,
    )
    .boxed()
    .await
    .map_err(|error| (DispatchFailureKind::LinkItem, error))?;
    Ok(DispatchCheckout {
        branch: owner.branch,
        worktree: owner.worktree,
        workspace_id: owner.workspace_id,
        read_only_workflow,
        write_workflow,
    })
}

/// The checkout this dispatch will run in, and who owns it.
struct DispatchOwner {
    branch: String,
    worktree: String,
    workspace_id: Option<String>,
    /// Correlation id the workflow launch records against. A legacy dispatch
    /// keeps naming its Session; a fresh one names its workspace, which is the
    /// owner that actually exists for it.
    launch_owner_id: String,
}

/// Give the dispatch a checkout to run in.
///
/// A board item already linked to a Session keeps using it, so work started
/// before workspaces existed stays dispatchable. Everything else provisions a
/// durable workspace and a checkout of its own, and creates no Session row and
/// no Session task on the way.
async fn prepare_dispatch_owner(
    db: &AsyncDaemonDbHandle,
    claim: &ClaimedTaskBoardDispatchPreparation,
) -> Result<DispatchOwner, (DispatchFailureKind, CliError)> {
    if let Some(session_id) = claim.preparation.session_id.clone() {
        return prepare_legacy_session_owner(db, claim, session_id).await;
    }
    workspace_owner::prepare_workspace_owner(db, claim).await
}

async fn prepare_legacy_session_owner(
    db: &AsyncDaemonDbHandle,
    claim: &ClaimedTaskBoardDispatchPreparation,
    session_id: String,
) -> Result<DispatchOwner, (DispatchFailureKind, CliError)> {
    ensure_dispatch_task(db, claim, &session_id)
        .await
        .map_err(|error| (DispatchFailureKind::CreateTask, error))?;
    let resolved = db
        .resolve_session(&session_id)
        .await
        .map_err(|error| (DispatchFailureKind::CreateSession, error))?
        .ok_or_else(|| {
            (
                DispatchFailureKind::CreateSession,
                CliError::from(CliErrorKind::session_not_active(format!(
                    "dispatch session '{session_id}' no longer exists"
                ))),
            )
        })?;
    let worktree = canonical_dispatch_worktree(resolved.state.worktree_path.clone())
        .await
        .map_err(|error| (DispatchFailureKind::CreateSession, error))?;
    Ok(DispatchOwner {
        branch: resolved.state.branch_ref,
        worktree,
        workspace_id: None,
        launch_owner_id: session_id,
    })
}

async fn canonical_dispatch_worktree(worktree: PathBuf) -> Result<String, CliError> {
    spawn_blocking(move || worktree.canonicalize())
        .await
        .map_err(|error| {
            CliErrorKind::workflow_io(format!("join dispatch worktree resolver: {error}"))
        })?
        .map(|path| path.to_string_lossy().into_owned())
        .map_err(|error| {
            CliErrorKind::workflow_io(format!("resolve dispatch worktree: {error}")).into()
        })
}

async fn maintain_preparation_claim(
    db: AsyncDaemonDbHandle,
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

/// Create the Session task a legacy dispatch's worker reports progress into.
///
/// Only reached for a board item already linked to a Session. A fresh dispatch
/// has no Session to hang a task off and does not create one - the board item
/// and its execution are the work record now.
async fn ensure_dispatch_task(
    db: &AsyncDaemonDbHandle,
    claim: &ClaimedTaskBoardDispatchPreparation,
    session_id: &str,
) -> Result<(), CliError> {
    let preparation = &claim.preparation;
    let task = &preparation.plan.task;
    create_task_with_id_async(
        session_id,
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
            "task-board dispatch requires project_dir when a working copy must be created",
        )
        .into()
    })
}

#[path = "dispatch_preparation_workspace_owner.rs"]
mod workspace_owner;

#[cfg(test)]
mod tests {
    use super::{TaskBoardPreparationUnavailable, unavailable_preparation_message};

    const INTENT: &str = "dispatch-intent-8024d942";

    #[test]
    fn a_retrying_preparation_reports_its_failure_not_contention() {
        let message = unavailable_preparation_message(
            INTENT,
            &TaskBoardPreparationUnavailable::WaitingToRetry {
                seconds_remaining: 16,
                last_error: Some("worktree is unreadable".to_string()),
            },
        );

        assert!(
            message.contains("worktree is unreadable") && message.contains("16s"),
            "the wait and the failure behind it both have to reach the operator, got {message}"
        );
        assert!(
            !message.contains("in progress"),
            "a preparation nobody holds must not read as contention, got {message}"
        );
    }

    #[test]
    fn each_unavailable_reason_reads_differently() {
        let messages = [
            TaskBoardPreparationUnavailable::Missing,
            TaskBoardPreparationUnavailable::HeldByWorker,
            TaskBoardPreparationUnavailable::WaitingToRetry {
                seconds_remaining: 4,
                last_error: None,
            },
            TaskBoardPreparationUnavailable::Settled {
                status: "pending".to_string(),
            },
        ]
        .map(|reason| unavailable_preparation_message(INTENT, &reason));
        let distinct: std::collections::BTreeSet<&String> = messages.iter().collect();

        assert_eq!(
            distinct.len(),
            messages.len(),
            "every reason needs its own message or the operator cannot tell them apart, got {messages:?}"
        );
        assert!(
            messages.iter().all(|message| message.contains(INTENT)),
            "every message must name the intent it is about, got {messages:?}"
        );
    }
}
