use sqlx::{Sqlite, Transaction, query};

use super::{phase_label, to_i64};
use crate::daemon::db::{CliError, TaskBoardRemoteLifecycleTrustSnapshot, db_error};
use crate::daemon::task_board_remote_transport::wire::RemoteOfferRequest;

pub(in crate::daemon::db::task_board) struct RemoteAssignmentInsertInput<'a> {
    pub(in crate::daemon::db::task_board) request: &'a RemoteOfferRequest,
    pub(in crate::daemon::db::task_board) principal: &'a str,
    pub(in crate::daemon::db::task_board) offered_at: &'a str,
    pub(in crate::daemon::db::task_board) lease_id: Option<&'a str>,
    pub(in crate::daemon::db::task_board) lease_expires_at: &'a str,
    pub(in crate::daemon::db::task_board) deadline_at: &'a str,
    pub(in crate::daemon::db::task_board) executor_configuration_revision: Option<u64>,
    pub(in crate::daemon::db::task_board) executor_checkout_path: Option<&'a str>,
    pub(in crate::daemon::db::task_board) lifecycle_trust:
        Option<&'a TaskBoardRemoteLifecycleTrustSnapshot>,
}

pub(crate) async fn insert_assignment_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    input: &RemoteAssignmentInsertInput<'_>,
) -> Result<(), CliError> {
    let request_json = serde_json::to_string(input.request)
        .map_err(|error| db_error(format!("serialize remote offer: {error}")))?;
    let lifecycle_trust_json = input
        .lifecycle_trust
        .map(TaskBoardRemoteLifecycleTrustSnapshot::encoded)
        .transpose()?;
    let lifecycle_trust_sha256 = input
        .lifecycle_trust
        .map(|trust| trust.snapshot_sha256.as_str());
    let request = input.request;
    query(
        "INSERT INTO task_board_remote_assignments (
           assignment_id, execution_id, phase, action_key, attempt, idempotency_key,
           host_id, target_host_instance_id, fencing_epoch, configuration_revision,
           execution_record_sha256, request_sha256, request_json,
           authenticated_principal, state, offered_at, lease_id, lease_expires_at,
           deadline_at, executor_configuration_revision, executor_checkout_path,
           controller_lifecycle_trust_json, controller_lifecycle_trust_sha256, updated_at
         ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13,
                   ?14, 'offered', ?15, ?16, ?17, ?18, ?19, ?20, ?21, ?22, ?15)",
    )
    .bind(&request.binding.assignment_id)
    .bind(&request.binding.execution_id)
    .bind(phase_label(request.binding.phase)?)
    .bind(&request.binding.action_key)
    .bind(i64::from(request.binding.attempt))
    .bind(&request.binding.idempotency_key)
    .bind(&request.binding.host_id)
    .bind(&request.binding.host_instance_id)
    .bind(to_i64(
        request.binding.fencing_epoch,
        "assignment fencing epoch",
    )?)
    .bind(to_i64(
        request.binding.configuration_revision,
        "assignment configuration revision",
    )?)
    .bind(&request.binding.execution_record_sha256)
    .bind(&request.request_sha256)
    .bind(request_json)
    .bind(input.principal)
    .bind(input.offered_at)
    .bind(input.lease_id)
    .bind(input.lease_expires_at)
    .bind(input.deadline_at)
    .bind(
        input
            .executor_configuration_revision
            .map(|revision| to_i64(revision, "executor configuration revision"))
            .transpose()?,
    )
    .bind(input.executor_checkout_path)
    .bind(lifecycle_trust_json)
    .bind(lifecycle_trust_sha256)
    .execute(transaction.as_mut())
    .await
    .map(|_| ())
    .map_err(|error| db_error(format!("insert remote assignment: {error}")))
}
