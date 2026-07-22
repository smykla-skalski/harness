//! Exact executor snapshot validation, start adoption, and terminal handoff.

use std::path::Path;

use crate::daemon::db::{
    AsyncDaemonDb, REMOTE_START_INTERRUPTED_WITHOUT_RUN_ERROR_CODE,
    REMOTE_START_INTERRUPTED_WITHOUT_RUN_FAILURE_CLASS, REMOTE_START_PREFLIGHT_ERROR_CODE,
    REMOTE_START_PREFLIGHT_FAILURE_CLASS, TaskBoardRemoteAssignmentRecord,
    TaskBoardRemoteExecutorStartIoPermit, TaskBoardRemoteExecutorStopAuthority,
    TaskBoardRemoteExecutorStopReason, TaskBoardRemoteMutationOutcome, executor_start_authority,
};
use crate::daemon::http::DaemonHttpState;
use crate::daemon::protocol::CodexRunSnapshot;
use crate::daemon::task_board_remote_transport::wire::{
    RemoteArtifactManifest, RemoteAssignmentWireState, RemoteLease, RemoteOfferRequest,
    RemoteStatusResponse, TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
};
use crate::errors::{CliError, CliErrorKind};
use crate::task_board::{TaskBoardFailureClass, TaskBoardRemoteAssignmentState};
use crate::workspace::utc_now;

use super::runtime::{
    PreparedRemoteWorkerAction, execute_remote_worker_action, validate_run_snapshot,
};
use super::stop::claim_and_settle_invalid_remote_run;
use super::stop::settle_lifecycle_settings_drift;
use super::terminal::persist_terminal_snapshot;
use super::{RemoteWorkerIdentity, claim_active_lifecycle_owner, concurrent};

pub(super) async fn execute_and_reconcile_remote_worker(
    state: &DaemonHttpState,
    db: &AsyncDaemonDb,
    mut record: TaskBoardRemoteAssignmentRecord,
    offer: &RemoteOfferRequest,
    identity: &RemoteWorkerIdentity,
    action: PreparedRemoteWorkerAction,
    workspace: &Path,
) -> Result<(), CliError> {
    let snapshot =
        match execute_remote_worker_action(state, db, offer, identity, &action, workspace).await {
            Ok(snapshot) => snapshot,
            Err(error) => {
                return match action.fresh_start_permit() {
                    Some(permit) => {
                        reconcile_fresh_start_failure(db, &record, identity, permit, error).await
                    }
                    // A probe (recovery) failure has launched nothing new: defer and
                    // let the next scan retry against fresh run evidence.
                    None => Err(error),
                };
            }
        };
    let permit = action.permit();
    if record.state == TaskBoardRemoteAssignmentState::Claimed && permit.is_none() {
        return stop_pre_permit_remote_run(state, db, &record, &snapshot).await;
    }
    validate_or_stop(
        state, db, &record, offer, identity, permit, workspace, &snapshot,
    )
    .await?;
    if record.state == TaskBoardRemoteAssignmentState::Claimed {
        let permit = permit
            .ok_or_else(|| concurrent("claimed remote worker has no durable Start I/O permit"))?;
        let Some(started) =
            Box::pin(adopt_remote_start(state, db, permit, &snapshot, workspace)).await?
        else {
            return Ok(());
        };
        let Some(owned) = claim_active_lifecycle_owner(state, db, &started).await? else {
            return Ok(());
        };
        record = owned.record;
        if owned.stop_only {
            return settle_lifecycle_settings_drift(state, db, &record, &snapshot).await;
        }
    }
    if !snapshot.status.is_active() {
        return Box::pin(persist_terminal_snapshot(
            db,
            &state.daemon_epoch,
            &record,
            &snapshot,
            workspace,
        ))
        .await;
    }
    mark_running_if_active(db, &record, &snapshot).await
}

/// A matching deterministic run without a persisted Start-I/O permit is not
/// adoptable. The pre-permit start authority is enough only to freeze this
/// exact run behind a stop intent; the stop CAS rejects stale generations.
async fn stop_pre_permit_remote_run(
    state: &DaemonHttpState,
    db: &AsyncDaemonDb,
    record: &TaskBoardRemoteAssignmentRecord,
    snapshot: &CodexRunSnapshot,
) -> Result<(), CliError> {
    let authority = executor_start_authority(record)?.ok_or_else(|| {
        concurrent("remote executor run has no durable pre-permit start authority")
    })?;
    claim_and_settle_invalid_remote_run(
        state,
        db,
        &TaskBoardRemoteExecutorStopAuthority::PrePermit(authority),
        snapshot,
        TaskBoardRemoteExecutorStopReason::StartEvidenceInvalid,
    )
    .await
}

/// A recovered durable permit with no deterministic run is a proven no-run
/// Start failure. The DB mutation rereads the run transactionally and either
/// seals the receipt or defers on a newly observed run; recovery never retries
/// external Start for the same permit.
pub(super) async fn reconcile_persisted_start_without_run(
    db: &AsyncDaemonDb,
    record: &TaskBoardRemoteAssignmentRecord,
    permit: &TaskBoardRemoteExecutorStartIoPermit,
) -> Result<(), CliError> {
    let response = failed_at_claimed_response(
        record,
        REMOTE_START_INTERRUPTED_WITHOUT_RUN_ERROR_CODE,
        REMOTE_START_INTERRUPTED_WITHOUT_RUN_FAILURE_CLASS,
        &utc_now(),
    )?;
    match db
        .fail_task_board_remote_executor_start_without_run(permit, &response)
        .await?
    {
        TaskBoardRemoteMutationOutcome::Updated(_)
        | TaskBoardRemoteMutationOutcome::Replayed(_) => Ok(()),
        TaskBoardRemoteMutationOutcome::Stale(_) => Err(concurrent(
            "remote executor no-run recovery lost its claimed generation",
        )),
    }
}

/// Reconciles a fresh external Start that returned an error. Rereads the
/// deterministic run: any proven no-run atomically seals a canonical typed
/// Failed-at-Claimed status (transient for a transiently-unreachable endpoint,
/// otherwise non-retryable) and clears the permit and start authority. The run
/// reread - not the error code - is the authoritative no-run proof. An observed
/// or ambiguous run instead retains the permit, authority, and capacity so a
/// later scan can probe/adopt or stop it.
async fn reconcile_fresh_start_failure(
    db: &AsyncDaemonDb,
    record: &TaskBoardRemoteAssignmentRecord,
    identity: &RemoteWorkerIdentity,
    permit: &TaskBoardRemoteExecutorStartIoPermit,
    error: CliError,
) -> Result<(), CliError> {
    if db.codex_run(&identity.run_id).await?.is_some() {
        // A durable run exists, so the Start may have launched: ambiguous. Retain
        // permit/authority/capacity and defer; only a proven no-run seals a failure.
        return Err(error);
    }
    let failure_class = no_run_start_failure_class(&error);
    let response = failed_at_claimed_response(record, error.code(), failure_class, &utc_now())?;
    match db
        .fail_task_board_remote_executor_start_without_run(permit, &response)
        .await?
    {
        TaskBoardRemoteMutationOutcome::Updated(_)
        | TaskBoardRemoteMutationOutcome::Replayed(_) => Ok(()),
        TaskBoardRemoteMutationOutcome::Stale(_) => Err(concurrent(
            "remote executor Start failure lost its claimed generation",
        )),
    }
}

/// Builds the canonical typed Failed status for a no-run Start failure: Failed at
/// the Claimed evidence stage (claimed, never started), carrying the proven
/// cause's error code and failure class but no result or artifacts.
fn failed_at_claimed_response(
    record: &TaskBoardRemoteAssignmentRecord,
    error_code: &str,
    failure_class: TaskBoardFailureClass,
    observed_at: &str,
) -> Result<RemoteStatusResponse, CliError> {
    let offer = record.require_offer()?;
    RemoteStatusResponse {
        schema_version: TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
        binding: offer.binding.clone(),
        state: RemoteAssignmentWireState::Failed,
        offer_request_sha256: offer.request_sha256.clone(),
        status_sha256: String::new(),
        lease: Some(RemoteLease {
            lease_id: required(&record.lease_id, "lease")?,
            expires_at: required(&record.lease_expires_at, "lease expiry")?,
        }),
        result: None,
        output_artifacts: RemoteArtifactManifest::default(),
        claimed_at: record.claimed_at.clone(),
        started_at: None,
        workspace_ref: None,
        error_code: Some(error_code.into()),
        failure_class: Some(failure_class),
        observed_at: observed_at.into(),
    }
    .seal()
    .map_err(|error| {
        CliErrorKind::workflow_parse(format!("seal Failed-at-Claimed status: {error}")).into()
    })
}

/// A no-run Start failure is retryable only when the executor endpoint was
/// transiently unreachable (`CODEX001`); every other proven no-run cause is
/// non-retryable and surfaces its exact code so a human can resolve it.
fn no_run_start_failure_class(error: &CliError) -> TaskBoardFailureClass {
    if error.code() == REMOTE_START_PREFLIGHT_ERROR_CODE {
        REMOTE_START_PREFLIGHT_FAILURE_CLASS
    } else {
        TaskBoardFailureClass::Permanent
    }
}

fn required(value: &Option<String>, label: &str) -> Result<String, CliError> {
    value
        .clone()
        .ok_or_else(|| concurrent_owned(format!("Failed-at-Claimed status has no {label}")))
}

fn concurrent_owned(message: String) -> CliError {
    CliErrorKind::concurrent_modification(message).into()
}

#[allow(clippy::too_many_arguments)]
async fn validate_or_stop(
    state: &DaemonHttpState,
    db: &AsyncDaemonDb,
    record: &TaskBoardRemoteAssignmentRecord,
    offer: &RemoteOfferRequest,
    identity: &RemoteWorkerIdentity,
    permit: Option<&TaskBoardRemoteExecutorStartIoPermit>,
    workspace: &Path,
    snapshot: &CodexRunSnapshot,
) -> Result<(), CliError> {
    let Err(error) = validate_run_snapshot(snapshot, offer, identity, workspace) else {
        return Ok(());
    };
    if let Some((stop_authority, reason)) = invalid_run_stop_source(record, permit)? {
        let validation_error = error.to_string();
        if let Err(stop_error) =
            claim_and_settle_invalid_remote_run(state, db, &stop_authority, snapshot, reason).await
        {
            return Err(CliErrorKind::workflow_io(format!(
                "validate remote worker start: {validation_error}; stop invalid worker: {stop_error}"
            ))
            .into());
        }
    }
    Err(error)
}

fn invalid_run_stop_source(
    record: &TaskBoardRemoteAssignmentRecord,
    start: Option<&TaskBoardRemoteExecutorStartIoPermit>,
) -> Result<
    Option<(
        TaskBoardRemoteExecutorStopAuthority,
        TaskBoardRemoteExecutorStopReason,
    )>,
    CliError,
> {
    if let Some(start) = start {
        return Ok(Some((
            TaskBoardRemoteExecutorStopAuthority::Start(start.clone()),
            TaskBoardRemoteExecutorStopReason::StartEvidenceInvalid,
        )));
    }
    if let Some(owner) = record.executor_lifecycle_owner.clone() {
        return Ok(Some((
            TaskBoardRemoteExecutorStopAuthority::Lifecycle(owner),
            TaskBoardRemoteExecutorStopReason::LifecycleEvidenceInvalid,
        )));
    }
    // Neither a Start I/O permit nor a lifecycle owner is durable, yet the run
    // failed validation. A pre-permit exact run (its permit transaction rolled
    // back after the run side-effect) is still fenced by the start authority
    // acquired before it, so stop it under that authority; otherwise there is no
    // durable fence and a later scan reconverges.
    Ok(executor_start_authority(record)?.map(|authority| {
        (
            TaskBoardRemoteExecutorStopAuthority::PrePermit(authority),
            TaskBoardRemoteExecutorStopReason::StartEvidenceInvalid,
        )
    }))
}

async fn adopt_remote_start(
    state: &DaemonHttpState,
    db: &AsyncDaemonDb,
    permit: &TaskBoardRemoteExecutorStartIoPermit,
    snapshot: &CodexRunSnapshot,
    workspace: &Path,
) -> Result<Option<TaskBoardRemoteAssignmentRecord>, CliError> {
    let outcome = db
        .adopt_task_board_remote_executor_start_owned(
            permit,
            workspace,
            &snapshot.created_at,
            &state.daemon_epoch,
            &utc_now(),
        )
        .await;
    match outcome {
        Ok(
            TaskBoardRemoteMutationOutcome::Updated(record)
            | TaskBoardRemoteMutationOutcome::Replayed(record),
        ) => Ok(Some(record)),
        Ok(TaskBoardRemoteMutationOutcome::Stale(_)) => {
            settle_failed_adoption(
                state,
                db,
                permit,
                snapshot,
                TaskBoardRemoteExecutorStopReason::StartAdoptionFenceLost,
            )
            .await?;
            Ok(None)
        }
        Err(error) => {
            let adoption_error = error.to_string();
            if let Err(stop_error) = settle_failed_adoption(
                state,
                db,
                permit,
                snapshot,
                TaskBoardRemoteExecutorStopReason::StartAdoptionFailed,
            )
            .await
            {
                return Err(CliErrorKind::workflow_io(format!(
                    "adopt remote worker start: {adoption_error}; stop unadopted worker: {stop_error}"
                ))
                .into());
            }
            Err(error)
        }
    }
}

async fn settle_failed_adoption(
    state: &DaemonHttpState,
    db: &AsyncDaemonDb,
    permit: &TaskBoardRemoteExecutorStartIoPermit,
    snapshot: &CodexRunSnapshot,
    reason: TaskBoardRemoteExecutorStopReason,
) -> Result<(), CliError> {
    claim_and_settle_invalid_remote_run(
        state,
        db,
        &TaskBoardRemoteExecutorStopAuthority::Start(permit.clone()),
        snapshot,
        reason,
    )
    .await
}

async fn mark_running_if_active(
    db: &AsyncDaemonDb,
    record: &TaskBoardRemoteAssignmentRecord,
    snapshot: &CodexRunSnapshot,
) -> Result<(), CliError> {
    if snapshot.status.is_active() {
        let owner = record
            .executor_lifecycle_owner
            .as_ref()
            .ok_or_else(|| concurrent("remote executor assignment has no lifecycle owner"))?;
        let _ = db
            .mark_task_board_remote_assignment_running(&record.assignment_id, owner, &utc_now())
            .await?;
    }
    Ok(())
}
