use chrono::Duration;
use sqlx::{Sqlite, Transaction, query, query_as};

use super::remote_assignment_lease::require_assignment;
use super::remote_assignment_model::{canonical_time, concurrent, nonblank, phase_label, to_i64};
use crate::daemon::db::{AsyncDaemonDb, CliError, db_error};
use crate::daemon::task_board_remote_transport::wire::{
    RemoteAssignmentWireState, RemoteSettledRequest, RemoteSettledResponse,
    TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
};

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct TaskBoardRemoteSettlementReceipt {
    pub(crate) request: RemoteSettledRequest,
    pub(crate) authenticated_principal: String,
    pub(crate) response: RemoteSettledResponse,
    pub(crate) cleanup_ready_at: String,
}

impl TaskBoardRemoteSettlementReceipt {
    pub(crate) fn is_exact_replay(
        &self,
        request: &RemoteSettledRequest,
        authenticated_principal: &str,
    ) -> bool {
        self.request == *request && self.authenticated_principal == authenticated_principal
    }
}

impl AsyncDaemonDb {
    pub(crate) async fn settle_task_board_remote_assignment(
        &self,
        request: &RemoteSettledRequest,
        authenticated_principal: &str,
        settled_at: &str,
    ) -> Result<TaskBoardRemoteSettlementReceipt, CliError> {
        request
            .validate()
            .map_err(|error| db_error(format!("validate remote settlement request: {error}")))?;
        nonblank(authenticated_principal, "remote settlement principal")?;
        canonical_time(settled_at, "remote settlement time")?;
        let mut transaction = self
            .begin_immediate_transaction("task board remote settlement receipt")
            .await?;
        let collisions = load_settlement_collisions_in_tx(&mut transaction, request).await?;
        if let [receipt] = collisions.as_slice() {
            if receipt.is_exact_replay(request, authenticated_principal) {
                transaction.commit().await.map_err(|error| {
                    db_error(format!("commit replayed remote settlement: {error}"))
                })?;
                return Ok(receipt.clone());
            }
            return Err(concurrent(
                "remote settlement conflicts with immutable receipt evidence",
            ));
        }
        if !collisions.is_empty() {
            return Err(concurrent(
                "remote settlement identity has multiple receipt collisions",
            ));
        }
        let assignment =
            require_assignment(&mut transaction, &request.binding.assignment_id).await?;
        require_current_settlement_window(&assignment, settled_at)?;
        require_exact_terminal_assignment(&assignment, request, authenticated_principal)?;
        let response = settlement_response(request, settled_at)?;
        insert_settlement_in_tx(
            &mut transaction,
            request,
            authenticated_principal,
            &response,
        )
        .await?;
        let receipt = load_settlement_in_tx(&mut transaction, &request.binding.assignment_id)
            .await?
            .ok_or_else(|| db_error("persisted remote settlement receipt disappeared"))?;
        super::remote_evidence_retention::prune_remote_evidence_in_tx(&mut transaction, settled_at)
            .await?;
        transaction
            .commit()
            .await
            .map_err(|error| db_error(format!("commit remote settlement receipt: {error}")))?;
        Ok(receipt)
    }

    pub(crate) async fn task_board_remote_settlement_receipt(
        &self,
        assignment_id: &str,
    ) -> Result<Option<TaskBoardRemoteSettlementReceipt>, CliError> {
        nonblank(assignment_id, "remote settlement assignment")?;
        let mut transaction = self
            .pool()
            .begin()
            .await
            .map_err(|error| db_error(format!("begin remote settlement read: {error}")))?;
        let receipt = load_settlement_in_tx(&mut transaction, assignment_id).await?;
        transaction
            .commit()
            .await
            .map_err(|error| db_error(format!("commit remote settlement read: {error}")))?;
        Ok(receipt)
    }
}

pub(super) fn require_current_settlement_window(
    assignment: &super::TaskBoardRemoteAssignmentRecord,
    settled_at: &str,
) -> Result<(), CliError> {
    let settled = canonical_time(settled_at, "remote settlement time")?;
    let deadline = assignment
        .deadline_at
        .as_deref()
        .ok_or_else(|| db_error("remote settlement assignment has no deadline"))?;
    let mut retention_anchor = canonical_time(deadline, "remote settlement deadline")?;
    if let Some(completed_at) = assignment.completed_at.as_deref() {
        retention_anchor = retention_anchor.max(canonical_time(
            completed_at,
            "remote settlement completion time",
        )?);
    }
    let retained_until = retention_anchor
        + Duration::days(super::remote_evidence_retention::REMOTE_EVIDENCE_RETENTION_DAYS);
    if settled <= retained_until {
        Ok(())
    } else {
        Err(concurrent(
            "remote settlement arrived after immutable evidence retention expired",
        ))
    }
}

pub(super) fn require_exact_terminal_assignment(
    assignment: &super::TaskBoardRemoteAssignmentRecord,
    request: &RemoteSettledRequest,
    principal: &str,
) -> Result<(), CliError> {
    let offer = assignment.require_offer()?;
    let exact = offer.binding == request.binding
        && offer.request_sha256 == request.offer_request_sha256
        && assignment.fencing_epoch == request.binding.fencing_epoch
        && assignment.lease_id.as_deref() == Some(request.lease_id.as_str())
        && assignment.authenticated_principal.as_deref() == Some(principal)
        && assignment.wire_state() == request.terminal_state
        && assignment.result_sha256.as_deref() == request.result_sha256.as_deref()
        && matches!(
            assignment.wire_state(),
            RemoteAssignmentWireState::Completed
                | RemoteAssignmentWireState::Failed
                | RemoteAssignmentWireState::Cancelled
                | RemoteAssignmentWireState::Superseded
                | RemoteAssignmentWireState::Unknown
        );
    if exact {
        Ok(())
    } else {
        Err(concurrent(
            "remote settlement does not match durable terminal assignment evidence",
        ))
    }
}

#[derive(sqlx::FromRow)]
struct RemoteSettlementRow {
    request_json: String,
    authenticated_principal: String,
    response_json: String,
    cleanup_ready_at: String,
}

impl RemoteSettlementRow {
    fn into_receipt(self) -> Result<TaskBoardRemoteSettlementReceipt, CliError> {
        let request = serde_json::from_str::<RemoteSettledRequest>(&self.request_json)
            .map_err(|error| db_error(format!("decode remote settlement request: {error}")))?;
        request
            .validate()
            .map_err(|error| db_error(format!("validate remote settlement request: {error}")))?;
        let response = serde_json::from_str::<RemoteSettledResponse>(&self.response_json)
            .map_err(|error| db_error(format!("decode remote settlement response: {error}")))?;
        response
            .validate(&request)
            .map_err(|error| db_error(format!("validate remote settlement response: {error}")))?;
        nonblank(
            &self.authenticated_principal,
            "remote settlement authenticated principal",
        )?;
        canonical_time(&self.cleanup_ready_at, "remote settlement cleanup marker")?;
        if response.settled_at != self.cleanup_ready_at {
            return Err(db_error(
                "remote settlement cleanup marker does not match first settlement time",
            ));
        }
        Ok(TaskBoardRemoteSettlementReceipt {
            request,
            authenticated_principal: self.authenticated_principal,
            response,
            cleanup_ready_at: self.cleanup_ready_at,
        })
    }
}

pub(super) async fn load_settlement_collisions_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    request: &RemoteSettledRequest,
) -> Result<Vec<TaskBoardRemoteSettlementReceipt>, CliError> {
    query_as::<_, RemoteSettlementRow>(
        "SELECT request_json, authenticated_principal, response_json, cleanup_ready_at
         FROM task_board_remote_settlement_receipts
         WHERE assignment_id = ?1 OR request_sha256 = ?2
           OR (execution_id = ?3 AND action_key = ?4 AND attempt = ?5)
           OR (execution_id = ?3 AND fencing_epoch = ?6)
         ORDER BY assignment_id",
    )
    .bind(&request.binding.assignment_id)
    .bind(&request.request_sha256)
    .bind(&request.binding.execution_id)
    .bind(&request.binding.action_key)
    .bind(i64::from(request.binding.attempt))
    .bind(to_i64(
        request.binding.fencing_epoch,
        "settlement fencing epoch",
    )?)
    .fetch_all(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("load remote settlement collision: {error}")))?
    .into_iter()
    .map(RemoteSettlementRow::into_receipt)
    .collect()
}

pub(super) async fn load_settlement_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    assignment_id: &str,
) -> Result<Option<TaskBoardRemoteSettlementReceipt>, CliError> {
    query_as::<_, RemoteSettlementRow>(
        "SELECT request_json, authenticated_principal, response_json, cleanup_ready_at
         FROM task_board_remote_settlement_receipts WHERE assignment_id = ?1",
    )
    .bind(assignment_id)
    .fetch_optional(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("load remote settlement receipt: {error}")))?
    .map(RemoteSettlementRow::into_receipt)
    .transpose()
}

pub(super) async fn insert_settlement_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    request: &RemoteSettledRequest,
    principal: &str,
    response: &RemoteSettledResponse,
) -> Result<(), CliError> {
    let request_json = serde_json::to_string(request)
        .map_err(|error| db_error(format!("serialize remote settlement request: {error}")))?;
    response
        .validate(request)
        .map_err(|error| db_error(format!("validate remote settlement response: {error}")))?;
    let response_json = serde_json::to_string(response)
        .map_err(|error| db_error(format!("serialize remote settlement response: {error}")))?;
    let binding = &request.binding;
    query(
        "INSERT INTO task_board_remote_settlement_receipts (
           assignment_id, execution_id, phase, action_key, attempt, idempotency_key,
           host_id, target_host_instance_id, fencing_epoch, configuration_revision,
           execution_record_sha256, lease_id, offer_request_sha256, terminal_state,
           result_sha256, request_sha256, request_json, authenticated_principal,
           response_json, settled_at, cleanup_ready_at
         ) VALUES (
           ?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14,
           ?15, ?16, ?17, ?18, ?19, ?20, ?20
         )",
    )
    .bind(&binding.assignment_id)
    .bind(&binding.execution_id)
    .bind(phase_label(binding.phase)?)
    .bind(&binding.action_key)
    .bind(i64::from(binding.attempt))
    .bind(&binding.idempotency_key)
    .bind(&binding.host_id)
    .bind(&binding.host_instance_id)
    .bind(to_i64(binding.fencing_epoch, "settlement fencing epoch")?)
    .bind(to_i64(
        binding.configuration_revision,
        "settlement configuration revision",
    )?)
    .bind(&binding.execution_record_sha256)
    .bind(&request.lease_id)
    .bind(&request.offer_request_sha256)
    .bind(terminal_state_label(request.terminal_state)?)
    .bind(&request.result_sha256)
    .bind(&request.request_sha256)
    .bind(request_json)
    .bind(principal)
    .bind(response_json)
    .bind(&response.settled_at)
    .execute(transaction.as_mut())
    .await
    .map(|_| ())
    .map_err(|error| db_error(format!("persist remote settlement receipt: {error}")))
}

fn settlement_response(
    request: &RemoteSettledRequest,
    settled_at: &str,
) -> Result<RemoteSettledResponse, CliError> {
    let response = RemoteSettledResponse {
        schema_version: TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
        binding: request.binding.clone(),
        offer_request_sha256: request.offer_request_sha256.clone(),
        settlement_request_sha256: request.request_sha256.clone(),
        settled_at: settled_at.into(),
    };
    response
        .validate(request)
        .map_err(|error| db_error(format!("validate remote settlement response: {error}")))?;
    Ok(response)
}

fn terminal_state_label(state: RemoteAssignmentWireState) -> Result<&'static str, CliError> {
    match state {
        RemoteAssignmentWireState::Completed => Ok("completed"),
        RemoteAssignmentWireState::Failed => Ok("failed"),
        RemoteAssignmentWireState::Cancelled => Ok("cancelled"),
        RemoteAssignmentWireState::Superseded => Ok("superseded"),
        RemoteAssignmentWireState::Unknown => Ok("unknown"),
        RemoteAssignmentWireState::Offered
        | RemoteAssignmentWireState::Claimed
        | RemoteAssignmentWireState::Running => {
            Err(db_error("remote settlement state is not terminal"))
        }
    }
}
