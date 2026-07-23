use std::path::Path;

use sha2::{Digest, Sha256};
use tokio::task::spawn_blocking;

use crate::daemon::db::{
    AsyncDaemonDb, REMOTE_IMPLEMENTATION_BUNDLE_MEDIA_TYPE, REMOTE_IMPLEMENTATION_BUNDLE_PATH,
    REMOTE_RESULT_ARTIFACT_MEDIA_TYPE, REMOTE_RESULT_ARTIFACT_PATH,
    TaskBoardRemoteAssignmentRecord, TaskBoardRemoteMutationOutcome,
    TaskBoardRemoteTerminalArtifact,
};
use crate::daemon::protocol::{CodexRunSnapshot, CodexRunStatus};
use crate::daemon::task_board_remote_transport::wire::{
    RemoteArtifactEntry, RemoteArtifactManifest, RemoteAssignmentWireState, RemoteLease,
    RemoteStatusResponse, RemoteTypedResult, TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
};
use crate::errors::{CliError, CliErrorKind};
use crate::git::bundle_export::GitBundleExportPlan;
use crate::task_board::{
    TaskBoardExecutionPhase, TaskBoardFailureClass, TaskBoardLocalAttemptResult,
};
use crate::workspace::utc_now;

const MAX_TERMINAL_ARTIFACT_BYTES: u64 = 32 * 1024 * 1024;

enum TerminalEvidence {
    Completed {
        result: Box<RemoteTypedResult>,
        artifacts: Vec<TaskBoardRemoteTerminalArtifact>,
    },
    Failed {
        error_code: &'static str,
        failure_class: TaskBoardFailureClass,
    },
}

pub(super) async fn persist_terminal_snapshot(
    db: &AsyncDaemonDb,
    owner_instance_id: &str,
    record: &TaskBoardRemoteAssignmentRecord,
    snapshot: &CodexRunSnapshot,
    workspace: &Path,
) -> Result<(), CliError> {
    let evidence = terminal_evidence(record, snapshot, workspace).await?;
    let owner_at = utc_now();
    let Some(claim) = db
        .claim_task_board_remote_executor_lifecycle_owner_with_settings(
            &record.assignment_id,
            owner_instance_id,
            &owner_at,
        )
        .await?
    else {
        return Err(concurrent("remote terminal lost its lifecycle owner"));
    };
    if claim.stop_only {
        return Err(concurrent(
            "remote terminal requires stop-only settings reconciliation",
        ));
    }
    let owner = claim.owner;
    let current = db
        .task_board_remote_assignment(&record.assignment_id)
        .await?
        .ok_or_else(|| concurrent("remote terminal assignment disappeared"))?;
    if current.fencing_epoch != record.fencing_epoch
        || current.offer.as_ref() != record.offer.as_ref()
    {
        return Err(concurrent("remote terminal assignment generation changed"));
    }
    let response = terminal_response(&current, &evidence, &utc_now())?;
    let artifacts = match &evidence {
        TerminalEvidence::Completed { artifacts, .. } => artifacts.as_slice(),
        TerminalEvidence::Failed { .. } => &[],
    };
    match db
        .complete_task_board_remote_executor_terminal(&owner, &response, artifacts)
        .await?
    {
        TaskBoardRemoteMutationOutcome::Updated(_)
        | TaskBoardRemoteMutationOutcome::Replayed(_) => Ok(()),
        TaskBoardRemoteMutationOutcome::Stale(_) => Err(concurrent(
            "remote terminal persistence lost its exact owner",
        )),
    }
}

async fn terminal_evidence(
    record: &TaskBoardRemoteAssignmentRecord,
    snapshot: &CodexRunSnapshot,
    workspace: &Path,
) -> Result<TerminalEvidence, CliError> {
    match snapshot.status {
        CodexRunStatus::Completed => match completed_evidence(record, snapshot, workspace).await {
            Ok(evidence) => Ok(evidence),
            Err(error) if error.code() == "KSRCLI084" => {
                tracing::warn!(%error, assignment_id = %record.assignment_id, "remote executor produced invalid terminal evidence");
                Ok(TerminalEvidence::Failed {
                    error_code: "executor_output_invalid",
                    failure_class: TaskBoardFailureClass::Permanent,
                })
            }
            Err(error) => Err(error),
        },
        CodexRunStatus::Failed => Ok(TerminalEvidence::Failed {
            error_code: "executor_runtime_failed",
            failure_class: TaskBoardFailureClass::Transient,
        }),
        CodexRunStatus::Cancelled => Ok(TerminalEvidence::Failed {
            error_code: "executor_runtime_cancelled",
            failure_class: TaskBoardFailureClass::Permanent,
        }),
        _ => Err(invalid_transition(
            "remote terminal persistence requires a terminal Codex snapshot",
        )),
    }
}

async fn completed_evidence(
    record: &TaskBoardRemoteAssignmentRecord,
    snapshot: &CodexRunSnapshot,
    workspace: &Path,
) -> Result<TerminalEvidence, CliError> {
    let offer = record.require_offer()?;
    let message = snapshot
        .final_message
        .as_deref()
        .ok_or_else(|| invalid_transition("completed remote Codex run has no final message"))?;
    let result = serde_json::from_str::<TaskBoardLocalAttemptResult>(message.trim())
        .map_err(|error| invalid_transition(format!("parse remote attempt result: {error}")))?;
    let typed = RemoteTypedResult::seal(result, offer.request_sha256.clone())
        .map_err(|error| invalid_transition(format!("seal remote attempt result: {error}")))?;
    typed
        .validate(&offer.binding, &offer.request_sha256)
        .map_err(|error| invalid_transition(format!("validate remote attempt result: {error}")))?;
    let result_bytes = serde_json::to_vec(&typed)
        .map_err(|error| invalid_transition(format!("serialize remote attempt result: {error}")))?;
    let mut artifacts = vec![terminal_artifact(
        REMOTE_RESULT_ARTIFACT_PATH,
        REMOTE_RESULT_ARTIFACT_MEDIA_TYPE,
        result_bytes,
    )?];
    if record.phase == TaskBoardExecutionPhase::Implementation {
        artifacts.push(implementation_bundle(record, &typed, workspace).await?);
    }
    Ok(TerminalEvidence::Completed {
        result: Box::new(typed),
        artifacts,
    })
}

async fn implementation_bundle(
    record: &TaskBoardRemoteAssignmentRecord,
    typed: &RemoteTypedResult,
    workspace: &Path,
) -> Result<TaskBoardRemoteTerminalArtifact, CliError> {
    let offer = record.require_offer()?;
    let plan = GitBundleExportPlan::for_result(
        workspace,
        offer.binding.base_revision.clone(),
        typed.result.exact_head_revision.clone(),
    )
    .map_err(|error| {
        invalid_transition(format!("validate remote implementation result: {error}"))
    })?;
    let bundle = spawn_blocking(move || plan.export(MAX_TERMINAL_ARTIFACT_BYTES))
        .await
        .map_err(|error| workflow_io(format!("join remote Git bundle export: {error}")))?
        .map_err(|error| workflow_io(format!("export remote implementation result: {error}")))?;
    terminal_artifact(
        REMOTE_IMPLEMENTATION_BUNDLE_PATH,
        REMOTE_IMPLEMENTATION_BUNDLE_MEDIA_TYPE,
        bundle.bytes,
    )
}

fn terminal_artifact(
    relative_path: &str,
    media_type: &str,
    content: Vec<u8>,
) -> Result<TaskBoardRemoteTerminalArtifact, CliError> {
    let size_bytes = u64::try_from(content.len())
        .map_err(|_| invalid_transition("remote terminal artifact length overflowed"))?;
    if size_bytes == 0 || size_bytes > MAX_TERMINAL_ARTIFACT_BYTES {
        return Err(invalid_transition(
            "remote terminal artifact exceeds its bounded contract",
        ));
    }
    Ok(TaskBoardRemoteTerminalArtifact {
        entry: RemoteArtifactEntry {
            relative_path: relative_path.into(),
            sha256: hex::encode(Sha256::digest(&content)),
            size_bytes,
            media_type: media_type.into(),
        },
        content,
    })
}

fn terminal_response(
    record: &TaskBoardRemoteAssignmentRecord,
    evidence: &TerminalEvidence,
    observed_at: &str,
) -> Result<RemoteStatusResponse, CliError> {
    let offer = record.require_offer()?;
    let (state, result, entries, error_code, failure_class) = match evidence {
        TerminalEvidence::Completed { result, artifacts } => (
            RemoteAssignmentWireState::Completed,
            Some((**result).clone()),
            artifacts
                .iter()
                .map(|artifact| artifact.entry.clone())
                .collect(),
            None,
            None,
        ),
        TerminalEvidence::Failed {
            error_code,
            failure_class,
        } => (
            RemoteAssignmentWireState::Failed,
            None,
            Vec::new(),
            Some((*error_code).into()),
            Some(*failure_class),
        ),
    };
    RemoteStatusResponse {
        schema_version: TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
        binding: offer.binding.clone(),
        state,
        offer_request_sha256: offer.request_sha256.clone(),
        status_sha256: String::new(),
        lease: Some(RemoteLease {
            lease_id: required(record.lease_id.as_deref(), "lease")?,
            expires_at: required(record.lease_expires_at.as_deref(), "lease expiry")?,
        }),
        result,
        output_artifacts: RemoteArtifactManifest { entries },
        claimed_at: record.claimed_at.clone(),
        started_at: record.started_at.clone(),
        workspace_ref: record.workspace_ref.clone(),
        error_code,
        failure_class,
        observed_at: observed_at.into(),
    }
    .seal()
    .map_err(|error| invalid_transition(format!("seal remote terminal status: {error}")))
}

fn required(value: Option<&str>, label: &str) -> Result<String, CliError> {
    value
        .map(str::to_owned)
        .ok_or_else(|| invalid_transition(format!("remote terminal has no {label}")))
}

fn concurrent(message: &'static str) -> CliError {
    CliErrorKind::concurrent_modification(message).into()
}

fn invalid_transition(message: impl Into<String>) -> CliError {
    CliErrorKind::invalid_transition(message.into()).into()
}

fn workflow_io(message: impl Into<String>) -> CliError {
    CliErrorKind::workflow_io(message.into()).into()
}

#[cfg(test)]
#[path = "terminal_tests.rs"]
mod tests;
