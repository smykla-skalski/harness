use sqlx::{Sqlite, Transaction, query_as};

use super::admission_lifecycle::{TaskBoardAdmissionCheck, revalidate_dispatch_admission_in_tx};
use super::dispatch_intents::ensure_dispatch_item_startable;
use super::dispatch_intents::helpers::refuse_pending_admission_in_tx;
use super::items::load_item_in_tx;
use super::workflow_dispatch::{
    insert_started_read_only_workflow_in_tx, insert_started_write_workflow_in_tx,
};
use crate::daemon::db::{CliError, CliErrorKind, db_error};
use crate::task_board::{DispatchAppliedTask, TaskBoardItem};

pub(super) async fn load_claimed_applied(
    transaction: &mut Transaction<'_, Sqlite>,
    intent_id: &str,
    claim_token: &str,
) -> Result<DispatchAppliedTask, CliError> {
    let payload = query_as::<_, (String,)>(
        "SELECT payload_json FROM task_board_dispatch_intents
         WHERE intent_id = ?1 AND claim_token = ?2 AND status = 'starting'",
    )
    .bind(intent_id)
    .bind(claim_token)
    .fetch_one(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("load claimed workflow launch: {error}")))?
    .0;
    serde_json::from_str(&payload)
        .map_err(|error| db_error(format!("decode task board dispatch intent: {error}")))
}

pub(super) fn workflow_start_fence(
    applied: &DispatchAppliedTask,
) -> Result<Option<(i64, u64)>, CliError> {
    match (&applied.read_only_workflow, &applied.write_workflow) {
        (Some(_), Some(_)) => Err(db_error("dispatch carries conflicting workflow launches")),
        (Some(launch), None) => Ok(Some((
            launch.prepared_item_revision,
            launch.configuration_revision,
        ))),
        (None, Some(launch)) => Ok(Some((
            launch.prepared_item_revision,
            launch.configuration_revision,
        ))),
        (None, None) => Ok(None),
    }
}

pub(super) async fn insert_started_workflow_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    item: &TaskBoardItem,
    item_revision: i64,
    intent_id: &str,
    applied: &DispatchAppliedTask,
) -> Result<(), CliError> {
    match (&applied.read_only_workflow, &applied.write_workflow) {
        (Some(_), Some(_)) => Err(db_error("dispatch carries conflicting workflow launches")),
        (Some(launch), None) => {
            insert_started_read_only_workflow_in_tx(
                transaction,
                item,
                item_revision,
                intent_id,
                launch,
            )
            .await
        }
        (None, Some(launch)) => {
            insert_started_write_workflow_in_tx(transaction, item, item_revision, intent_id, launch)
                .await
        }
        (None, None) => Ok(()),
    }
}

pub(super) async fn validate_pending_dispatch(
    transaction: &mut Transaction<'_, Sqlite>,
    board_item_id: &str,
    intent_id: &str,
    applied: &DispatchAppliedTask,
    consumed_approval_grant_id: Option<&str>,
) -> Result<(), CliError> {
    let (item, item_revision) = load_item_in_tx(transaction, board_item_id)
        .await?
        .ok_or_else(|| db_error(format!("task-board item '{board_item_id}' not found")))?;
    if let Some((prepared_item_revision, _)) = workflow_start_fence(applied)?
        && item_revision != prepared_item_revision
    {
        let error = CliError::from(CliErrorKind::invalid_transition(
            "workflow item revision changed before worker claim",
        ));
        refuse_pending_admission_in_tx(
            transaction,
            intent_id,
            applied,
            consumed_approval_grant_id,
            &error.to_string(),
        )
        .await?;
        return Err(error);
    }
    if let Err(error) = ensure_dispatch_item_startable(
        &item,
        &applied.session_id,
        &applied.work_item_id,
        applied.item.workflow.execution_id.as_deref(),
    ) {
        refuse_pending_admission_in_tx(
            transaction,
            intent_id,
            applied,
            consumed_approval_grant_id,
            &error.to_string(),
        )
        .await?;
        return Err(error);
    }
    if let TaskBoardAdmissionCheck::Blocked(admission) =
        revalidate_dispatch_admission_in_tx(transaction, intent_id, &item, item_revision).await?
    {
        refuse_pending_admission_in_tx(
            transaction,
            intent_id,
            applied,
            consumed_approval_grant_id,
            &admission.refusal_message(),
        )
        .await?;
        return Err(CliErrorKind::invalid_transition(admission.refusal_message()).into());
    }
    Ok(())
}
