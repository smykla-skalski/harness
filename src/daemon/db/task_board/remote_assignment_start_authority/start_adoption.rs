use sqlx::{Sqlite, Transaction, query};

use super::super::remote_assignment_lifecycle_owner::lifecycle_owner;
use super::super::remote_assignment_model::{TaskBoardRemoteAssignmentRecord, concurrent, to_i64};
use super::super::remote_start_receipts::{
    TaskBoardRemoteExecutorStartReceipt, start_receipt_values,
};
use super::TaskBoardRemoteExecutorStartIoPermit;
use crate::daemon::db::{CliError, db_error};
use crate::task_board::TaskBoardRemoteAssignmentState;

pub(super) async fn persist_start_adoption_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    record: &TaskBoardRemoteAssignmentRecord,
    permit: &TaskBoardRemoteExecutorStartIoPermit,
    receipt: &TaskBoardRemoteExecutorStartReceipt,
    started_at: &str,
    owner_instance_id: &str,
    owner_at: &str,
    owner_expires_at: &str,
) -> Result<(), CliError> {
    let mut adopted = record.clone();
    adopted.state = TaskBoardRemoteAssignmentState::Started;
    adopted.started_at = Some(started_at.into());
    adopted.heartbeat_at = Some(started_at.into());
    adopted.workspace_ref = Some(permit.identity.workspace_ref.clone());
    adopted.executor_start_authority_sha256 = None;
    adopted.executor_start_authority_at = None;
    adopted.executor_start_io_permit_sha256 = None;
    adopted.executor_start_io_permit_at = None;
    adopted.start_receipt = Some(receipt.clone());
    let owner = lifecycle_owner(&adopted, owner_instance_id, 1, owner_at)?;
    if owner.expires_at != owner_expires_at {
        return Err(db_error("remote executor initial owner expiry diverged"));
    }
    let (receipt_json, receipt_sha256) = start_receipt_values(receipt)?;
    let rows = query(
        "UPDATE task_board_remote_assignments
         SET state = 'started', started_at = ?2, heartbeat_at = ?2,
             workspace_ref = ?3, executor_start_authority_sha256 = NULL,
             executor_start_authority_at = NULL,
             executor_start_io_permit_sha256 = NULL,
             executor_start_io_permit_at = NULL,
             executor_start_receipt_json = ?7,
             executor_start_receipt_sha256 = ?8,
             executor_lifecycle_owner_instance_id = ?9,
             executor_lifecycle_owner_epoch = ?10,
             executor_lifecycle_owner_acquired_at = ?11,
             executor_lifecycle_owner_expires_at = ?12,
             executor_lifecycle_owner_sha256 = ?13, updated_at = ?11
         WHERE assignment_id = ?1 AND fencing_epoch = ?4 AND state = 'claimed'
           AND executor_start_authority_sha256 = ?5
           AND executor_start_authority_at = ?6
           AND executor_start_io_permit_sha256 = ?14
           AND executor_start_io_permit_at = ?15
           AND executor_start_receipt_sha256 IS NULL
           AND executor_stop_pending_sha256 IS NULL",
    )
    .bind(&record.assignment_id)
    .bind(started_at)
    .bind(&permit.identity.workspace_ref)
    .bind(to_i64(record.fencing_epoch, "assignment fencing epoch")?)
    .bind(&permit.authority.sha256)
    .bind(&permit.authority.acquired_at)
    .bind(receipt_json)
    .bind(receipt_sha256)
    .bind(&owner.owner_instance_id)
    .bind(to_i64(owner.owner_epoch, "remote lifecycle owner epoch")?)
    .bind(&owner.acquired_at)
    .bind(&owner.expires_at)
    .bind(&owner.sha256)
    .bind(&permit.sha256)
    .bind(&permit.permitted_at)
    .execute(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("adopt remote executor start: {error}")))?
    .rows_affected();
    if rows != 1 {
        return Err(concurrent("remote executor start adoption lost its fence"));
    }
    Ok(())
}
