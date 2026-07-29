use serde::{Deserialize, Serialize};
use uuid::Uuid;

use super::admission::{TaskBoardDispatchAdmissionSnapshot, evaluate_dispatch_admission_in_tx};
use super::admission_reservations::persist_admission_snapshot_in_tx;
use super::dispatch_admission_queries::DispatchAdmissionQueries;
use super::dispatch_preparation_claim::TaskBoardPreparationClaim;
use super::dispatch_workflow_launch::rebind_write_launch;
use super::item_tx_ext::TaskBoardItemTxExt;
use crate::daemon::db::policy::consume_approval_grant_in_tx;
use crate::daemon::db::{AsyncDaemonDb, CliError, db_error};
use crate::infra::io;
use crate::task_board::{
    DispatchAppliedTask, DispatchPlan, SessionIntent, TaskBoardItem,
    TaskBoardReadOnlyWorkflowLaunch, TaskBoardWorkflowKind, TaskBoardWriteWorkflowLaunch,
};

const PREPARATION_LEASE_SECONDS: i64 = 30;

#[path = "dispatch_preparations_helpers.rs"]
mod helpers;
use helpers::{
    active_reservation, insert_preparation, stamp_admitting_execution_in_tx,
    validate_reservable_item,
};

pub(crate) use helpers::PREPARATION_MAX_ATTEMPTS as TASK_BOARD_PREPARATION_MAX_ATTEMPTS;

/// What a release did with the preparation it was handed.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum TaskBoardPreparationRelease {
    /// Queued for another attempt once the wait elapses.
    Retrying { delay_seconds: i64 },
    /// Retired after spending its budget; the item is dispatchable again.
    GaveUp { attempts: i64 },
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub(crate) struct TaskBoardDispatchPreparation {
    pub(crate) board_item_id: String,
    pub(crate) session_id: String,
    pub(crate) work_item_id: String,
    pub(crate) workflow_execution_id: String,
    pub(crate) actor: String,
    pub(crate) project_dir: Option<String>,
    pub(crate) plan: DispatchPlan,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub(crate) source_item_revision: Option<i64>,
    #[serde(default)]
    pub(crate) hold_worker: bool,
}

#[derive(Debug, Clone)]
pub(crate) struct ClaimedTaskBoardDispatchPreparation {
    pub(crate) intent_id: String,
    pub(crate) claim_token: String,
    pub(crate) preparation: TaskBoardDispatchPreparation,
}

#[derive(Debug)]
pub(crate) enum ReservedTaskBoardDispatch {
    Preparing {
        intent_id: String,
        preparation: Box<TaskBoardDispatchPreparation>,
    },
    Applied(Box<DispatchAppliedTask>),
    Blocked(Box<TaskBoardDispatchAdmissionSnapshot>),
}

fn preparation_revision_error(
    preparation: &TaskBoardDispatchPreparation,
    item: &TaskBoardItem,
    item_revision: i64,
) -> Option<&'static str> {
    if preparation
        .source_item_revision
        .is_some_and(|expected| expected != item_revision)
    {
        Some("workflow item revision changed before preparation claim")
    } else if preparation.source_item_revision.is_none()
        && !matches!(item.workflow_kind, TaskBoardWorkflowKind::Unknown)
    {
        Some("legacy workflow preparation has no frozen item revision")
    } else {
        None
    }
}

fn rebind_prepared_workflow_launches(
    item: &TaskBoardItem,
    prepared_item_revision: i64,
    workflow_execution_id: &str,
    read_only_workflow: &mut Option<TaskBoardReadOnlyWorkflowLaunch>,
    write_workflow: &mut Option<Box<TaskBoardWriteWorkflowLaunch>>,
) -> Result<(), CliError> {
    if let Some(launch) = read_only_workflow.as_mut() {
        launch.prepared_item_revision = prepared_item_revision;
    }
    if let Some(launch) = write_workflow.as_mut() {
        launch.prepared_item_revision = prepared_item_revision;
        let started_item_revision = prepared_item_revision
            .checked_add(1)
            .ok_or_else(|| db_error("workflow item revision is out of range"))?;
        rebind_write_launch(item, launch, workflow_execution_id, started_item_revision)?;
    }
    Ok(())
}

async fn consume_prepared_approval_grant(
    transaction: &mut sqlx::Transaction<'_, sqlx::Sqlite>,
    preparation: &TaskBoardDispatchPreparation,
) -> Result<(), CliError> {
    if !preparation.hold_worker
        && let Some(grant_id) = preparation.plan.consumed_approval_grant_id.as_deref()
    {
        let consumed = consume_approval_grant_in_tx(transaction.as_mut(), grant_id).await?;
        if !consumed {
            return Err(db_error(format!(
                "approval grant already consumed; rebuild plan (grant '{grant_id}')"
            )));
        }
    }
    Ok(())
}

impl AsyncDaemonDb {
    /// Reserve one dispatch before creating its session or task side effects.
    pub(crate) async fn reserve_task_board_dispatch(
        &self,
        plan: &DispatchPlan,
        actor: &str,
        project_dir: Option<&str>,
        hold_worker: bool,
    ) -> Result<ReservedTaskBoardDispatch, CliError> {
        <Self as DispatchAdmissionQueries>::reserve_task_board_dispatch(
            self,
            plan,
            actor,
            project_dir,
            hold_worker,
        )
        .await
    }

    /// Claims a preparation, or reports why it could not be claimed.
    pub(crate) async fn attempt_task_board_dispatch_preparation_claim(
        &self,
        intent_id: &str,
    ) -> Result<TaskBoardPreparationClaim, CliError> {
        <Self as DispatchAdmissionQueries>::attempt_task_board_dispatch_preparation_claim(
            self, intent_id,
        )
        .await
    }

    /// For callers that only act on the claim itself. Anything reported to a
    /// person should take the reason from the attempt above instead.
    pub(crate) async fn claim_task_board_dispatch_preparation(
        &self,
        intent_id: &str,
    ) -> Result<Option<ClaimedTaskBoardDispatchPreparation>, CliError> {
        <Self as DispatchAdmissionQueries>::claim_task_board_dispatch_preparation(self, intent_id)
            .await
    }

    pub(crate) async fn claim_next_task_board_dispatch_preparation(
        &self,
    ) -> Result<Option<ClaimedTaskBoardDispatchPreparation>, CliError> {
        <Self as DispatchAdmissionQueries>::claim_next_task_board_dispatch_preparation(self).await
    }

    /// Renew a claimed preparation while its session or worktree is being created.
    pub(crate) async fn renew_task_board_dispatch_preparation(
        &self,
        claim: &ClaimedTaskBoardDispatchPreparation,
    ) -> Result<(), CliError> {
        <Self as DispatchAdmissionQueries>::renew_task_board_dispatch_preparation(self, claim).await
    }

    pub(crate) async fn complete_task_board_dispatch_preparation(
        &self,
        claim: &ClaimedTaskBoardDispatchPreparation,
        branch: &str,
        worktree: &str,
    ) -> Result<DispatchAppliedTask, CliError> {
        <Self as DispatchAdmissionQueries>::complete_task_board_dispatch_preparation(
            self, claim, branch, worktree,
        )
        .await
    }

    /// Atomically link a prepared session task and expose it for worker startup.
    pub(crate) async fn complete_task_board_dispatch_preparation_with_workflow(
        &self,
        claim: &ClaimedTaskBoardDispatchPreparation,
        branch: &str,
        worktree: &str,
        read_only_workflow: Option<TaskBoardReadOnlyWorkflowLaunch>,
        write_workflow: Option<Box<TaskBoardWriteWorkflowLaunch>>,
    ) -> Result<DispatchAppliedTask, CliError> {
        <Self as DispatchAdmissionQueries>::complete_task_board_dispatch_preparation_with_workflow(
            self,
            claim,
            branch,
            worktree,
            read_only_workflow,
            write_workflow,
        )
        .await
    }

    /// Hands a failed preparation back to the queue, or retires it once its
    /// retry budget is spent so the item stops being held by a dispatch that
    /// cannot finish.
    pub(crate) async fn release_task_board_dispatch_preparation(
        &self,
        claim: &ClaimedTaskBoardDispatchPreparation,
        reason: &str,
    ) -> Result<TaskBoardPreparationRelease, CliError> {
        <Self as DispatchAdmissionQueries>::release_task_board_dispatch_preparation(
            self, claim, reason,
        )
        .await
    }
}

/// Real implementations behind the matching [`DispatchAdmissionQueries`]
/// methods, called from the single consolidated trait impl in
/// `dispatch_admission_queries.rs` (a trait's methods can only be implemented
/// in one `impl` block per type, so the per-area files hand it plain
/// functions instead of each declaring their own `impl DispatchAdmissionQueries
/// for AsyncDaemonDb`).
#[expect(
    clippy::cognitive_complexity,
    reason = "dispatch reservation must validate and insert under one transaction"
)]
pub(super) async fn reserve_task_board_dispatch(
    db: &AsyncDaemonDb,
    plan: &DispatchPlan,
    actor: &str,
    project_dir: Option<&str>,
    hold_worker: bool,
) -> Result<ReservedTaskBoardDispatch, CliError> {
    io::validate_safe_segment(&plan.board_item_id)?;
    let mut transaction = db
        .begin_immediate_transaction("task board dispatch reservation")
        .await?;
    if let Some(reserved) = active_reservation(&mut transaction, &plan.board_item_id).await? {
        transaction.commit().await.map_err(|error| {
            db_error(format!("commit existing task board reservation: {error}"))
        })?;
        return Ok(reserved);
    }
    let (item, item_revision) = transaction
        .load_item_in_tx(&plan.board_item_id)
        .await?
        .ok_or_else(|| {
            db_error(format!(
                "task-board item '{}' not found",
                plan.board_item_id
            ))
        })?;
    validate_reservable_item(&item, plan)?;
    let mut admission =
        evaluate_dispatch_admission_in_tx(&mut transaction, &item, item_revision, None).await?;
    if admission.as_ref().is_some_and(|value| !value.is_allowed()) {
        let mut admission = admission.take().expect("checked task board admission");
        persist_admission_snapshot_in_tx(&mut transaction, &plan.board_item_id, None, &mut admission)
            .await?;
        transaction.commit().await.map_err(|error| {
            db_error(format!("commit refused task board admission: {error}"))
        })?;
        return Ok(ReservedTaskBoardDispatch::Blocked(Box::new(admission)));
    }
    let intent_id = format!("dispatch-intent-{}", Uuid::new_v4().simple());
    let workflow_execution_id = format!("workflow-{}", Uuid::new_v4().simple());
    let session_id = match &plan.session {
        SessionIntent::Existing { session_id } => session_id.clone(),
        SessionIntent::Create { .. } => Uuid::new_v4().to_string(),
    };
    let workflow_kind = item.workflow_kind;
    // Stamp the owning execution onto the ticket in the same transaction that
    // reserves the intent, so the admit window stops being a blind spot: the
    // ticket exposes exactly one execution and a repeated admission is a
    // visible no-op rather than a second competing run. The ticket stays in
    // Todo and at the same revision; only its workflow content moves to
    // Admitting, so the claim guard and launch bindings are unaffected.
    stamp_admitting_execution_in_tx(&mut transaction, item, item_revision, &workflow_execution_id)
        .await?;
    let preparation = TaskBoardDispatchPreparation {
        board_item_id: plan.board_item_id.clone(),
        session_id,
        work_item_id: format!("task-board-{}", Uuid::new_v4().simple()),
        workflow_execution_id,
        actor: actor.to_string(),
        project_dir: project_dir.map(ToString::to_string),
        plan: plan.clone(),
        source_item_revision: (!matches!(workflow_kind, TaskBoardWorkflowKind::Unknown))
            .then_some(item_revision),
        hold_worker,
    };
    insert_preparation(&mut transaction, &intent_id, &preparation).await?;
    if let Some(mut admission) = admission {
        persist_admission_snapshot_in_tx(
            &mut transaction,
            &plan.board_item_id,
            Some(&intent_id),
            &mut admission,
        )
        .await?;
    }
    transaction
        .commit()
        .await
        .map_err(|error| db_error(format!("commit task board dispatch reservation: {error}")))?;
    Ok(ReservedTaskBoardDispatch::Preparing {
        intent_id,
        preparation: Box::new(preparation),
    })
}


// The remaining `DispatchAdmissionQueries` real implementations live in
// `queries` (split into its own file to keep this one under the repo's line
// budget); they stay part of the `dispatch_preparations` module.
#[path = "dispatch_preparations_queries.rs"]
pub(in crate::daemon::db::task_board) mod queries;
