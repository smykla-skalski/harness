use std::collections::BTreeMap;

use tempfile::TempDir;

use super::workflow_dispatch::workflow_owner;
use super::{TaskBoardRemoteAssignmentRecord, TaskBoardRemoteOfferOutcome};
use crate::daemon::db::AsyncDaemonDb;
use crate::daemon::task_board_remote_transport::wire::{
    RemoteArtifactManifest, RemoteAttemptBinding, RemoteClaimRequest, RemoteCodexLaunchEnvelope,
    RemoteOfferRequest, RemoteSourceMaterial, TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
    test_codex_launch,
};
use crate::task_board::{
    AgentMode, TASK_BOARD_READ_ONLY_RUN_CONTEXT_VERSION, TASK_BOARD_REMOTE_PROTOCOL_VERSION,
    TaskBoardAttemptState, TaskBoardExecutionAttemptRecord, TaskBoardExecutionHostAdvertisement,
    TaskBoardExecutionHostConfig, TaskBoardExecutionOwnership, TaskBoardExecutionPhase,
    TaskBoardExecutionState, TaskBoardLocalExecutionHostConfig,
    TaskBoardLocalExecutionRepositoryConfig, TaskBoardOrchestratorWorkflow,
    TaskBoardPhaseCapabilityProfile, TaskBoardReadOnlyRunContext,
    TaskBoardRepositoryAutomationConfig, TaskBoardResolvedReviewer, TaskBoardReviewerProfile,
    TaskBoardWorkflowExecutionArtifacts, TaskBoardWorkflowExecutionRecord, TaskBoardWorkflowKind,
    TaskBoardWorkflowSnapshot, TaskBoardWorkflowTransitionState,
};

#[path = "remote_assignment_test_support/runtime.rs"]
mod runtime;
pub(crate) use runtime::{
    authorize_and_start_executor, persist_executor_run, persist_pre_permit_executor_run,
};

pub(crate) const NOW: &str = "2026-07-19T10:00:00Z";
pub(crate) const CLAIMED_AT: &str = "2026-07-19T10:00:10Z";
pub(super) const STARTED_AT: &str = "2026-07-19T10:00:20Z";
pub(crate) const LEASE_EXPIRES: &str = "2026-07-19T10:01:00Z";
pub(crate) const DEADLINE: &str = "2026-07-19T10:10:00Z";
pub(super) const AFTER_EXPIRY: &str = "2026-07-19T10:02:00Z";
pub(crate) const HOST: &str = "executor-a";
// A remote executor's authenticated principal is its host_id: assignment_route
// rejects any offer whose client_id != binding.host_id, and the schema pins
// authenticated_principal = host_id. Tests mirror that single identity.
pub(crate) const PRINCIPAL: &str = HOST;
pub(crate) const INSTANCE: &str = "instance-a";
pub(super) const REPOSITORY: &str = "example/harness";
pub(super) const SOURCE_REVISION: &str = "1111111111111111111111111111111111111111";

pub(crate) struct ControllerFixture {
    pub(crate) db: AsyncDaemonDb,
    pub(crate) _temp: TempDir,
    pub(crate) execution: TaskBoardWorkflowExecutionRecord,
    pub(crate) attempt: TaskBoardExecutionAttemptRecord,
    pub(crate) request: RemoteOfferRequest,
}

pub(crate) async fn controller_fixture(capacity: u32) -> ControllerFixture {
    controller_fixture_with_retry_attempts(capacity, None).await
}

pub(super) async fn controller_fixture_with_retry_attempts(
    capacity: u32,
    max_attempts: Option<u32>,
) -> ControllerFixture {
    let temp = tempfile::tempdir().expect("tempdir");
    let db = AsyncDaemonDb::connect(&temp.path().join("controller.db"))
        .await
        .expect("open controller db");
    configure_controller(&db, max_attempts).await;
    let execution = review_execution(&db).await;
    let attempt = review_attempt(&execution.execution_id, 1, NOW);
    db.create_task_board_execution_attempt(&attempt)
        .await
        .expect("create remote-ready attempt");
    let execution = db
        .task_board_workflow_execution(&execution.execution_id)
        .await
        .expect("load execution")
        .expect("execution exists");
    db.record_task_board_execution_host_observation(
        &TaskBoardExecutionHostAdvertisement {
            host_id: HOST.into(),
            host_instance_id: INSTANCE.into(),
            protocol_version: TASK_BOARD_REMOTE_PROTOCOL_VERSION,
            repositories: vec![REPOSITORY.into()],
            runtimes: vec!["codex".into()],
            capabilities: vec![TaskBoardPhaseCapabilityProfile::ReviewReadOnly],
            capacity,
            active_assignments: 0,
            heartbeat_at: NOW.into(),
        },
        NOW,
    )
    .await
    .expect("record host observation");
    let request = offer_request(
        &execution,
        &attempt,
        "assignment-controller-1",
        HOST,
        INSTANCE,
    );
    ControllerFixture {
        db,
        _temp: temp,
        execution,
        attempt,
        request,
    }
}

pub(super) async fn offer_controller(fixture: &ControllerFixture) -> TaskBoardRemoteOfferOutcome {
    fixture
        .db
        .offer_task_board_remote_assignment(
            &crate::task_board::TaskBoardWorkflowExecutionCas::from(&fixture.execution),
            &crate::task_board::TaskBoardExecutionAttemptCas::from(&fixture.attempt),
            &fixture.request,
            HOST,
            NOW,
            LEASE_EXPIRES,
            DEADLINE,
        )
        .await
        .expect("offer controller assignment")
}

pub(crate) struct ExecutorFixture {
    pub(crate) db: AsyncDaemonDb,
    pub(crate) _temp: TempDir,
    pub(crate) request: RemoteOfferRequest,
}

pub(crate) async fn executor_fixture(capacity: u32) -> ExecutorFixture {
    let temp = tempfile::tempdir().expect("tempdir");
    let db = AsyncDaemonDb::connect(&temp.path().join("executor.db"))
        .await
        .expect("open executor db");
    let mut settings = db
        .task_board_orchestrator_settings()
        .await
        .expect("load executor settings");
    settings.local_execution_host = TaskBoardLocalExecutionHostConfig {
        enabled: true,
        host_id: HOST.into(),
        capacity,
        repositories: vec![TaskBoardLocalExecutionRepositoryConfig {
            repository: REPOSITORY.into(),
            checkout_path: "/tmp/harness-remote-checkouts".into(),
        }],
        runtimes: vec!["codex".into()],
        capabilities: vec![TaskBoardPhaseCapabilityProfile::ReviewReadOnly],
    };
    db.replace_task_board_orchestrator_settings(&settings)
        .await
        .expect("configure executor");
    let request = detached_offer("assignment-executor-1", "attempt-key-1");
    ExecutorFixture {
        db,
        _temp: temp,
        request,
    }
}

pub(crate) async fn accept_executor(
    fixture: &ExecutorFixture,
    request: &RemoteOfferRequest,
) -> TaskBoardRemoteAssignmentRecord {
    match fixture
        .db
        .accept_task_board_remote_assignment_offer(request, PRINCIPAL, INSTANCE, NOW)
        .await
        .expect("accept executor offer")
    {
        TaskBoardRemoteOfferOutcome::Created(record) => record,
        other => panic!("expected created executor offer, got {other:?}"),
    }
}

pub(super) fn detached_offer(assignment_id: &str, idempotency_key: &str) -> RemoteOfferRequest {
    RemoteOfferRequest {
        schema_version: TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
        binding: RemoteAttemptBinding {
            assignment_id: assignment_id.into(),
            execution_id: "execution-detached".into(),
            phase: TaskBoardExecutionPhase::Review,
            workflow_kind: TaskBoardWorkflowKind::Review,
            action_key: "review:reviewer".into(),
            attempt: 1,
            idempotency_key: idempotency_key.into(),
            host_id: HOST.into(),
            host_instance_id: INSTANCE.into(),
            fencing_epoch: 1,
            configuration_revision: 77,
            execution_record_sha256: "a".repeat(64),
            repository: REPOSITORY.into(),
            base_revision: SOURCE_REVISION.into(),
            expected_head_revision: Some(SOURCE_REVISION.into()),
        },
        lease_seconds: 60,
        deadline_at: DEADLINE.into(),
        launch: test_codex_launch(
            TaskBoardExecutionPhase::Review,
            "execution-detached",
            "review:reviewer",
            "Review the frozen revision",
        ),
        source: RemoteSourceMaterial::repository_revision(REPOSITORY, SOURCE_REVISION),
        artifacts: RemoteArtifactManifest::default(),
        request_sha256: String::new(),
    }
    .seal()
    .expect("seal detached offer")
}

pub(crate) fn claim_request(
    request: &RemoteOfferRequest,
    assignment: &TaskBoardRemoteAssignmentRecord,
) -> RemoteClaimRequest {
    RemoteClaimRequest {
        schema_version: TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
        binding: request.binding.clone(),
        lease_id: assignment.lease_id.clone().expect("host lease"),
        offer_request_sha256: request.request_sha256.clone(),
        request_sha256: String::new(),
    }
    .seal()
    .expect("seal claim")
}

async fn configure_controller(db: &AsyncDaemonDb, max_attempts: Option<u32>) {
    let mut settings = db
        .task_board_orchestrator_settings()
        .await
        .expect("load controller settings");
    settings.execution_hosts = vec![TaskBoardExecutionHostConfig {
        host_id: HOST.into(),
        endpoint: "https://executor.example.test".into(),
        certificate_fingerprint: crate::task_board::remote_spki_pin::encode([0x11; 32]),
        credential_reference: "env://HARNESS_REMOTE_TOKEN".into(),
        enabled: true,
    }];
    settings.repositories = vec![TaskBoardRepositoryAutomationConfig {
        repository: REPOSITORY.into(),
        enabled: true,
        workflows: vec![TaskBoardOrchestratorWorkflow::Review],
        preferred_host_id: Some(HOST.into()),
        execution_checkout_path: None,
    }];
    if let Some(max_attempts) = max_attempts {
        settings.retry.max_attempts = max_attempts;
    }
    db.replace_task_board_orchestrator_settings(&settings)
        .await
        .expect("configure controller");
}

async fn review_execution(db: &AsyncDaemonDb) -> TaskBoardWorkflowExecutionRecord {
    let mut item = crate::task_board::TaskBoardItem::new(
        "item-remote".into(),
        "Remote review".into(),
        "Review exactly one revision".into(),
        NOW.into(),
    );
    item.workflow_kind = TaskBoardWorkflowKind::Review;
    item.execution_repository = Some(REPOSITORY.into());
    let mutation = db.create_task_board_item(item).await.expect("create item");
    let settings = db
        .task_board_orchestrator_settings_snapshot()
        .await
        .expect("settings snapshot");
    let reviewer = reviewers();
    let record = TaskBoardWorkflowExecutionRecord {
        execution_id: "execution-remote".into(),
        item_id: "item-remote".into(),
        snapshot: TaskBoardWorkflowSnapshot {
            workflow_kind: TaskBoardWorkflowKind::Review,
            execution_repository: Some(REPOSITORY.into()),
            item_revision: mutation.item_revision,
            configuration_revision: u64::try_from(settings.row_revision)
                .expect("settings revision"),
            policy_version: settings.settings.policy_version,
            reviewer: reviewer.clone(),
            read_only_run_context: Some(TaskBoardReadOnlyRunContext {
                schema_version: TASK_BOARD_READ_ONLY_RUN_CONTEXT_VERSION,
                session_id: "session-remote".into(),
                title: "Remote review".into(),
                body: "Review exactly one revision".into(),
                tags: vec!["security".into()],
                worktree: "/tmp/controller-context-only".into(),
            }),
            provider_revision: None,
        },
        resolved_reviewers: reviewer,
        transition: TaskBoardWorkflowTransitionState {
            workflow_kind: TaskBoardWorkflowKind::Review,
            phase: Some(TaskBoardExecutionPhase::Review),
            execution_state: TaskBoardExecutionState::Preparing,
            pull_request: None,
            exact_head_revision: Some(SOURCE_REVISION.into()),
        },
        artifacts: TaskBoardWorkflowExecutionArtifacts::default(),
        ownership: TaskBoardExecutionOwnership {
            host_id: None,
            fencing_epoch: 0,
            resources: BTreeMap::from([(
                "admission_owner".into(),
                workflow_owner("execution-remote"),
            )]),
        },
        available_at: None,
        blocked_reason: None,
        created_at: NOW.into(),
        updated_at: NOW.into(),
        completed_at: None,
        attempts: Vec::new(),
    };
    db.create_or_load_task_board_workflow_execution(&record)
        .await
        .expect("create execution")
        .execution
}

fn reviewers() -> TaskBoardResolvedReviewer {
    TaskBoardResolvedReviewer {
        reviewer_count: 1,
        required_approvals: 1,
        max_revision_cycles: 1,
        profiles: vec![TaskBoardReviewerProfile {
            id: "reviewer".into(),
            runtime: "codex".into(),
            persona: "security-reviewer".into(),
            agent_mode: AgentMode::Evaluate,
            model: Some("gpt-5.4".into()),
            effort: Some("high".into()),
        }],
    }
}

fn review_attempt(execution_id: &str, attempt: u32, now: &str) -> TaskBoardExecutionAttemptRecord {
    TaskBoardExecutionAttemptRecord {
        execution_id: execution_id.into(),
        action_key: "review:reviewer".into(),
        attempt,
        idempotency_key: format!("review-attempt-{attempt}"),
        state: TaskBoardAttemptState::Preparing,
        failure_class: None,
        available_at: None,
        error: None,
        artifact: None,
        started_at: now.into(),
        updated_at: now.into(),
        completed_at: None,
    }
}

pub(super) fn offer_request(
    execution: &TaskBoardWorkflowExecutionRecord,
    attempt: &TaskBoardExecutionAttemptRecord,
    assignment_id: &str,
    host_id: &str,
    instance_id: &str,
) -> RemoteOfferRequest {
    let cas = crate::task_board::TaskBoardWorkflowExecutionCas::from(execution);
    let launch = crate::daemon::service::task_board_read_only_coordinator::requests::remote_codex_attempt_request(
        execution,
        attempt,
    )
    .expect("build canonical remote Codex launch");
    RemoteOfferRequest {
        schema_version: TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
        binding: RemoteAttemptBinding {
            assignment_id: assignment_id.into(),
            execution_id: execution.execution_id.clone(),
            phase: TaskBoardExecutionPhase::Review,
            workflow_kind: TaskBoardWorkflowKind::Review,
            action_key: attempt.action_key.clone(),
            attempt: attempt.attempt,
            idempotency_key: attempt.idempotency_key.clone(),
            host_id: host_id.into(),
            host_instance_id: instance_id.into(),
            fencing_epoch: execution.ownership.fencing_epoch + 1,
            configuration_revision: execution.snapshot.configuration_revision,
            execution_record_sha256: cas.record_sha256,
            repository: REPOSITORY.into(),
            base_revision: SOURCE_REVISION.into(),
            expected_head_revision: Some(SOURCE_REVISION.into()),
        },
        lease_seconds: 60,
        deadline_at: DEADLINE.into(),
        launch: RemoteCodexLaunchEnvelope::from_codex_request("codex", &launch)
            .expect("freeze canonical remote Codex launch"),
        source: RemoteSourceMaterial::repository_revision(REPOSITORY, SOURCE_REVISION),
        artifacts: RemoteArtifactManifest::default(),
        request_sha256: String::new(),
    }
    .seal()
    .expect("seal offer")
}
