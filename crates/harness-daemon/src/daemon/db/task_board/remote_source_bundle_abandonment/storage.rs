use sqlx::{Sqlite, Transaction, query, query_as};

use super::TaskBoardRemoteSourceBundleAbandonment;
use crate::daemon::db::task_board::remote_assignment_model::{nonblank, to_i64};
use crate::daemon::db::{CliError, db_error};
use crate::daemon::task_board_remote_transport::wire::{
    RemoteOfferRequest, RemoteSourceBundleAbandonRequest, RemoteSourceBundleAbandonResponse,
    RemoteSourceBundleReceiptVerificationResponse,
};

#[derive(sqlx::FromRow)]
struct SourceBundleAbandonmentRow {
    assignment_id: String,
    fencing_epoch: i64,
    execution_id: String,
    action_key: String,
    attempt: i64,
    idempotency_key: String,
    host_id: String,
    target_host_instance_id: String,
    offer_request_sha256: String,
    upload_request_sha256: String,
    authenticated_principal: String,
    verified_absence_sha256: String,
    abandon_request_sha256: String,
    verified_absence_checked_at: String,
    verified_absence_json: String,
    request_json: String,
    abandoned_by_host_instance_id: String,
    response_json: String,
}

impl SourceBundleAbandonmentRow {
    fn into_record(self) -> Result<TaskBoardRemoteSourceBundleAbandonment, CliError> {
        let request = serde_json::from_str::<RemoteSourceBundleAbandonRequest>(&self.request_json)
            .map_err(|error| db_error(format!("decode source abandonment request: {error}")))?;
        let verification = serde_json::from_str::<RemoteSourceBundleReceiptVerificationResponse>(
            &self.verified_absence_json,
        )
        .map_err(|error| db_error(format!("decode source absence verification: {error}")))?;
        let response =
            serde_json::from_str::<RemoteSourceBundleAbandonResponse>(&self.response_json)
                .map_err(|error| {
                    db_error(format!("decode source abandonment response: {error}"))
                })?;
        request
            .validate()
            .map_err(|error| db_error(format!("validate source abandonment request: {error}")))?;
        response
            .validate(&request)
            .map_err(|error| db_error(format!("validate source abandonment response: {error}")))?;
        let canonical_verification = serde_json::to_string(&verification).map_err(|error| {
            db_error(format!(
                "encode canonical source absence verification: {error}"
            ))
        })?;
        let canonical_request = serde_json::to_string(&request).map_err(|error| {
            db_error(format!(
                "encode canonical source abandonment request: {error}"
            ))
        })?;
        let canonical_response = serde_json::to_string(&response).map_err(|error| {
            db_error(format!(
                "encode canonical source abandonment response: {error}"
            ))
        })?;
        nonblank(
            &self.authenticated_principal,
            "source abandonment authenticated principal",
        )?;
        let epoch = u64::try_from(self.fencing_epoch)
            .ok()
            .filter(|epoch| *epoch > 0)
            .ok_or_else(|| db_error("source abandonment fencing epoch is invalid"))?;
        let attempt = u32::try_from(self.attempt)
            .ok()
            .filter(|attempt| *attempt > 0)
            .ok_or_else(|| db_error("source abandonment attempt is invalid"))?;
        let binding = request.offer.binding.clone();
        let exact = self.verified_absence_json == canonical_verification
            && self.request_json == canonical_request
            && self.response_json == canonical_response
            && verification == request.verified_absence
            && binding.assignment_id == self.assignment_id
            && binding.fencing_epoch == epoch
            && binding.execution_id == self.execution_id
            && binding.action_key == self.action_key
            && binding.attempt == attempt
            && binding.idempotency_key == self.idempotency_key
            && binding.host_id == self.host_id
            && binding.host_id == self.authenticated_principal
            && binding.host_instance_id == self.target_host_instance_id
            && request.offer.request_sha256 == self.offer_request_sha256
            && request.upload_request_sha256 == self.upload_request_sha256
            && verification.response_sha256 == self.verified_absence_sha256
            && verification.checked_at == self.verified_absence_checked_at
            && request.request_sha256 == self.abandon_request_sha256
            && response.abandoned_by_host_instance_id == self.abandoned_by_host_instance_id;
        if !exact {
            return Err(db_error(
                "source abandonment row contradicts its sealed request or response",
            ));
        }
        Ok(TaskBoardRemoteSourceBundleAbandonment {
            binding,
            offer_request_sha256: self.offer_request_sha256,
            upload_request_sha256: self.upload_request_sha256,
            verified_absence_sha256: self.verified_absence_sha256,
            abandon_request_sha256: self.abandon_request_sha256,
            authenticated_principal: self.authenticated_principal,
            request,
            response,
        })
    }
}

const LOAD_ABANDONMENT_COLLISIONS_QUERY: &str =
    "SELECT assignment_id, fencing_epoch, execution_id, action_key, attempt,
            idempotency_key, host_id, target_host_instance_id,
            offer_request_sha256, upload_request_sha256,
            authenticated_principal, verified_absence_sha256,
            abandon_request_sha256, verified_absence_checked_at,
            verified_absence_json, request_json,
            abandoned_by_host_instance_id, response_json
     FROM task_board_remote_source_bundle_abandonments
     WHERE assignment_id = ?1 OR offer_request_sha256 = ?2
        OR upload_request_sha256 = ?3
        OR (execution_id = ?4 AND fencing_epoch = ?5)
     ORDER BY assignment_id, fencing_epoch";

const LOAD_ABANDONMENT_QUERY: &str =
    "SELECT assignment_id, fencing_epoch, execution_id, action_key, attempt,
            idempotency_key, host_id, target_host_instance_id,
            offer_request_sha256, upload_request_sha256,
            authenticated_principal, verified_absence_sha256,
            abandon_request_sha256, verified_absence_checked_at,
            verified_absence_json, request_json,
            abandoned_by_host_instance_id, response_json
     FROM task_board_remote_source_bundle_abandonments
     WHERE assignment_id = ?1 AND fencing_epoch = ?2";

pub(crate) async fn load_abandonment_collisions_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    offer: &RemoteOfferRequest,
    upload_request_sha256: &str,
) -> Result<Vec<TaskBoardRemoteSourceBundleAbandonment>, CliError> {
    query_as::<_, SourceBundleAbandonmentRow>(LOAD_ABANDONMENT_COLLISIONS_QUERY)
        .bind(&offer.binding.assignment_id)
        .bind(&offer.request_sha256)
        .bind(upload_request_sha256)
        .bind(&offer.binding.execution_id)
        .bind(to_i64(
            offer.binding.fencing_epoch,
            "source abandonment fencing epoch",
        )?)
        .fetch_all(transaction.as_mut())
        .await
        .map_err(|error| db_error(format!("load source abandonment collision: {error}")))?
        .into_iter()
        .map(SourceBundleAbandonmentRow::into_record)
        .collect()
}

pub(crate) async fn load_abandonment_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    assignment_id: &str,
    fencing_epoch: u64,
) -> Result<Option<TaskBoardRemoteSourceBundleAbandonment>, CliError> {
    query_as::<_, SourceBundleAbandonmentRow>(LOAD_ABANDONMENT_QUERY)
        .bind(assignment_id)
        .bind(to_i64(fencing_epoch, "source abandonment fencing epoch")?)
        .fetch_optional(transaction.as_mut())
        .await
        .map_err(|error| db_error(format!("load source abandonment: {error}")))?
        .map(SourceBundleAbandonmentRow::into_record)
        .transpose()
}

pub(crate) async fn source_offer_is_abandoned_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    offer: &RemoteOfferRequest,
) -> Result<bool, CliError> {
    query(
        "SELECT 1 FROM task_board_remote_source_bundle_abandonments
         WHERE assignment_id = ?1 OR offer_request_sha256 = ?2
            OR (execution_id = ?3 AND fencing_epoch = ?4)
         LIMIT 1",
    )
    .bind(&offer.binding.assignment_id)
    .bind(&offer.request_sha256)
    .bind(&offer.binding.execution_id)
    .bind(to_i64(
        offer.binding.fencing_epoch,
        "source abandonment fencing epoch",
    )?)
    .fetch_optional(transaction.as_mut())
    .await
    .map(|row| row.is_some())
    .map_err(|error| db_error(format!("check source offer abandonment: {error}")))
}

pub(crate) async fn insert_abandonment_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    request: &RemoteSourceBundleAbandonRequest,
    principal: &str,
    response: &RemoteSourceBundleAbandonResponse,
) -> Result<(), CliError> {
    let verification_json = serde_json::to_string(&request.verified_absence)
        .map_err(|error| db_error(format!("serialize source absence verification: {error}")))?;
    let request_json = serde_json::to_string(request)
        .map_err(|error| db_error(format!("serialize source abandonment request: {error}")))?;
    let response_json = serde_json::to_string(response)
        .map_err(|error| db_error(format!("serialize source abandonment response: {error}")))?;
    let binding = &request.offer.binding;
    query(
        "INSERT INTO task_board_remote_source_bundle_abandonments (
           assignment_id, fencing_epoch, execution_id, action_key, attempt,
           idempotency_key, host_id, target_host_instance_id, offer_request_sha256,
           upload_request_sha256, authenticated_principal, verified_absence_sha256,
           abandon_request_sha256, verified_absence_checked_at, verified_absence_json,
           request_json, abandoned_by_host_instance_id, response_json, abandoned_at
         ) VALUES (
           ?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15,
           ?16, ?17, ?18, ?19
         )",
    )
    .bind(&binding.assignment_id)
    .bind(to_i64(
        binding.fencing_epoch,
        "source abandonment insert epoch",
    )?)
    .bind(&binding.execution_id)
    .bind(&binding.action_key)
    .bind(i64::from(binding.attempt))
    .bind(&binding.idempotency_key)
    .bind(&binding.host_id)
    .bind(&binding.host_instance_id)
    .bind(&request.offer.request_sha256)
    .bind(&request.upload_request_sha256)
    .bind(principal)
    .bind(&request.verified_absence.response_sha256)
    .bind(&request.request_sha256)
    .bind(&request.verified_absence.checked_at)
    .bind(verification_json)
    .bind(request_json)
    .bind(&response.abandoned_by_host_instance_id)
    .bind(response_json)
    .bind(&response.abandoned_at)
    .execute(transaction.as_mut())
    .await
    .map(|_| ())
    .map_err(|error| db_error(format!("persist source abandonment: {error}")))
}
