use chrono::{DateTime, Duration, SecondsFormat, Utc};
use sha2::{Digest, Sha256};

use crate::daemon::db::{
    TaskBoardRemoteAssignmentRecord, TaskBoardRemoteHostSelection,
    TaskBoardRemotePriorPhaseBundle,
};
use crate::daemon::task_board_remote_transport::wire::{
    RemoteArtifactEntry, RemoteArtifactFetchRequest, RemoteArtifactManifest,
    RemoteAssignmentWireState, RemoteAttemptBinding, RemoteClaimRequest,
    RemoteCodexLaunchEnvelope, RemoteLeaseRenewRequest, RemoteOfferRequest,
    RemoteSettledRequest, RemoteSourceMaterial, RemoteStatusRequest,
    TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
};
use crate::daemon::task_board_remote_transport::wire_cleanup::RemoteCleanupObservationRequest;
use crate::errors::{CliError, CliErrorKind};
use crate::task_board::{
    TaskBoardAttemptResultArtifact, TaskBoardExecutionAttemptRecord, TaskBoardExecutionPhase,
    TaskBoardImplementationResult, TaskBoardWorkflowExecutionCas, TaskBoardWorkflowExecutionRecord,
    TaskBoardWorkflowKind,
};

use super::super::task_board_read_only_coordinator::requests::remote_codex_attempt_request;

#[path = "requests/source.rs"]
mod source;
pub(super) use source::PreparedRemoteSource;
#[path = "requests/recovery.rs"]
mod recovery;
pub(super) use recovery::{PreparedRemoteReassignment, prepare_source_reassignment};

pub(super) const REMOTE_LEASE_SECONDS: u32 = 60;
const REMOTE_ATTEMPT_DEADLINE_SECONDS: i64 = 3_600;

pub(super) struct PreparedRemoteOffer {
    pub(super) request: RemoteOfferRequest,
    pub(super) source_content: Option<Vec<u8>>,
    pub(super) offered_at: String,
    pub(super) lease_expires_at: String,
    pub(super) deadline_at: String,
}

pub(super) fn prepare_offer(
    execution: &TaskBoardWorkflowExecutionRecord,
    attempt: &TaskBoardExecutionAttemptRecord,
    host: &TaskBoardRemoteHostSelection,
    prepared_source: PreparedRemoteSource,
    now: &str,
) -> Result<Option<PreparedRemoteOffer>, CliError> {
    let phase = execution
        .transition
        .phase
        .filter(|phase| remotely_executable(*phase))
        .ok_or_else(|| invalid("workflow phase is not remotely executable"))?;
    if host.configuration_revision != execution.snapshot.configuration_revision {
        return Ok(None);
    }
    let PreparedRemoteSource {
        source,
        artifacts,
        content,
    } = prepared_source;
    let offered_at = canonical_time(now, "remote offer time")?;
    let lease_expires_at = offered_at + Duration::seconds(i64::from(REMOTE_LEASE_SECONDS));
    let deadline_at = offered_at + Duration::seconds(REMOTE_ATTEMPT_DEADLINE_SECONDS);
    let binding = binding(execution, attempt, host, phase, source.repository())?;
    let launch = remote_codex_attempt_request(execution, attempt)?;
    let request = RemoteOfferRequest {
        schema_version: TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
        binding,
        lease_seconds: REMOTE_LEASE_SECONDS,
        deadline_at: canonical( deadline_at),
        launch: RemoteCodexLaunchEnvelope::from_codex_request("codex", &launch)
            .map_err(|error| invalid(format!("freeze remote Codex launch: {error}")))?,
        source,
        artifacts,
        request_sha256: String::new(),
    }
    .seal()
    .map_err(|error| invalid(format!("seal remote offer: {error}")))?;
    Ok(Some(PreparedRemoteOffer {
        request,
        source_content: content,
        offered_at: canonical(offered_at),
        lease_expires_at: canonical(lease_expires_at),
        deadline_at: canonical(deadline_at),
    }))
}

pub(super) fn prepare_source(
    execution: &TaskBoardWorkflowExecutionRecord,
    phase: TaskBoardExecutionPhase,
    prior_bundle: Option<&TaskBoardRemotePriorPhaseBundle>,
) -> Result<Option<PreparedRemoteSource>, CliError> {
    if requires_prior_bundle(execution, phase) {
        let Some(prior_bundle) = prior_bundle else {
            return Ok(None);
        };
        let implementation = prior_implementation(execution, phase)?;
        let source = RemoteSourceMaterial::prior_phase_bundle(
            &prior_bundle.repository,
            &implementation.base_head_revision,
            &implementation.head_revision,
            prior_bundle.artifact.clone(),
        );
        return Ok(Some(PreparedRemoteSource {
            source,
            artifacts: RemoteArtifactManifest {
                entries: vec![prior_bundle.artifact.clone()],
            },
            content: Some(prior_bundle.content.clone()),
        }));
    }
    let revision = initial_revision(execution, phase)?;
    if initial_snapshot_required(execution, phase) {
        return Ok(None);
    }
    Ok(Some(PreparedRemoteSource {
        source: initial_repository_source(execution, revision)?,
        artifacts: RemoteArtifactManifest::default(),
        content: None,
    }))
}

pub(super) fn initial_snapshot_identity(
    execution: &TaskBoardWorkflowExecutionRecord,
    phase: TaskBoardExecutionPhase,
) -> Result<Option<(&str, &str, &str)>, CliError> {
    if !initial_snapshot_required(execution, phase) {
        return Ok(None);
    }
    let repository = execution
        .snapshot
        .execution_repository
        .as_deref()
        .ok_or_else(|| invalid("remote workflow has no execution repository"))?;
    let revision = initial_revision(execution, phase)?;
    let worktree = execution
        .snapshot
        .read_only_run_context
        .as_ref()
        .map(|context| context.worktree.as_str())
        .ok_or_else(|| invalid("remote workflow has no frozen controller worktree"))?;
    Ok(Some((worktree, repository, revision)))
}

pub(super) fn claim_request(
    assignment: &TaskBoardRemoteAssignmentRecord,
) -> Result<RemoteClaimRequest, CliError> {
    let offer = assignment.require_offer()?;
    RemoteClaimRequest {
        schema_version: TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
        binding: offer.binding.clone(),
        lease_id: lease_id(assignment)?.to_owned(),
        offer_request_sha256: offer.request_sha256.clone(),
        request_sha256: String::new(),
    }
    .seal()
    .map_err(|error| invalid(format!("seal remote claim: {error}")))
}

pub(super) fn status_request(
    assignment: &TaskBoardRemoteAssignmentRecord,
) -> Result<RemoteStatusRequest, CliError> {
    let offer = assignment.require_offer()?;
    RemoteStatusRequest {
        schema_version: TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
        binding: offer.binding.clone(),
        lease_id: lease_id(assignment)?.to_owned(),
        offer_request_sha256: offer.request_sha256.clone(),
        request_sha256: String::new(),
    }
    .seal()
    .map_err(|error| invalid(format!("seal remote status request: {error}")))
}

pub(super) fn renewal_request(
    assignment: &TaskBoardRemoteAssignmentRecord,
) -> Result<RemoteLeaseRenewRequest, CliError> {
    let offer = assignment.require_offer()?;
    RemoteLeaseRenewRequest {
        schema_version: TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
        binding: offer.binding.clone(),
        lease_id: lease_id(assignment)?.to_owned(),
        offer_request_sha256: offer.request_sha256.clone(),
        extend_seconds: offer.lease_seconds,
        request_sha256: String::new(),
    }
    .seal()
    .map_err(|error| invalid(format!("seal remote lease renewal: {error}")))
}

pub(super) fn artifact_request(
    assignment: &TaskBoardRemoteAssignmentRecord,
    artifact: &RemoteArtifactEntry,
) -> Result<RemoteArtifactFetchRequest, CliError> {
    let offer = assignment.require_offer()?;
    RemoteArtifactFetchRequest {
        schema_version: TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
        binding: offer.binding.clone(),
        lease_id: lease_id(assignment)?.to_owned(),
        offer_request_sha256: offer.request_sha256.clone(),
        relative_path: artifact.relative_path.clone(),
        expected_sha256: artifact.sha256.clone(),
        request_sha256: String::new(),
    }
    .seal()
    .map_err(|error| invalid(format!("seal remote artifact request: {error}")))
}

pub(super) fn settlement_request(
    assignment: &TaskBoardRemoteAssignmentRecord,
) -> Result<RemoteSettledRequest, CliError> {
    let offer = assignment.require_offer()?;
    let terminal_state = assignment.wire_state();
    let result_sha256 = (terminal_state == RemoteAssignmentWireState::Completed)
        .then(|| assignment.result_sha256.clone())
        .flatten()
        .ok_or_else(|| invalid("completed remote assignment has no result digest"))
        .map(Some)
        .or_else(|error| {
            if terminal_state == RemoteAssignmentWireState::Completed {
                Err(error)
            } else {
                Ok(None)
            }
        })?;
    RemoteSettledRequest {
        schema_version: TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
        binding: offer.binding.clone(),
        lease_id: lease_id(assignment)?.to_owned(),
        offer_request_sha256: offer.request_sha256.clone(),
        terminal_state,
        result_sha256,
        request_sha256: String::new(),
    }
    .seal()
    .map_err(|error| invalid(format!("seal remote settlement request: {error}")))
}

pub(super) fn cleanup_observation_request(
    settlement: &crate::daemon::db::TaskBoardRemoteSettlementReceipt,
) -> Result<RemoteCleanupObservationRequest, CliError> {
    RemoteCleanupObservationRequest::for_settlement(&settlement.request)
        .map_err(|error| invalid(format!("seal remote cleanup observation: {error}")))
}

pub(super) fn renewal_is_due(
    assignment: &TaskBoardRemoteAssignmentRecord,
    now: &str,
) -> Result<bool, CliError> {
    let now = canonical_time(now, "remote controller time")?;
    let expires = assignment
        .lease_expires_at
        .as_deref()
        .ok_or_else(|| invalid("active remote assignment has no lease expiry"))?;
    let expires = canonical_time(expires, "remote lease expiry")?;
    Ok(expires <= now + Duration::seconds(i64::from(REMOTE_LEASE_SECONDS / 2)))
}

fn binding(
    execution: &TaskBoardWorkflowExecutionRecord,
    attempt: &TaskBoardExecutionAttemptRecord,
    host: &TaskBoardRemoteHostSelection,
    phase: TaskBoardExecutionPhase,
    source_repository: &str,
) -> Result<RemoteAttemptBinding, CliError> {
    let (base_revision, expected_head_revision) = revision_binding(execution, phase)?;
    let fencing_epoch = execution
        .ownership
        .fencing_epoch
        .checked_add(1)
        .ok_or_else(|| invalid("remote assignment fencing epoch overflow"))?;
    Ok(RemoteAttemptBinding {
        assignment_id: deterministic_assignment_id(
            execution,
            attempt,
            &host.config.host_id,
            fencing_epoch,
        ),
        execution_id: execution.execution_id.clone(),
        phase,
        workflow_kind: execution.snapshot.workflow_kind,
        action_key: attempt.action_key.clone(),
        attempt: attempt.attempt,
        idempotency_key: attempt.idempotency_key.clone(),
        host_id: host.config.host_id.clone(),
        host_instance_id: host.advertisement.host_instance_id.clone(),
        fencing_epoch,
        configuration_revision: execution.snapshot.configuration_revision,
        execution_record_sha256: TaskBoardWorkflowExecutionCas::from(execution).record_sha256,
        repository: source_repository.into(),
        base_revision,
        expected_head_revision,
    })
}

fn revision_binding(
    execution: &TaskBoardWorkflowExecutionRecord,
    phase: TaskBoardExecutionPhase,
) -> Result<(String, Option<String>), CliError> {
    match phase {
        TaskBoardExecutionPhase::Implementation => {
            Ok((implementation_base(execution)?.to_owned(), None))
        }
        TaskBoardExecutionPhase::Review | TaskBoardExecutionPhase::Evaluate => {
            let head = execution
                .transition
                .exact_head_revision
                .clone()
                .ok_or_else(|| invalid("remote read-only phase has no exact head"))?;
            Ok((head.clone(), Some(head)))
        }
        _ => Err(invalid("workflow phase is not remotely executable")),
    }
}

fn initial_repository_source(
    execution: &TaskBoardWorkflowExecutionRecord,
    revision: &str,
) -> Result<RemoteSourceMaterial, CliError> {
    let head = execution
        .transition
        .pull_request
        .as_ref()
        .and_then(|pull_request| pull_request.head.as_ref())
        .filter(|_| {
            matches!(
                execution.snapshot.workflow_kind,
                TaskBoardWorkflowKind::PrFix | TaskBoardWorkflowKind::PrReview
            )
        });
    if let Some(head) = head {
        if head.revision != revision {
            return Err(invalid("frozen pull-request source revision changed"));
        }
        return Ok(RemoteSourceMaterial::repository_branch(
            &head.repository,
            &head.branch,
            revision,
        ));
    }
    let repository = execution
        .snapshot
        .execution_repository
        .as_deref()
        .ok_or_else(|| invalid("remote workflow has no execution repository"))?;
    Ok(RemoteSourceMaterial::repository_revision(repository, revision))
}

fn initial_snapshot_required(
    execution: &TaskBoardWorkflowExecutionRecord,
    phase: TaskBoardExecutionPhase,
) -> bool {
    execution.snapshot.workflow_kind == TaskBoardWorkflowKind::DefaultTask
        && phase == TaskBoardExecutionPhase::Implementation
        && execution.artifacts.current_revision_cycle == 1
}

fn initial_revision<'a>(
    execution: &'a TaskBoardWorkflowExecutionRecord,
    phase: TaskBoardExecutionPhase,
) -> Result<&'a str, CliError> {
    match phase {
        TaskBoardExecutionPhase::Implementation => implementation_base(execution),
        TaskBoardExecutionPhase::Review | TaskBoardExecutionPhase::Evaluate => execution
            .transition
            .exact_head_revision
            .as_deref()
            .ok_or_else(|| invalid("remote phase has no exact source revision")),
        _ => Err(invalid("workflow phase is not remotely executable")),
    }
}

fn implementation_base(execution: &TaskBoardWorkflowExecutionRecord) -> Result<&str, CliError> {
    let cycle = execution.artifacts.current_revision_cycle;
    if cycle > 1 {
        return execution
            .artifacts
            .review_cycles
            .iter()
            .find(|review| review.revision_cycle == cycle - 1)
            .map(|review| review.head_revision.as_str())
            .ok_or_else(|| invalid("remote implementation has no prior reviewed base"));
    }
    if execution.snapshot.workflow_kind == TaskBoardWorkflowKind::PrFix {
        return execution
            .transition
            .pull_request
            .as_ref()
            .and_then(|pull_request| pull_request.head.as_ref())
            .map(|head| head.revision.as_str())
            .ok_or_else(|| invalid("remote PR fix has no frozen head identity"));
    }
    execution
        .transition
        .exact_head_revision
        .as_deref()
        .ok_or_else(|| invalid("remote implementation has no frozen base"))
}

fn prior_implementation(
    execution: &TaskBoardWorkflowExecutionRecord,
    phase: TaskBoardExecutionPhase,
) -> Result<&TaskBoardImplementationResult, CliError> {
    let cycle = match phase {
        TaskBoardExecutionPhase::Implementation => execution
            .artifacts
            .current_revision_cycle
            .checked_sub(1),
        TaskBoardExecutionPhase::Review | TaskBoardExecutionPhase::Evaluate => {
            Some(execution.artifacts.current_revision_cycle)
        }
        _ => None,
    }
    .ok_or_else(|| invalid("remote phase has no prior implementation cycle"))?;
    execution
        .attempts
        .iter()
        .find_map(|attempt| match attempt.artifact.as_ref() {
            Some(TaskBoardAttemptResultArtifact::Implementation(result))
                if result.revision_cycle == cycle =>
            {
                Some(result)
            }
            _ => None,
        })
        .ok_or_else(|| invalid("remote phase has no prior implementation result"))
}

pub(super) fn requires_prior_bundle(
    execution: &TaskBoardWorkflowExecutionRecord,
    phase: TaskBoardExecutionPhase,
) -> bool {
    let write = matches!(
        execution.snapshot.workflow_kind,
        TaskBoardWorkflowKind::DefaultTask | TaskBoardWorkflowKind::PrFix
    );
    match phase {
        TaskBoardExecutionPhase::Implementation => execution.artifacts.current_revision_cycle > 1,
        TaskBoardExecutionPhase::Review | TaskBoardExecutionPhase::Evaluate => write,
        _ => false,
    }
}

fn deterministic_assignment_id(
    execution: &TaskBoardWorkflowExecutionRecord,
    attempt: &TaskBoardExecutionAttemptRecord,
    host_id: &str,
    fencing_epoch: u64,
) -> String {
    let mut digest = Sha256::new();
    digest.update(b"harness:task-board:remote-assignment:v1\0");
    for value in [
        execution.execution_id.as_bytes(),
        attempt.action_key.as_bytes(),
        attempt.idempotency_key.as_bytes(),
        host_id.as_bytes(),
    ] {
        digest.update((value.len() as u64).to_be_bytes());
        digest.update(value);
    }
    digest.update(attempt.attempt.to_be_bytes());
    digest.update(fencing_epoch.to_be_bytes());
    format!("remote-{}", hex::encode(digest.finalize()))
}

fn lease_id(assignment: &TaskBoardRemoteAssignmentRecord) -> Result<&str, CliError> {
    assignment
        .lease_id
        .as_deref()
        .ok_or_else(|| invalid("remote assignment has no accepted lease"))
}

const fn remotely_executable(phase: TaskBoardExecutionPhase) -> bool {
    matches!(
        phase,
        TaskBoardExecutionPhase::Implementation
            | TaskBoardExecutionPhase::Review
            | TaskBoardExecutionPhase::Evaluate
    )
}

fn canonical_time(value: &str, field: &str) -> Result<DateTime<Utc>, CliError> {
    let parsed = DateTime::parse_from_rfc3339(value)
        .map(DateTime::<Utc>::from)
        .map_err(|error| invalid(format!("invalid {field}: {error}")))?;
    if canonical(parsed) == value {
        Ok(parsed)
    } else {
        Err(invalid(format!("{field} is not canonical")))
    }
}

fn canonical(value: DateTime<Utc>) -> String {
    value.to_rfc3339_opts(SecondsFormat::AutoSi, true)
}

fn invalid(detail: impl Into<String>) -> CliError {
    CliErrorKind::invalid_transition(detail.into()).into()
}
