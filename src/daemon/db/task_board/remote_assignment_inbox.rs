use chrono::{DateTime, Duration, Utc};
use sqlx::{Sqlite, Transaction};
use uuid::Uuid;

use super::ORCHESTRATOR_CHANGE_SCOPE;
use super::items::bump_change_in_tx;
use super::remote_assignment_archival_fence::require_no_archival_collision_in_tx;
use super::remote_assignment_cleanup::active_remote_assignments_in_tx;
use super::remote_assignment_model::{
    TaskBoardRemoteAssignmentRecord, TaskBoardRemoteOfferOutcome, canonical_time, concurrent,
    insert_assignment_in_tx, load_assignment_in_tx, load_offer_collision_in_tx, nonblank,
};
use super::remote_offer_receipts::{
    TaskBoardRemoteOfferReceipt, TaskBoardRemoteOfferReceiptDisposition,
    ensure_accepted_offer_receipt_in_tx, ensure_rejected_offer_receipt_in_tx,
    load_offer_receipt_collisions_in_tx, load_offer_receipt_in_tx,
};
use super::remote_source_bundle_abandonment::source_offer_is_abandoned_in_tx;
use super::remote_source_bundles::require_source_bundle_in_tx;
use crate::daemon::db::{AsyncDaemonDb, CliError, db_error};
use crate::daemon::task_board_remote_transport::wire::RemoteOfferRequest;
use crate::task_board::{
    TaskBoardLocalExecutionHostConfig, TaskBoardOrchestratorSettings, remote_capability_for_phase,
    validate_local_execution_host_config,
};

const EXECUTOR_UNAVAILABLE: &str = "executor_unavailable";
pub(super) const PREDECESSOR_OFFER_NOT_RECEIVED: &str = "predecessor_offer_not_received";

enum HostOfferAdmission {
    Rejected(&'static str),
    Accepted(AcceptedHostOffer),
}

struct AcceptedHostOffer {
    settings_revision: i64,
    checkout_path: String,
    lease_expires_at: String,
}

impl AsyncDaemonDb {
    pub(crate) async fn accept_task_board_remote_assignment_offer(
        &self,
        request: &RemoteOfferRequest,
        authenticated_principal: &str,
        host_instance_id: &str,
        accepted_at: &str,
    ) -> Result<TaskBoardRemoteOfferOutcome, CliError> {
        validate_host_offer(
            request,
            authenticated_principal,
            host_instance_id,
            accepted_at,
        )?;
        let accepted = canonical_time(accepted_at, "remote host offer acceptance time")?;
        let mut transaction = self
            .begin_immediate_transaction("task board remote host inbox offer")
            .await?;
        let receipts = load_offer_receipt_collisions_in_tx(&mut transaction, request).await?;
        if !receipts.is_empty() {
            return resolve_receipt_collision(
                transaction,
                receipts,
                request,
                authenticated_principal,
            )
            .await;
        }
        // The immutable offer receipt replays above are authoritative; past them,
        // an identity colliding with an archived legacy row is a deterministic
        // conflict before any host, settings, capacity, source, or insert work.
        require_no_archival_collision_in_tx(
            &mut transaction,
            &request.binding.assignment_id,
            &request.binding.idempotency_key,
            Some(&request.request_sha256),
            &request.binding.execution_id,
            request.binding.fencing_epoch,
        )
        .await?;
        let collisions = load_offer_collision_in_tx(&mut transaction, request).await?;
        if !collisions.is_empty() {
            return resolve_host_collision(
                transaction,
                collisions,
                request,
                authenticated_principal,
            )
            .await;
        }
        accept_new_host_offer(
            transaction,
            request,
            authenticated_principal,
            host_instance_id,
            accepted,
            accepted_at,
        )
        .await
    }
}

async fn accept_new_host_offer(
    mut transaction: Transaction<'_, Sqlite>,
    request: &RemoteOfferRequest,
    authenticated_principal: &str,
    host_instance_id: &str,
    accepted: DateTime<Utc>,
    accepted_at: &str,
) -> Result<TaskBoardRemoteOfferOutcome, CliError> {
    let accepted_offer = match admit_host_offer_in_tx(
        &mut transaction,
        request,
        host_instance_id,
        accepted,
    )
    .await?
    {
        HostOfferAdmission::Rejected(rejection_code) => {
            return reject_host_offer(
                transaction,
                request,
                authenticated_principal,
                rejection_code,
                accepted_at,
            )
            .await;
        }
        HostOfferAdmission::Accepted(accepted_offer) => accepted_offer,
    };
    require_source_bundle_in_tx(&mut transaction, request, authenticated_principal).await?;
    let lease_id = format!("remote-lease-{}", Uuid::new_v4().simple());
    let assignment = super::remote_assignment_model::RemoteAssignmentInsertInput {
        request,
        principal: authenticated_principal,
        offered_at: accepted_at,
        lease_id: Some(&lease_id),
        lease_expires_at: &accepted_offer.lease_expires_at,
        deadline_at: &request.deadline_at,
        executor_configuration_revision: Some(
            u64::try_from(accepted_offer.settings_revision)
                .map_err(|_| db_error("local executor settings revision is out of range"))?,
        ),
        executor_checkout_path: Some(&accepted_offer.checkout_path),
        lifecycle_trust: None,
    };
    insert_assignment_in_tx(&mut transaction, &assignment).await?;
    ensure_accepted_offer_receipt_in_tx(
        &mut transaction,
        request,
        authenticated_principal,
        &lease_id,
        &accepted_offer.lease_expires_at,
        accepted_at,
    )
    .await?;
    bump_change_in_tx(&mut transaction, ORCHESTRATOR_CHANGE_SCOPE).await?;
    let assignment = load_assignment_in_tx(&mut transaction, &request.binding.assignment_id)
        .await?
        .ok_or_else(|| db_error("accepted remote host assignment disappeared"))?;
    transaction
        .commit()
        .await
        .map_err(|error| db_error(format!("commit remote host inbox offer: {error}")))?;
    Ok(TaskBoardRemoteOfferOutcome::Created(assignment))
}

async fn admit_host_offer_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    request: &RemoteOfferRequest,
    host_instance_id: &str,
    accepted: DateTime<Utc>,
) -> Result<HostOfferAdmission, CliError> {
    // A generation whose source was durably abandoned - including a distinct
    // assignment aliasing the same (execution_id, fencing_epoch) - must never
    // be accepted before any host, source, or assignment mutation.
    if source_offer_is_abandoned_in_tx(transaction, request).await? {
        return Err(concurrent(
            "remote host offer generation was durably abandoned",
        ));
    }
    let (host, settings_revision) = local_host_in_tx(transaction).await?;
    if host.host_id != request.binding.host_id {
        return Ok(HostOfferAdmission::Rejected(EXECUTOR_UNAVAILABLE));
    }
    if request.binding.host_instance_id != host_instance_id {
        return Ok(HostOfferAdmission::Rejected(PREDECESSOR_OFFER_NOT_RECEIVED));
    }
    let deadline = canonical_time(&request.deadline_at, "remote assignment deadline")?;
    let lease_expires = accepted + Duration::seconds(i64::from(request.lease_seconds));
    let lease_expires_at = lease_expires.to_rfc3339_opts(chrono::SecondsFormat::AutoSi, true);
    if lease_expires > deadline {
        return Ok(HostOfferAdmission::Rejected(EXECUTOR_UNAVAILABLE));
    }
    let Some(checkout_path) = local_checkout_path(&host, request, host_instance_id)? else {
        return Ok(HostOfferAdmission::Rejected(EXECUTOR_UNAVAILABLE));
    };
    if !local_host_is_provisioned_in_tx(transaction, &host, settings_revision).await?
        || !local_capacity_available(transaction, &host).await?
    {
        return Ok(HostOfferAdmission::Rejected(EXECUTOR_UNAVAILABLE));
    }
    Ok(HostOfferAdmission::Accepted(AcceptedHostOffer {
        settings_revision,
        checkout_path: checkout_path.into(),
        lease_expires_at,
    }))
}

fn validate_host_offer(
    request: &RemoteOfferRequest,
    principal: &str,
    host_instance_id: &str,
    accepted_at: &str,
) -> Result<(), CliError> {
    request
        .validate()
        .map_err(|error| db_error(format!("validate remote host offer: {error}")))?;
    nonblank(principal, "remote assignment authenticated principal")?;
    nonblank(host_instance_id, "remote assignment host instance")?;
    canonical_time(accepted_at, "remote host offer acceptance time")?;
    if principal == request.binding.host_id {
        Ok(())
    } else {
        Err(concurrent(
            "remote offer principal does not match its bound executor host",
        ))
    }
}

pub(super) async fn local_host_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
) -> Result<(TaskBoardLocalExecutionHostConfig, i64), CliError> {
    let (settings_json, revision) = sqlx::query_as::<_, (String, i64)>(
        "SELECT settings_json, revision FROM task_board_orchestrator_settings
             WHERE singleton = 1",
    )
    .fetch_one(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("load local execution host settings: {error}")))?;
    let settings = serde_json::from_str::<TaskBoardOrchestratorSettings>(&settings_json)
        .map_err(|error| db_error(format!("decode local execution host settings: {error}")))?;
    validate_local_execution_host_config(&settings.local_execution_host)?;
    Ok((settings.local_execution_host, revision))
}

pub(super) fn local_checkout_path<'a>(
    host: &'a TaskBoardLocalExecutionHostConfig,
    request: &RemoteOfferRequest,
    host_instance_id: &str,
) -> Result<Option<&'a str>, CliError> {
    let capability = remote_capability_for_phase(request.binding.phase)?;
    let eligible = host.enabled
        && host.host_id == request.binding.host_id
        && request.binding.host_instance_id == host_instance_id
        && host.runtimes.contains(&request.launch.runtime)
        && host.capabilities.contains(&capability);
    Ok(eligible
        .then(|| {
            host.repositories
                .iter()
                .find(|repository| repository.repository == request.source.repository())
                .map(|repository| repository.checkout_path.as_str())
        })
        .flatten())
}

pub(super) async fn local_host_is_provisioned_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    host: &TaskBoardLocalExecutionHostConfig,
    settings_revision: i64,
) -> Result<bool, CliError> {
    let stored = sqlx::query_as::<_, (String, i64, bool)>(
        "SELECT host_role, configuration_revision, enabled
         FROM task_board_execution_hosts WHERE host_id = ?1",
    )
    .bind(&host.host_id)
    .fetch_optional(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("verify local execution host row: {error}")))?;
    Ok(stored.as_ref().is_some_and(|(role, revision, enabled)| {
        role == "executor_self" && *revision == settings_revision && *enabled
    }))
}

async fn reject_host_offer(
    mut transaction: Transaction<'_, Sqlite>,
    request: &RemoteOfferRequest,
    principal: &str,
    rejection_code: &str,
    rejected_at: &str,
) -> Result<TaskBoardRemoteOfferOutcome, CliError> {
    ensure_rejected_offer_receipt_in_tx(
        &mut transaction,
        request,
        principal,
        rejection_code,
        rejected_at,
    )
    .await?;
    bump_change_in_tx(&mut transaction, ORCHESTRATOR_CHANGE_SCOPE).await?;
    let rejection = load_offer_receipt_in_tx(&mut transaction, &request.binding.assignment_id)
        .await?
        .ok_or_else(|| db_error("rejected remote host offer disappeared"))?;
    transaction
        .commit()
        .await
        .map_err(|error| db_error(format!("commit rejected remote host offer: {error}")))?;
    Ok(TaskBoardRemoteOfferOutcome::Rejected(rejection))
}

async fn local_capacity_available(
    transaction: &mut Transaction<'_, Sqlite>,
    host: &TaskBoardLocalExecutionHostConfig,
) -> Result<bool, CliError> {
    let active = active_remote_assignments_in_tx(transaction, &host.host_id).await?;
    Ok(active < host.capacity)
}

async fn resolve_host_collision(
    transaction: Transaction<'_, Sqlite>,
    collisions: Vec<TaskBoardRemoteAssignmentRecord>,
    _request: &RemoteOfferRequest,
    _principal: &str,
) -> Result<TaskBoardRemoteOfferOutcome, CliError> {
    commit_noop(transaction, "conflicting host offer").await?;
    Err(concurrent(if collisions.len() == 1 {
        "remote host inbox assignment is missing its immutable offer receipt"
    } else {
        "remote host inbox contains conflicting assignment evidence"
    }))
}

async fn resolve_receipt_collision(
    transaction: Transaction<'_, Sqlite>,
    receipts: Vec<TaskBoardRemoteOfferReceipt>,
    request: &RemoteOfferRequest,
    principal: &str,
) -> Result<TaskBoardRemoteOfferOutcome, CliError> {
    if receipts.len() != 1 || !receipts[0].is_exact_replay(request, principal) {
        commit_noop(transaction, "conflicting host offer receipt").await?;
        return Err(concurrent(
            "remote host inbox contains conflicting immutable offer evidence",
        ));
    }
    let receipt = receipts.into_iter().next().expect("one receipt");
    let outcome = match receipt.disposition {
        TaskBoardRemoteOfferReceiptDisposition::Accepted => {
            TaskBoardRemoteOfferOutcome::AcceptedReplay(receipt)
        }
        TaskBoardRemoteOfferReceiptDisposition::Rejected => {
            TaskBoardRemoteOfferOutcome::Rejected(receipt)
        }
    };
    commit_noop(transaction, "replayed immutable host offer receipt").await?;
    Ok(outcome)
}

async fn commit_noop(transaction: Transaction<'_, Sqlite>, reason: &str) -> Result<(), CliError> {
    transaction
        .commit()
        .await
        .map_err(|error| db_error(format!("commit {reason}: {error}")))
}
