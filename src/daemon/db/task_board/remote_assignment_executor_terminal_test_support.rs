use sha2::{Digest, Sha256};

use super::remote_assignment_executor_terminal::{
    REMOTE_IMPLEMENTATION_BUNDLE_MEDIA_TYPE, REMOTE_IMPLEMENTATION_BUNDLE_PATH,
    REMOTE_RESULT_ARTIFACT_MEDIA_TYPE, REMOTE_RESULT_ARTIFACT_PATH,
    TaskBoardRemoteTerminalArtifact,
};
use super::remote_assignment_test_support::*;
use super::{
    TaskBoardRemoteAssignmentRecord, TaskBoardRemoteExecutorLifecycleOwner,
    TaskBoardRemoteMutationOutcome,
};
use crate::daemon::task_board_remote_transport::wire::{
    RemoteArtifactEntry, RemoteArtifactManifest, RemoteAssignmentWireState, RemoteLease,
    RemoteStatusResponse, RemoteTypedResult, TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
    test_codex_launch,
};
use crate::task_board::{
    TASK_BOARD_LOCAL_ATTEMPT_RESULT_SCHEMA_VERSION, TaskBoardAttemptResultArtifact,
    TaskBoardEvaluationResult, TaskBoardExecutionPhase, TaskBoardFailureClass,
    TaskBoardImplementationResult, TaskBoardLocalAttemptResult,
    TaskBoardPhaseCapabilityProfile, TaskBoardPhaseVerdict, TaskBoardRemoteAssignmentState,
    TaskBoardReviewResult, TaskBoardReviewerOutcome, TaskBoardWorkflowKind,
};

pub(super) const TERMINAL_AT: &str = "2026-07-19T10:00:30Z";
const RESULT_HEAD: &str = "2222222222222222222222222222222222222222";

pub(super) struct TerminalExecutor {
    pub(super) fixture: ExecutorFixture,
    pub(super) record: TaskBoardRemoteAssignmentRecord,
    pub(super) owner: TaskBoardRemoteExecutorLifecycleOwner,
}

pub(super) async fn terminal_executor(phase: TaskBoardExecutionPhase) -> TerminalExecutor {
    let mut fixture = executor_fixture(1).await;
    match phase {
        TaskBoardExecutionPhase::Implementation => enable_implementation(&mut fixture).await,
        TaskBoardExecutionPhase::Evaluate => enable_evaluate(&mut fixture).await,
        _ => {}
    }
    let accepted = accept_executor(&fixture, &fixture.request).await;
    assert!(matches!(
        fixture
            .db
            .claim_task_board_remote_assignment(
                &claim_request(&fixture.request, &accepted),
                PRINCIPAL,
                CLAIMED_AT,
            )
            .await
            .expect("claim executor assignment"),
        TaskBoardRemoteMutationOutcome::Updated(_)
    ));
    assert!(matches!(
        authorize_and_start_executor(&fixture, &accepted.assignment_id, STARTED_AT).await,
        TaskBoardRemoteMutationOutcome::Updated(_)
    ));
    let record = fixture
        .db
        .task_board_remote_assignment(&accepted.assignment_id)
        .await
        .expect("load started executor assignment")
        .expect("started executor assignment");
    assert_eq!(record.state, TaskBoardRemoteAssignmentState::Started);
    let owner = record
        .executor_lifecycle_owner
        .clone()
        .expect("started lifecycle owner");
    TerminalExecutor {
        fixture,
        record,
        owner,
    }
}

pub(super) fn completed_evidence(
    record: &TaskBoardRemoteAssignmentRecord,
) -> (RemoteStatusResponse, Vec<TaskBoardRemoteTerminalArtifact>) {
    let offer = record.require_offer().expect("strict offer");
    let typed = RemoteTypedResult::seal(
        result_for_phase(record.phase, &offer.binding),
        offer.request_sha256.clone(),
    )
    .expect("seal typed terminal result");
    let result_bytes = serde_json::to_vec(&typed).expect("serialize typed terminal result");
    let mut artifacts = vec![terminal_artifact(
        REMOTE_RESULT_ARTIFACT_PATH,
        REMOTE_RESULT_ARTIFACT_MEDIA_TYPE,
        result_bytes,
    )];
    if record.phase == TaskBoardExecutionPhase::Implementation {
        artifacts.push(terminal_artifact(
            REMOTE_IMPLEMENTATION_BUNDLE_PATH,
            REMOTE_IMPLEMENTATION_BUNDLE_MEDIA_TYPE,
            b"# v2 git bundle\n2222222222222222222222222222222222222222 HEAD\n\npack".to_vec(),
        ));
    }
    let response = terminal_response(
        record,
        RemoteAssignmentWireState::Completed,
        Some(typed),
        artifacts.iter().map(|value| value.entry.clone()).collect(),
        None,
        None,
    );
    (response, artifacts)
}

pub(super) fn failed_evidence(record: &TaskBoardRemoteAssignmentRecord) -> RemoteStatusResponse {
    terminal_response(
        record,
        RemoteAssignmentWireState::Failed,
        None,
        Vec::new(),
        Some("executor_output_invalid".into()),
        Some(TaskBoardFailureClass::Permanent),
    )
}

pub(super) fn terminal_artifact(
    path: &str,
    media_type: &str,
    content: Vec<u8>,
) -> TaskBoardRemoteTerminalArtifact {
    TaskBoardRemoteTerminalArtifact {
        entry: RemoteArtifactEntry {
            relative_path: path.into(),
            sha256: hex::encode(Sha256::digest(&content)),
            size_bytes: u64::try_from(content.len()).expect("artifact length"),
            media_type: media_type.into(),
        },
        content,
    }
}

fn terminal_response(
    record: &TaskBoardRemoteAssignmentRecord,
    state: RemoteAssignmentWireState,
    result: Option<RemoteTypedResult>,
    entries: Vec<RemoteArtifactEntry>,
    error_code: Option<String>,
    failure_class: Option<TaskBoardFailureClass>,
) -> RemoteStatusResponse {
    let offer = record.require_offer().expect("strict offer");
    RemoteStatusResponse {
        schema_version: TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
        binding: offer.binding.clone(),
        state,
        offer_request_sha256: offer.request_sha256.clone(),
        status_sha256: String::new(),
        lease: Some(RemoteLease {
            lease_id: record.lease_id.clone().expect("terminal lease"),
            expires_at: record
                .lease_expires_at
                .clone()
                .expect("terminal lease expiry"),
        }),
        result,
        output_artifacts: RemoteArtifactManifest { entries },
        claimed_at: record.claimed_at.clone(),
        started_at: record.started_at.clone(),
        workspace_ref: record.workspace_ref.clone(),
        error_code,
        failure_class,
        observed_at: TERMINAL_AT.into(),
    }
    .seal()
    .expect("seal terminal response")
}

fn result_for_phase(
    phase: TaskBoardExecutionPhase,
    binding: &crate::daemon::task_board_remote_transport::wire::RemoteAttemptBinding,
) -> TaskBoardLocalAttemptResult {
    let (head, artifact) = match phase {
        TaskBoardExecutionPhase::Implementation => (
            RESULT_HEAD,
            TaskBoardAttemptResultArtifact::Implementation(TaskBoardImplementationResult {
                revision_cycle: 1,
                base_head_revision: SOURCE_REVISION.into(),
                head_revision: RESULT_HEAD.into(),
                summary: "implemented remotely".into(),
                evidence: Vec::new(),
            }),
        ),
        TaskBoardExecutionPhase::Review => (
            SOURCE_REVISION,
            TaskBoardAttemptResultArtifact::Review(TaskBoardReviewerOutcome {
                profile_id: "reviewer".into(),
                result: TaskBoardReviewResult {
                    verdict: TaskBoardPhaseVerdict::Pass,
                    head_revision: SOURCE_REVISION.into(),
                    summary: "reviewed remotely".into(),
                    findings: Vec::new(),
                },
            }),
        ),
        TaskBoardExecutionPhase::Evaluate => (
            SOURCE_REVISION,
            TaskBoardAttemptResultArtifact::Evaluation(TaskBoardEvaluationResult {
                verdict: TaskBoardPhaseVerdict::Pass,
                summary: "evaluated remotely".into(),
                evidence: Vec::new(),
                head_revision: None,
                revision_cycle: None,
            }),
        ),
        _ => panic!("unsupported terminal test phase"),
    };
    TaskBoardLocalAttemptResult {
        schema_version: TASK_BOARD_LOCAL_ATTEMPT_RESULT_SCHEMA_VERSION,
        execution_id: binding.execution_id.clone(),
        action_key: binding.action_key.clone(),
        attempt: binding.attempt,
        idempotency_key: binding.idempotency_key.clone(),
        exact_head_revision: head.into(),
        artifact,
    }
}

async fn enable_implementation(fixture: &mut ExecutorFixture) {
    let mut settings = fixture
        .db
        .task_board_orchestrator_settings()
        .await
        .expect("load executor settings");
    settings.local_execution_host.capabilities =
        vec![TaskBoardPhaseCapabilityProfile::ImplementationWrite];
    fixture
        .db
        .replace_task_board_orchestrator_settings(&settings)
        .await
        .expect("enable implementation capability");
    fixture.request.binding.phase = TaskBoardExecutionPhase::Implementation;
    fixture.request.binding.workflow_kind = TaskBoardWorkflowKind::DefaultTask;
    fixture.request.binding.action_key = "implementation:1".into();
    fixture.request.binding.expected_head_revision = None;
    // The launch must match the rebound implementation phase and action key.
    fixture.request.launch = test_codex_launch(
        TaskBoardExecutionPhase::Implementation,
        &fixture.request.binding.execution_id,
        "implementation:1",
        "Implement the frozen task plan.",
    );
    fixture.request = fixture
        .request
        .clone()
        .seal()
        .expect("reseal implementation offer");
}

async fn enable_evaluate(fixture: &mut ExecutorFixture) {
    let mut settings = fixture
        .db
        .task_board_orchestrator_settings()
        .await
        .expect("load executor settings");
    settings.local_execution_host.capabilities =
        vec![TaskBoardPhaseCapabilityProfile::EvaluateReadOnly];
    fixture
        .db
        .replace_task_board_orchestrator_settings(&settings)
        .await
        .expect("enable evaluate capability");
    fixture.request.binding.phase = TaskBoardExecutionPhase::Evaluate;
    fixture.request.binding.action_key = "evaluate".into();
    fixture.request = fixture
        .request
        .clone()
        .seal()
        .expect("reseal evaluate offer");
}
