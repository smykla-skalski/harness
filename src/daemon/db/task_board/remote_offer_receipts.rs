use sqlx::{Sqlite, Transaction, query, query_as};

use super::remote_assignment_model::{canonical_time, nonblank, phase_label, to_i64};
use crate::daemon::db::{AsyncDaemonDb, CliError, db_error};
use crate::daemon::task_board_remote_transport::wire::{
    RemoteLease, RemoteOfferDisposition, RemoteOfferRequest, RemoteOfferResponse,
    TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
};
use crate::errors::CliErrorKind;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum TaskBoardRemoteOfferReceiptDisposition {
    Accepted,
    Rejected,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct TaskBoardRemoteOfferReceipt {
    pub(crate) request: RemoteOfferRequest,
    pub(crate) authenticated_principal: String,
    pub(crate) disposition: TaskBoardRemoteOfferReceiptDisposition,
    pub(crate) initial_lease_id: Option<String>,
    pub(crate) initial_lease_expires_at: Option<String>,
    pub(crate) rejection_code: Option<String>,
    pub(crate) received_at: String,
}

impl TaskBoardRemoteOfferReceipt {
    pub(crate) fn is_exact_replay(&self, request: &RemoteOfferRequest, principal: &str) -> bool {
        self.request == *request && self.authenticated_principal == principal
    }

    pub(crate) fn response(&self) -> Result<RemoteOfferResponse, CliError> {
        let (disposition, lease, rejection_code) = match self.disposition {
            TaskBoardRemoteOfferReceiptDisposition::Accepted => (
                RemoteOfferDisposition::Accepted,
                Some(RemoteLease {
                    lease_id: self
                        .initial_lease_id
                        .clone()
                        .ok_or_else(|| db_error("accepted offer receipt has no lease id"))?,
                    expires_at: self
                        .initial_lease_expires_at
                        .clone()
                        .ok_or_else(|| db_error("accepted offer receipt has no lease expiry"))?,
                }),
                None,
            ),
            TaskBoardRemoteOfferReceiptDisposition::Rejected => (
                RemoteOfferDisposition::Rejected,
                None,
                self.rejection_code.clone(),
            ),
        };
        Ok(RemoteOfferResponse {
            schema_version: TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
            binding: self.request.binding.clone(),
            offer_request_sha256: self.request.request_sha256.clone(),
            disposition,
            lease,
            rejection_code,
        })
    }
}

impl AsyncDaemonDb {
    pub(crate) async fn exact_task_board_remote_offer_receipt(
        &self,
        request: &RemoteOfferRequest,
        authenticated_principal: &str,
    ) -> Result<Option<TaskBoardRemoteOfferReceipt>, CliError> {
        request
            .validate()
            .map_err(|error| db_error(format!("validate remote offer receipt lookup: {error}")))?;
        nonblank(
            authenticated_principal,
            "remote offer receipt lookup principal",
        )?;
        let mut transaction = self
            .pool()
            .begin()
            .await
            .map_err(|error| db_error(format!("begin remote offer receipt lookup: {error}")))?;
        let receipts = load_offer_receipt_collisions_in_tx(&mut transaction, request).await?;
        let receipt = match receipts.as_slice() {
            [] => None,
            [receipt] if receipt.is_exact_replay(request, authenticated_principal) => {
                Some(receipt.clone())
            }
            _ => {
                return Err(CliErrorKind::concurrent_modification(
                    "remote offer receipt conflicts with the exact request",
                )
                .into());
            }
        };
        transaction
            .commit()
            .await
            .map_err(|error| db_error(format!("commit remote offer receipt lookup: {error}")))?;
        Ok(receipt)
    }
}

#[derive(sqlx::FromRow)]
struct RemoteOfferReceiptRow {
    request_json: String,
    authenticated_principal: String,
    disposition: String,
    initial_lease_id: Option<String>,
    initial_lease_expires_at: Option<String>,
    rejection_code: Option<String>,
    received_at: String,
}

impl RemoteOfferReceiptRow {
    fn into_receipt(self) -> Result<TaskBoardRemoteOfferReceipt, CliError> {
        let request = serde_json::from_str::<RemoteOfferRequest>(&self.request_json)
            .map_err(|error| db_error(format!("decode remote offer receipt: {error}")))?;
        request
            .validate()
            .map_err(|error| db_error(format!("validate remote offer receipt: {error}")))?;
        nonblank(
            &self.authenticated_principal,
            "remote offer receipt authenticated principal",
        )?;
        canonical_time(&self.received_at, "remote offer receipt time")?;
        let disposition = match self.disposition.as_str() {
            "accepted" => {
                validate_accepted_receipt(&self)?;
                TaskBoardRemoteOfferReceiptDisposition::Accepted
            }
            "rejected" => {
                validate_rejected_receipt(&self)?;
                TaskBoardRemoteOfferReceiptDisposition::Rejected
            }
            value => {
                return Err(db_error(format!(
                    "invalid remote offer disposition '{value}'"
                )));
            }
        };
        Ok(TaskBoardRemoteOfferReceipt {
            request,
            authenticated_principal: self.authenticated_principal,
            disposition,
            initial_lease_id: self.initial_lease_id,
            initial_lease_expires_at: self.initial_lease_expires_at,
            rejection_code: self.rejection_code,
            received_at: self.received_at,
        })
    }
}

pub(super) async fn load_offer_receipt_collisions_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    request: &RemoteOfferRequest,
) -> Result<Vec<TaskBoardRemoteOfferReceipt>, CliError> {
    query_as::<_, RemoteOfferReceiptRow>(
        "SELECT request_json, authenticated_principal, disposition,
                initial_lease_id, initial_lease_expires_at, rejection_code, received_at
         FROM task_board_remote_offer_receipts
         WHERE assignment_id = ?1 OR idempotency_key = ?2 OR request_sha256 = ?3
           OR (execution_id = ?4 AND action_key = ?5 AND attempt = ?6)
           OR (execution_id = ?4 AND fencing_epoch = ?7)
         ORDER BY assignment_id",
    )
    .bind(&request.binding.assignment_id)
    .bind(&request.binding.idempotency_key)
    .bind(&request.request_sha256)
    .bind(&request.binding.execution_id)
    .bind(&request.binding.action_key)
    .bind(i64::from(request.binding.attempt))
    .bind(to_i64(
        request.binding.fencing_epoch,
        "offer receipt fencing epoch",
    )?)
    .fetch_all(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("load remote offer receipt collision: {error}")))?
    .into_iter()
    .map(RemoteOfferReceiptRow::into_receipt)
    .collect()
}

pub(super) async fn load_offer_receipt_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    assignment_id: &str,
) -> Result<Option<TaskBoardRemoteOfferReceipt>, CliError> {
    query_as::<_, RemoteOfferReceiptRow>(
        "SELECT request_json, authenticated_principal, disposition,
                initial_lease_id, initial_lease_expires_at, rejection_code, received_at
         FROM task_board_remote_offer_receipts WHERE assignment_id = ?1",
    )
    .bind(assignment_id)
    .fetch_optional(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("load remote offer receipt: {error}")))?
    .map(RemoteOfferReceiptRow::into_receipt)
    .transpose()
}

pub(super) async fn ensure_accepted_offer_receipt_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    request: &RemoteOfferRequest,
    principal: &str,
    lease_id: &str,
    lease_expires_at: &str,
    received_at: &str,
) -> Result<TaskBoardRemoteOfferReceipt, CliError> {
    ensure_offer_receipt_in_tx(
        transaction,
        request,
        principal,
        "accepted",
        Some(lease_id),
        Some(lease_expires_at),
        None,
        received_at,
    )
    .await
}

pub(super) async fn ensure_rejected_offer_receipt_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    request: &RemoteOfferRequest,
    principal: &str,
    rejection_code: &str,
    received_at: &str,
) -> Result<TaskBoardRemoteOfferReceipt, CliError> {
    validate_rejection_code(rejection_code)?;
    ensure_offer_receipt_in_tx(
        transaction,
        request,
        principal,
        "rejected",
        None,
        None,
        Some(rejection_code),
        received_at,
    )
    .await
}

#[allow(clippy::too_many_arguments)]
async fn ensure_offer_receipt_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    request: &RemoteOfferRequest,
    principal: &str,
    disposition: &str,
    initial_lease_id: Option<&str>,
    initial_lease_expires_at: Option<&str>,
    rejection_code: Option<&str>,
    received_at: &str,
) -> Result<TaskBoardRemoteOfferReceipt, CliError> {
    let receipts = load_offer_receipt_collisions_in_tx(transaction, request).await?;
    if let [receipt] = receipts.as_slice() {
        let exact = receipt.is_exact_replay(request, principal)
            && receipt_disposition(receipt) == disposition
            && receipt.initial_lease_id.as_deref() == initial_lease_id
            && receipt.initial_lease_expires_at.as_deref() == initial_lease_expires_at
            && receipt.rejection_code.as_deref() == rejection_code;
        if exact {
            return Ok(receipt.clone());
        }
        return Err(CliErrorKind::concurrent_modification(
            "remote offer receipt conflicts with immutable response evidence",
        )
        .into());
    }
    if !receipts.is_empty() {
        return Err(CliErrorKind::concurrent_modification(
            "remote offer receipt identity has multiple collisions",
        )
        .into());
    }
    insert_offer_receipt_in_tx(
        transaction,
        request,
        principal,
        disposition,
        initial_lease_id,
        initial_lease_expires_at,
        rejection_code,
        received_at,
    )
    .await?;
    load_offer_receipt_in_tx(transaction, &request.binding.assignment_id)
        .await?
        .ok_or_else(|| db_error("persisted remote offer receipt disappeared"))
}

#[allow(clippy::too_many_arguments)]
async fn insert_offer_receipt_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    request: &RemoteOfferRequest,
    principal: &str,
    disposition: &str,
    initial_lease_id: Option<&str>,
    initial_lease_expires_at: Option<&str>,
    rejection_code: Option<&str>,
    received_at: &str,
) -> Result<(), CliError> {
    let request_json = serde_json::to_string(request)
        .map_err(|error| db_error(format!("serialize remote offer receipt: {error}")))?;
    let binding = &request.binding;
    query(
        "INSERT INTO task_board_remote_offer_receipts (
           assignment_id, execution_id, phase, action_key, attempt, idempotency_key,
           host_id, target_host_instance_id, fencing_epoch, configuration_revision,
           execution_record_sha256, request_sha256, request_json,
           authenticated_principal, disposition, initial_lease_id,
           initial_lease_expires_at, rejection_code, received_at
         ) VALUES (
           ?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14,
           ?15, ?16, ?17, ?18, ?19
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
    .bind(to_i64(
        binding.fencing_epoch,
        "offer receipt fencing epoch",
    )?)
    .bind(to_i64(
        binding.configuration_revision,
        "offer receipt configuration revision",
    )?)
    .bind(&binding.execution_record_sha256)
    .bind(&request.request_sha256)
    .bind(request_json)
    .bind(principal)
    .bind(disposition)
    .bind(initial_lease_id)
    .bind(initial_lease_expires_at)
    .bind(rejection_code)
    .bind(received_at)
    .execute(transaction.as_mut())
    .await
    .map(|_| ())
    .map_err(|error| db_error(format!("persist remote offer receipt: {error}")))
}

const fn receipt_disposition(receipt: &TaskBoardRemoteOfferReceipt) -> &'static str {
    match receipt.disposition {
        TaskBoardRemoteOfferReceiptDisposition::Accepted => "accepted",
        TaskBoardRemoteOfferReceiptDisposition::Rejected => "rejected",
    }
}

fn validate_accepted_receipt(row: &RemoteOfferReceiptRow) -> Result<(), CliError> {
    let lease_id = row
        .initial_lease_id
        .as_deref()
        .ok_or_else(|| db_error("accepted remote offer receipt has no initial lease"))?;
    nonblank(lease_id, "accepted remote offer receipt lease id")?;
    let expires_at = row
        .initial_lease_expires_at
        .as_deref()
        .ok_or_else(|| db_error("accepted remote offer receipt has no initial lease expiry"))?;
    canonical_time(expires_at, "accepted remote offer receipt lease expiry")?;
    if row.rejection_code.is_some() {
        return Err(db_error(
            "accepted remote offer receipt has a rejection code",
        ));
    }
    Ok(())
}

fn validate_rejected_receipt(row: &RemoteOfferReceiptRow) -> Result<(), CliError> {
    if row.initial_lease_id.is_some() || row.initial_lease_expires_at.is_some() {
        return Err(db_error("rejected remote offer receipt has lease evidence"));
    }
    validate_rejection_code(
        row.rejection_code
            .as_deref()
            .ok_or_else(|| db_error("rejected remote offer receipt has no reason"))?,
    )
}

fn validate_rejection_code(value: &str) -> Result<(), CliError> {
    let valid = !value.is_empty()
        && value.len() <= 64
        && value
            .bytes()
            .all(|byte| byte.is_ascii_lowercase() || byte.is_ascii_digit() || byte == b'_');
    if valid {
        Ok(())
    } else {
        Err(db_error("remote offer rejection code is not canonical"))
    }
}
