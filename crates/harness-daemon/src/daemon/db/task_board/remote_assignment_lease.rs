use chrono::{DateTime, Duration, Utc};
use sqlx::{Sqlite, Transaction, query};
use uuid::Uuid;

use super::ORCHESTRATOR_CHANGE_SCOPE;
use super::items::bump_change_in_tx;
use super::remote_assignment_lifecycle_owner::TaskBoardRemoteExecutorLifecycleOwner;
use super::remote_assignment_model::{
    TaskBoardRemoteAssignmentRecord, TaskBoardRemoteMutationOutcome, canonical_time, concurrent,
    load_assignment_in_tx, nonblank, to_i64,
};
use super::remote_claim_receipts::{
    claim_receipt_values, claim_response_for_record, exact_claim_response,
};
use crate::daemon::db::task_board::remote_execution_queries::RemoteExecutionQueries;
use crate::daemon::db::{AsyncDaemonDb, CliError, db_error};
use crate::task_board::TaskBoardRemoteAssignmentState;
use crate::task_board::remote_wire::wire::RemoteClaimResponse;
use crate::task_board::remote_wire::wire::TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION;
use crate::task_board::remote_wire::wire::{
    RemoteAttemptBinding, RemoteClaimRequest, RemoteLeaseRenewRequest,
};

impl AsyncDaemonDb {

    pub(crate) async fn mark_task_board_remote_assignment_running(
        &self,
        assignment_id: &str,
        owner: &TaskBoardRemoteExecutorLifecycleOwner,
        running_at: &str,
    ) -> Result<TaskBoardRemoteMutationOutcome, CliError> {
        canonical_time(running_at, "remote assignment running time")?;
        let mut transaction = self
            .begin_immediate_transaction("task board remote assignment running")
            .await?;
        let record = require_assignment(&mut transaction, assignment_id).await?;
        if let Some(outcome) = running_screen_outcome(&record, owner, running_at)? {
            let (reason, outcome) = outcome.into_reason_and_outcome(record);
            commit_noop(transaction, reason).await?;
            return Ok(outcome);
        }
        run_assignment_in_tx(&mut transaction, &record, owner, running_at).await?;
        finish_mutation(transaction, assignment_id, "running").await
    }

    pub(crate) async fn renew_task_board_remote_assignment_lease(
        &self,
        request: &RemoteLeaseRenewRequest,
        authenticated_principal: &str,
        renewed_at: &str,
    ) -> Result<TaskBoardRemoteMutationOutcome, CliError> {
        request
            .validate()
            .map_err(|error| db_error(format!("validate remote assignment renewal: {error}")))?;
        nonblank(
            authenticated_principal,
            "remote assignment authenticated principal",
        )?;
        let renewed = canonical_time(renewed_at, "remote assignment renewal time")?;
        let mut transaction = self
            .begin_immediate_transaction("task board remote assignment lease renewal")
            .await?;
        let record = require_assignment(&mut transaction, &request.binding.assignment_id).await?;
        if let Some(outcome) =
            lease_renewal_replay_or_stale(&record, request, authenticated_principal)
        {
            let (reason, outcome) = outcome.into_reason_and_outcome(record);
            commit_noop(transaction, reason).await?;
            return Ok(outcome);
        }
        ensure_before_expiry(&record, renewed_at)?;
        let expires = renewed + Duration::seconds(i64::from(request.extend_seconds));
        if lease_renewal_extension_is_stale(&record, expires)? {
            commit_noop(transaction, "renewal does not extend the current lease").await?;
            return Ok(TaskBoardRemoteMutationOutcome::Stale(record));
        }
        let lease_id = format!("remote-lease-{}", Uuid::new_v4().simple());
        let expires_at = expires.to_rfc3339_opts(chrono::SecondsFormat::AutoSi, true);
        let rows = query(
            "UPDATE task_board_remote_assignments SET lease_id = ?2, lease_expires_at = ?3,
             heartbeat_at = ?4, last_mutation_kind = 'renew',
             last_mutation_sha256 = ?5, result_json = NULL,
             status_sha256 = NULL, result_sha256 = NULL, updated_at = ?4
             WHERE assignment_id = ?1 AND fencing_epoch = ?6 AND lease_id = ?7
             AND state IN ('claimed', 'started', 'running')
             AND executor_start_authority_sha256 IS NULL
             AND executor_stop_pending_sha256 IS NULL",
        )
        .bind(&record.assignment_id)
        .bind(lease_id)
        .bind(expires_at)
        .bind(renewed_at)
        .bind(&request.request_sha256)
        .bind(to_i64(record.fencing_epoch, "assignment fencing epoch")?)
        .bind(&request.lease_id)
        .execute(transaction.as_mut())
        .await
        .map_err(|error| db_error(format!("renew remote assignment lease: {error}")))?
        .rows_affected();
        if rows != 1 {
            return Err(concurrent("remote assignment lease renewal lost its fence"));
        }
        finish_mutation(transaction, &record.assignment_id, "renewal").await
    }

    pub(crate) async fn build_task_board_remote_renew_request(
        &self,
        assignment_id: &str,
    ) -> Result<Option<RemoteLeaseRenewRequest>, CliError> {
        nonblank(assignment_id, "remote renewal assignment id")?;
        let Some(record) = self.task_board_remote_assignment(assignment_id).await? else {
            return Ok(None);
        };
        if !matches!(
            record.state,
            TaskBoardRemoteAssignmentState::Claimed
                | TaskBoardRemoteAssignmentState::Started
                | TaskBoardRemoteAssignmentState::Running
                | TaskBoardRemoteAssignmentState::Unknown
        ) {
            return Ok(None);
        }
        renew_request_for_record(&record).map(Some)
    }
}

pub(super) async fn claim_task_board_remote_assignment(
    db: &AsyncDaemonDb,
    request: &RemoteClaimRequest,
    authenticated_principal: &str,
    claimed_at: &str,
) -> Result<TaskBoardRemoteMutationOutcome, CliError> {
    request
        .validate()
        .map_err(|error| db_error(format!("validate remote assignment claim: {error}")))?;
    nonblank(
        authenticated_principal,
        "remote assignment authenticated principal",
    )?;
    canonical_time(claimed_at, "remote assignment claim time")?;
    let mut transaction = db
        .begin_immediate_transaction("task board remote assignment claim")
        .await?;
    let record = require_assignment(&mut transaction, &request.binding.assignment_id).await?;
    if let Some(outcome) = claim_screen_outcome(&record, request, authenticated_principal) {
        let (reason, outcome) = outcome.into_reason_and_outcome(record);
        commit_noop(transaction, reason).await?;
        return Ok(outcome);
    }
    ensure_before_expiry(&record, claimed_at)?;
    let response = claim_response_for_record(&record, request, claimed_at)?;
    claim_assignment_in_tx(
        &mut transaction,
        &record,
        request,
        &response,
        authenticated_principal,
        claimed_at,
    )
    .await?;
    finish_mutation(transaction, &record.assignment_id, "claim").await
}

pub(super) fn renew_request_for_record(
    record: &TaskBoardRemoteAssignmentRecord,
) -> Result<RemoteLeaseRenewRequest, CliError> {
    let offer = record.require_offer()?;
    let lease_id = record
        .lease_id
        .clone()
        .ok_or_else(|| db_error("remote renewal lease id is missing"))?;
    RemoteLeaseRenewRequest {
        schema_version: TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
        binding: offer.binding.clone(),
        lease_id,
        offer_request_sha256: offer.request_sha256.clone(),
        extend_seconds: offer.lease_seconds,
        request_sha256: String::new(),
    }
    .seal()
    .map_err(|error| db_error(format!("seal remote renewal request: {error}")))
}

pub(super) fn claim_request_for_record(
    record: &TaskBoardRemoteAssignmentRecord,
) -> Result<RemoteClaimRequest, CliError> {
    let offer = record.require_offer()?;
    let lease_id = record
        .lease_id
        .clone()
        .ok_or_else(|| db_error("remote claim lease id is missing"))?;
    RemoteClaimRequest {
        schema_version: TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
        binding: offer.binding.clone(),
        lease_id,
        offer_request_sha256: offer.request_sha256.clone(),
        request_sha256: String::new(),
    }
    .seal()
    .map_err(|error| db_error(format!("seal remote claim request: {error}")))
}

pub(super) async fn require_assignment(
    transaction: &mut Transaction<'_, Sqlite>,
    assignment_id: &str,
) -> Result<TaskBoardRemoteAssignmentRecord, CliError> {
    nonblank(assignment_id, "remote assignment id")?;
    load_assignment_in_tx(transaction, assignment_id)
        .await?
        .ok_or_else(|| db_error(format!("remote assignment '{assignment_id}' not found")))
}

pub(super) fn mutation_binding_matches(
    record: &TaskBoardRemoteAssignmentRecord,
    binding: &RemoteAttemptBinding,
    principal: &str,
    lease_id: &str,
) -> bool {
    record
        .offer
        .as_ref()
        .is_some_and(|offer| offer.binding == *binding)
        && record.authenticated_principal.as_deref() == Some(principal)
        && record.lease_id.as_deref() == Some(lease_id)
        && record.target_host_instance_id.as_deref() == Some(binding.host_instance_id.as_str())
}

pub(super) fn exact_mutation_replay(
    record: &TaskBoardRemoteAssignmentRecord,
    kind: &str,
    digest: &str,
) -> bool {
    record.last_mutation_kind.as_deref() == Some(kind)
        && record.last_mutation_sha256.as_deref() == Some(digest)
}

pub(super) fn ensure_before_expiry(
    record: &TaskBoardRemoteAssignmentRecord,
    now: &str,
) -> Result<(), CliError> {
    let now = canonical_time(now, "remote assignment mutation time")?;
    let lease = record
        .lease_expires_at
        .as_deref()
        .ok_or_else(|| db_error("remote assignment lease expiry is missing"))?;
    let deadline = record
        .deadline_at
        .as_deref()
        .ok_or_else(|| db_error("remote assignment deadline is missing"))?;
    if now <= canonical_time(lease, "remote assignment lease expiry")?
        && now <= canonical_time(deadline, "remote assignment deadline")?
    {
        Ok(())
    } else {
        Err(concurrent("remote assignment lease or deadline expired"))
    }
}

/// A screen refuses a mutation without touching assignment state; the
/// transaction still commits so the noop is durable, not rolled back. Kept
/// synchronous so a shared screen never adds another async frame to the
/// caller's future: `clippy::large_futures` is denied here, and one more
/// nested `.await` on a transaction-carrying future tips distant call sites
/// (route handlers, adoption loops) over the limit.
enum RemoteAssignmentScreenOutcome {
    Replayed(&'static str),
    Stale(&'static str),
}

impl RemoteAssignmentScreenOutcome {
    fn into_reason_and_outcome(
        self,
        record: TaskBoardRemoteAssignmentRecord,
    ) -> (&'static str, TaskBoardRemoteMutationOutcome) {
        match self {
            Self::Replayed(reason) => (reason, TaskBoardRemoteMutationOutcome::Replayed(record)),
            Self::Stale(reason) => (reason, TaskBoardRemoteMutationOutcome::Stale(record)),
        }
    }
}

fn claim_screen_outcome(
    record: &TaskBoardRemoteAssignmentRecord,
    request: &RemoteClaimRequest,
    authenticated_principal: &str,
) -> Option<RemoteAssignmentScreenOutcome> {
    if exact_claim_response(record, request, authenticated_principal).is_some() {
        return Some(RemoteAssignmentScreenOutcome::Replayed("replayed claim"));
    }
    if record.claim_receipt.is_some() {
        return Some(RemoteAssignmentScreenOutcome::Stale(
            "conflicting claim receipt",
        ));
    }
    if !mutation_binding_matches(
        record,
        &request.binding,
        authenticated_principal,
        &request.lease_id,
    ) || record.state != TaskBoardRemoteAssignmentState::Offered
    {
        return Some(RemoteAssignmentScreenOutcome::Stale("stale claim"));
    }
    None
}

fn running_screen_outcome(
    record: &TaskBoardRemoteAssignmentRecord,
    owner: &TaskBoardRemoteExecutorLifecycleOwner,
    running_at: &str,
) -> Result<Option<RemoteAssignmentScreenOutcome>, CliError> {
    if record.executor_stop_pending.is_some() {
        return Ok(Some(RemoteAssignmentScreenOutcome::Stale(
            "remote executor is permanently stop-only",
        )));
    }
    if canonical_time(running_at, "remote assignment running time")?
        >= canonical_time(&owner.expires_at, "remote lifecycle owner expiry")?
    {
        return Ok(Some(RemoteAssignmentScreenOutcome::Stale(
            "expired remote executor lifecycle owner",
        )));
    }
    if record.state == TaskBoardRemoteAssignmentState::Running
        && record.executor_lifecycle_owner.as_ref() == Some(owner)
    {
        return Ok(Some(RemoteAssignmentScreenOutcome::Replayed(
            "replayed running",
        )));
    }
    if record.state != TaskBoardRemoteAssignmentState::Started
        || record.executor_lifecycle_owner.as_ref() != Some(owner)
    {
        return Ok(Some(RemoteAssignmentScreenOutcome::Stale("stale running")));
    }
    Ok(None)
}

fn lease_renewal_replay_or_stale(
    record: &TaskBoardRemoteAssignmentRecord,
    request: &RemoteLeaseRenewRequest,
    authenticated_principal: &str,
) -> Option<RemoteAssignmentScreenOutcome> {
    if exact_mutation_replay(record, "renew", &request.request_sha256) {
        return Some(RemoteAssignmentScreenOutcome::Replayed("replayed renewal"));
    }
    let active = matches!(
        record.state,
        TaskBoardRemoteAssignmentState::Claimed
            | TaskBoardRemoteAssignmentState::Started
            | TaskBoardRemoteAssignmentState::Running
    );
    if record.executor_start_authority_sha256.is_some()
        || record.executor_stop_pending.is_some()
        || !active
        || !mutation_binding_matches(
            record,
            &request.binding,
            authenticated_principal,
            &request.lease_id,
        )
    {
        return Some(RemoteAssignmentScreenOutcome::Stale("stale renewal"));
    }
    None
}

fn lease_renewal_extension_is_stale(
    record: &TaskBoardRemoteAssignmentRecord,
    expires: DateTime<Utc>,
) -> Result<bool, CliError> {
    let deadline = record
        .deadline_at
        .as_deref()
        .ok_or_else(|| db_error("remote assignment deadline is missing"))?;
    let current_expiry = record
        .lease_expires_at
        .as_deref()
        .ok_or_else(|| db_error("remote assignment lease expiry is missing"))?;
    Ok(
        expires <= canonical_time(current_expiry, "current lease expiry")?
            || expires > canonical_time(deadline, "remote assignment deadline")?,
    )
}

async fn claim_assignment_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    record: &TaskBoardRemoteAssignmentRecord,
    request: &RemoteClaimRequest,
    response: &RemoteClaimResponse,
    principal: &str,
    claimed_at: &str,
) -> Result<(), CliError> {
    let (response_json, receipt_sha256) =
        claim_receipt_values(record, request, response, principal)?;
    let rows = query(
        "UPDATE task_board_remote_assignments SET state = 'claimed',
         claimed_host_instance_id = ?2, claimed_at = ?3, heartbeat_at = ?3,
         claim_request_sha256 = ?4, claim_response_json = ?5,
         claim_receipt_sha256 = ?6, last_mutation_kind = 'claim',
         last_mutation_sha256 = ?4, updated_at = ?3
         WHERE assignment_id = ?1 AND fencing_epoch = ?7 AND state = 'offered'
           AND claim_receipt_sha256 IS NULL",
    )
    .bind(&record.assignment_id)
    .bind(&request.binding.host_instance_id)
    .bind(claimed_at)
    .bind(&request.request_sha256)
    .bind(response_json)
    .bind(receipt_sha256)
    .bind(to_i64(record.fencing_epoch, "assignment fencing epoch")?)
    .execute(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("claim remote assignment: {error}")))?
    .rows_affected();
    require_one(rows, "remote assignment claim lost its fence")
}

async fn run_assignment_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    record: &TaskBoardRemoteAssignmentRecord,
    owner: &TaskBoardRemoteExecutorLifecycleOwner,
    running_at: &str,
) -> Result<(), CliError> {
    let rows = query(
        "UPDATE task_board_remote_assignments SET state = 'running', heartbeat_at = ?2,
         updated_at = ?2 WHERE assignment_id = ?1 AND fencing_epoch = ?3
         AND state = 'started' AND executor_lifecycle_owner_sha256 = ?4
         AND executor_stop_pending_sha256 IS NULL",
    )
    .bind(&record.assignment_id)
    .bind(running_at)
    .bind(to_i64(record.fencing_epoch, "assignment fencing epoch")?)
    .bind(&owner.sha256)
    .execute(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("run remote assignment: {error}")))?
    .rows_affected();
    require_one(rows, "remote assignment running update lost its fence")
}

fn require_one(rows: u64, message: &'static str) -> Result<(), CliError> {
    if rows == 1 {
        Ok(())
    } else {
        Err(concurrent(message))
    }
}

pub(super) async fn finish_mutation(
    mut transaction: Transaction<'_, Sqlite>,
    assignment_id: &str,
    context: &str,
) -> Result<TaskBoardRemoteMutationOutcome, CliError> {
    bump_change_in_tx(&mut transaction, ORCHESTRATOR_CHANGE_SCOPE).await?;
    let updated = load_assignment_in_tx(&mut transaction, assignment_id)
        .await?
        .ok_or_else(|| db_error("updated remote assignment disappeared"))?;
    transaction
        .commit()
        .await
        .map_err(|error| db_error(format!("commit remote assignment {context}: {error}")))?;
    Ok(TaskBoardRemoteMutationOutcome::Updated(updated))
}

pub(super) async fn commit_noop(
    transaction: Transaction<'_, Sqlite>,
    reason: &str,
) -> Result<(), CliError> {
    transaction
        .commit()
        .await
        .map_err(|error| db_error(format!("commit {reason}: {error}")))
}
