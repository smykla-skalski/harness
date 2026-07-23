use sqlx::{Sqlite, Transaction, query, query_scalar};

use super::remote_artifacts::{
    TaskBoardRemoteArtifactStoreInput, exact_artifact_replay, insert_artifact_in_tx,
    load_artifact_in_tx, validate_artifact_evidence,
};
use super::remote_assignment_lease::{commit_noop, finish_mutation, require_assignment};
use super::remote_assignment_lifecycle_owner::TaskBoardRemoteExecutorLifecycleOwner;
use super::remote_assignment_model::{
    TaskBoardRemoteAssignmentRecord, TaskBoardRemoteMutationOutcome, canonical_time, concurrent,
    to_i64,
};
use super::remote_start_receipts::durable_start_receipt_run_matches;
use crate::daemon::db::{AsyncDaemonDb, CliError, db_error};
use crate::daemon::task_board_remote_transport::wire::{
    RemoteArtifactEntry, RemoteAssignmentWireState, RemoteStatusRequest, RemoteStatusResponse,
    TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
};
use crate::task_board::{TaskBoardExecutionPhase, TaskBoardRemoteAssignmentState};

pub(crate) const REMOTE_RESULT_ARTIFACT_PATH: &str = "result/attempt.json";
pub(crate) const REMOTE_RESULT_ARTIFACT_MEDIA_TYPE: &str =
    "application/vnd.harness.task-board-result+json";
pub(crate) const REMOTE_IMPLEMENTATION_BUNDLE_PATH: &str = "result/implementation.bundle";
pub(crate) const REMOTE_IMPLEMENTATION_BUNDLE_MEDIA_TYPE: &str = "application/x-git-bundle";

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct TaskBoardRemoteTerminalArtifact {
    pub(crate) entry: RemoteArtifactEntry,
    pub(crate) content: Vec<u8>,
}

impl AsyncDaemonDb {
    pub(crate) async fn complete_task_board_remote_executor_terminal(
        &self,
        owner: &TaskBoardRemoteExecutorLifecycleOwner,
        response: &RemoteStatusResponse,
        artifacts: &[TaskBoardRemoteTerminalArtifact],
    ) -> Result<TaskBoardRemoteMutationOutcome, CliError> {
        let mut transaction = self
            .begin_immediate_transaction("task board remote executor terminal")
            .await?;
        let record = require_assignment(&mut transaction, &owner.assignment_id).await?;
        if terminal_replay_matches(&mut transaction, &record, owner, response, artifacts).await? {
            commit_noop(transaction, "replayed remote executor terminal").await?;
            return Ok(TaskBoardRemoteMutationOutcome::Replayed(record));
        }
        if record.wire_state().is_terminal() {
            commit_noop(transaction, "conflicting remote executor terminal replay").await?;
            return Ok(TaskBoardRemoteMutationOutcome::Stale(record));
        }
        validate_terminal_response(&record, owner, response, artifacts)?;
        if !executor_terminal_authority_matches(&mut transaction, &record, owner, response).await? {
            commit_noop(transaction, "stale remote executor terminal authority").await?;
            return Ok(TaskBoardRemoteMutationOutcome::Stale(record));
        }
        if artifact_count_in_tx(&mut transaction, &record).await? != 0 {
            return Err(concurrent(
                "remote executor terminal has pre-existing artifact evidence",
            ));
        }
        insert_terminal_artifacts(&mut transaction, &record, response, artifacts).await?;
        persist_terminal_status(&mut transaction, &record, owner, response).await?;
        finish_mutation(transaction, &record.assignment_id, "executor terminal").await
    }
}

async fn executor_terminal_authority_matches(
    transaction: &mut Transaction<'_, Sqlite>,
    record: &TaskBoardRemoteAssignmentRecord,
    owner: &TaskBoardRemoteExecutorLifecycleOwner,
    response: &RemoteStatusResponse,
) -> Result<bool, CliError> {
    if !matches!(
        record.state,
        TaskBoardRemoteAssignmentState::Started | TaskBoardRemoteAssignmentState::Running
    ) || record.executor_start_authority_sha256.is_some()
        || record.executor_stop_pending.is_some()
        || record.executor_lifecycle_owner.as_ref() != Some(owner)
        || !is_executor_self_assignment(transaction, record).await?
    {
        return Ok(false);
    }
    let receipt = record
        .start_receipt
        .as_ref()
        .ok_or_else(|| db_error("remote executor terminal has no start receipt"))?;
    if !durable_start_receipt_run_matches(transaction, record, receipt).await? {
        return Ok(false);
    }
    let observed = canonical_time(&response.observed_at, "remote executor terminal time")?;
    let acquired = canonical_time(&owner.acquired_at, "remote lifecycle owner acquisition")?;
    let expires = canonical_time(&owner.expires_at, "remote lifecycle owner expiry")?;
    Ok(observed >= acquired && observed <= expires)
}

fn validate_terminal_response(
    record: &TaskBoardRemoteAssignmentRecord,
    owner: &TaskBoardRemoteExecutorLifecycleOwner,
    response: &RemoteStatusResponse,
    artifacts: &[TaskBoardRemoteTerminalArtifact],
) -> Result<(), CliError> {
    if owner.assignment_id != record.assignment_id || owner.fencing_epoch != record.fencing_epoch {
        return Err(concurrent(
            "remote executor terminal owner generation mismatched",
        ));
    }
    let request = status_request(record)?;
    response
        .validate(&request)
        .map_err(|error| db_error(format!("validate remote executor terminal status: {error}")))?;
    let exact = response.binding == request.binding
        && response.offer_request_sha256 == request.offer_request_sha256
        && response.claimed_at == record.claimed_at
        && response.started_at == record.started_at
        && response.workspace_ref == record.workspace_ref
        && response.lease.as_ref().is_some_and(|lease| {
            record.lease_id.as_deref() == Some(lease.lease_id.as_str())
                && record.lease_expires_at.as_deref() == Some(lease.expires_at.as_str())
        });
    if !exact {
        return Err(concurrent(
            "remote executor terminal status contradicts durable run evidence",
        ));
    }
    validate_phase_artifacts(record.phase, response, artifacts)
}

fn validate_phase_artifacts(
    phase: TaskBoardExecutionPhase,
    response: &RemoteStatusResponse,
    artifacts: &[TaskBoardRemoteTerminalArtifact],
) -> Result<(), CliError> {
    let entries = artifacts
        .iter()
        .map(|artifact| artifact.entry.clone())
        .collect::<Vec<_>>();
    if entries != response.output_artifacts.entries {
        return Err(concurrent(
            "remote executor terminal bytes differ from the sealed manifest",
        ));
    }
    for artifact in artifacts {
        validate_artifact_evidence(
            &response.offer_request_sha256,
            &artifact.entry,
            &artifact.content,
        )?;
    }
    match response.state {
        RemoteAssignmentWireState::Completed => {
            let result = response
                .result
                .as_ref()
                .ok_or_else(|| db_error("completed remote terminal has no typed result"))?;
            let canonical = serde_json::to_vec(result)
                .map_err(|error| db_error(format!("serialize remote terminal result: {error}")))?;
            require_result_artifact(artifacts.first(), &canonical)?;
            match phase {
                TaskBoardExecutionPhase::Implementation => {
                    require_bundle_artifact(artifacts.get(1))?;
                    if artifacts.len() != 2 {
                        return Err(concurrent("implementation terminal artifact set differs"));
                    }
                }
                TaskBoardExecutionPhase::Review | TaskBoardExecutionPhase::Evaluate => {
                    if artifacts.len() != 1 {
                        return Err(concurrent("read-only terminal artifact set differs"));
                    }
                }
                _ => return Err(db_error("remote terminal phase is not executable")),
            }
            Ok(())
        }
        RemoteAssignmentWireState::Failed if artifacts.is_empty() => Ok(()),
        RemoteAssignmentWireState::Failed => Err(concurrent(
            "failed remote terminal cannot publish artifacts",
        )),
        _ => Err(db_error(
            "executor terminal API accepts only completed or failed evidence",
        )),
    }
}

fn require_result_artifact(
    artifact: Option<&TaskBoardRemoteTerminalArtifact>,
    canonical_result: &[u8],
) -> Result<(), CliError> {
    let Some(artifact) = artifact else {
        return Err(concurrent(
            "completed remote terminal has no result envelope",
        ));
    };
    if artifact.entry.relative_path == REMOTE_RESULT_ARTIFACT_PATH
        && artifact.entry.media_type == REMOTE_RESULT_ARTIFACT_MEDIA_TYPE
        && artifact.content == canonical_result
    {
        Ok(())
    } else {
        Err(concurrent(
            "remote terminal result envelope is not canonical",
        ))
    }
}

fn require_bundle_artifact(
    artifact: Option<&TaskBoardRemoteTerminalArtifact>,
) -> Result<(), CliError> {
    let Some(artifact) = artifact else {
        return Err(concurrent(
            "implementation terminal has no immutable git bundle",
        ));
    };
    let git_bundle = artifact.content.starts_with(b"# v2 git bundle\n")
        || artifact.content.starts_with(b"# v3 git bundle\n");
    if artifact.entry.relative_path == REMOTE_IMPLEMENTATION_BUNDLE_PATH
        && artifact.entry.media_type == REMOTE_IMPLEMENTATION_BUNDLE_MEDIA_TYPE
        && git_bundle
    {
        Ok(())
    } else {
        Err(concurrent(
            "implementation terminal git bundle is not canonical",
        ))
    }
}

async fn insert_terminal_artifacts(
    transaction: &mut Transaction<'_, Sqlite>,
    record: &TaskBoardRemoteAssignmentRecord,
    response: &RemoteStatusResponse,
    artifacts: &[TaskBoardRemoteTerminalArtifact],
) -> Result<(), CliError> {
    let offer = record.require_offer()?;
    let lease_id = record
        .lease_id
        .as_deref()
        .ok_or_else(|| db_error("remote executor terminal has no lease"))?;
    let principal = record
        .authenticated_principal
        .as_deref()
        .ok_or_else(|| db_error("remote executor terminal has no principal"))?;
    for artifact in artifacts {
        let input = TaskBoardRemoteArtifactStoreInput {
            binding: &offer.binding,
            lease_id,
            offer_request_sha256: &offer.request_sha256,
            artifact: &artifact.entry,
            content: &artifact.content,
            authenticated_principal: principal,
            stored_at: &response.observed_at,
        };
        insert_artifact_in_tx(transaction, &input).await?;
    }
    Ok(())
}

async fn persist_terminal_status(
    transaction: &mut Transaction<'_, Sqlite>,
    record: &TaskBoardRemoteAssignmentRecord,
    owner: &TaskBoardRemoteExecutorLifecycleOwner,
    response: &RemoteStatusResponse,
) -> Result<(), CliError> {
    let state = match response.state {
        RemoteAssignmentWireState::Completed => "completed",
        RemoteAssignmentWireState::Failed => "failed",
        _ => return Err(db_error("remote executor terminal state is unsupported")),
    };
    let status_json = serde_json::to_string(response)
        .map_err(|error| db_error(format!("serialize remote executor terminal: {error}")))?;
    let result_sha256 = response
        .result
        .as_ref()
        .map(|result| result.result_sha256.as_str());
    let rows = query(
        "UPDATE task_board_remote_assignments SET state = ?2, heartbeat_at = ?3,
         completed_at = ?3, result_json = ?4, status_sha256 = ?5,
         result_sha256 = ?6, error = ?7, updated_at = ?3
         WHERE assignment_id = ?1 AND fencing_epoch = ?8
           AND state IN ('started', 'running')
           AND executor_start_authority_sha256 IS NULL
           AND executor_stop_pending_sha256 IS NULL
           AND executor_start_receipt_sha256 = ?9
           AND claim_receipt_sha256 = ?10
           AND executor_lifecycle_owner_instance_id = ?11
           AND executor_lifecycle_owner_epoch = ?12
           AND executor_lifecycle_owner_sha256 = ?13
           AND lease_id = ?14 AND lease_expires_at = ?15",
    )
    .bind(&record.assignment_id)
    .bind(state)
    .bind(&response.observed_at)
    .bind(status_json)
    .bind(&response.status_sha256)
    .bind(result_sha256)
    .bind(&response.error_code)
    .bind(to_i64(record.fencing_epoch, "terminal fencing epoch")?)
    .bind(
        &record
            .start_receipt
            .as_ref()
            .ok_or_else(|| db_error("remote executor terminal has no start receipt"))?
            .sha256,
    )
    .bind(
        &record
            .claim_receipt
            .as_ref()
            .ok_or_else(|| db_error("remote executor terminal has no claim receipt"))?
            .sha256,
    )
    .bind(&owner.owner_instance_id)
    .bind(to_i64(owner.owner_epoch, "terminal owner epoch")?)
    .bind(&owner.sha256)
    .bind(&record.lease_id)
    .bind(&record.lease_expires_at)
    .execute(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("persist remote executor terminal: {error}")))?
    .rows_affected();
    if rows == 1 {
        Ok(())
    } else {
        Err(concurrent("remote executor terminal lost its owner fence"))
    }
}

async fn terminal_replay_matches(
    transaction: &mut Transaction<'_, Sqlite>,
    record: &TaskBoardRemoteAssignmentRecord,
    owner: &TaskBoardRemoteExecutorLifecycleOwner,
    response: &RemoteStatusResponse,
    artifacts: &[TaskBoardRemoteTerminalArtifact],
) -> Result<bool, CliError> {
    if !record.wire_state().is_terminal()
        || record.executor_lifecycle_owner.as_ref() != Some(owner)
        || record.status_response.as_ref() != Some(response)
        || artifact_count_in_tx(transaction, record).await? != artifacts.len()
    {
        return Ok(false);
    }
    let lease_id = record.lease_id.as_deref().unwrap_or_default();
    let offer_digest = record.request_sha256.as_deref().unwrap_or_default();
    let principal = record
        .authenticated_principal
        .as_deref()
        .unwrap_or_default();
    let Some(offer) = record.offer.as_ref() else {
        return Ok(false);
    };
    for artifact in artifacts {
        let Some(stored) = load_artifact_in_tx(
            transaction,
            &record.assignment_id,
            record.fencing_epoch,
            &artifact.entry.relative_path,
        )
        .await?
        else {
            return Ok(false);
        };
        let input = TaskBoardRemoteArtifactStoreInput {
            binding: &offer.binding,
            lease_id,
            offer_request_sha256: offer_digest,
            artifact: &artifact.entry,
            content: &artifact.content,
            authenticated_principal: principal,
            stored_at: &response.observed_at,
        };
        if !exact_artifact_replay(&stored, &input) {
            return Ok(false);
        }
    }
    Ok(true)
}

async fn artifact_count_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    record: &TaskBoardRemoteAssignmentRecord,
) -> Result<usize, CliError> {
    let count = query_scalar::<_, i64>(
        "SELECT COUNT(*) FROM task_board_remote_artifacts
         WHERE assignment_id = ?1 AND fencing_epoch = ?2",
    )
    .bind(&record.assignment_id)
    .bind(to_i64(record.fencing_epoch, "terminal artifact epoch")?)
    .fetch_one(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("count remote terminal artifacts: {error}")))?;
    usize::try_from(count).map_err(|_| db_error("remote terminal artifact count is invalid"))
}

async fn is_executor_self_assignment(
    transaction: &mut Transaction<'_, Sqlite>,
    record: &TaskBoardRemoteAssignmentRecord,
) -> Result<bool, CliError> {
    query_scalar::<_, bool>(
        "SELECT EXISTS(
           SELECT 1 FROM task_board_execution_hosts
           WHERE host_id = ?1 AND host_role = 'executor_self'
         )",
    )
    .bind(&record.host_id)
    .fetch_one(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("verify executor-self terminal assignment: {error}")))
}

fn status_request(
    record: &TaskBoardRemoteAssignmentRecord,
) -> Result<RemoteStatusRequest, CliError> {
    let offer = record.require_offer()?;
    RemoteStatusRequest {
        schema_version: TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
        binding: offer.binding.clone(),
        lease_id: record
            .lease_id
            .clone()
            .ok_or_else(|| db_error("remote executor terminal has no lease"))?,
        offer_request_sha256: offer.request_sha256.clone(),
        request_sha256: String::new(),
    }
    .seal()
    .map_err(|error| db_error(format!("seal remote executor status request: {error}")))
}

trait TerminalWireState {
    fn is_terminal(&self) -> bool;
}

impl TerminalWireState for RemoteAssignmentWireState {
    fn is_terminal(&self) -> bool {
        matches!(
            self,
            Self::Completed | Self::Failed | Self::Cancelled | Self::Superseded | Self::Unknown
        )
    }
}
