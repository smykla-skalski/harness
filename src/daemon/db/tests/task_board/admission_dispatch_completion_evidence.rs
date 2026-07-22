use super::*;
use crate::daemon::task_board_remote_transport::wire::{
    RemoteArtifactManifest, RemoteAssignmentWireState, RemoteAttemptBinding,
    RemoteCodexLaunchEnvelope, RemoteOfferDisposition, RemoteOfferRequest, RemoteOfferResponse,
    RemoteSourceMaterial, RemoteStatusRequest, RemoteStatusResponse,
    TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
};
use crate::task_board::{
    TASK_BOARD_REMOTE_PROTOCOL_VERSION, TaskBoardExecutionHostAdvertisement,
    TaskBoardExecutionHostConfig, TaskBoardExecutionPhase, TaskBoardOrchestratorWorkflow,
    TaskBoardPhaseCapabilityProfile, TaskBoardRepositoryAutomationConfig,
    TaskBoardWorkflowExecutionCas,
};

#[tokio::test]
async fn read_only_dispatch_atomically_starts_workflow_with_exact_completion_evidence() {
    let db = test_db().await;
    configure_policy(&db, admission_policy(1)).await;
    let mut item = TaskBoardItem::new(
        "admission-read-only".into(),
        "Review exact head".into(),
        "Review without workspace writes".into(),
        "2026-07-17T10:00:00Z".into(),
    );
    item.agent_mode = AgentMode::Evaluate;
    item.workflow_kind = TaskBoardWorkflowKind::Review;
    db.create_task_board_item(item).await.expect("create item");
    let mut launch = read_only_launch(&db, None).await;
    let plan = create_plan_for_existing(&db, "admission-read-only").await;
    let intent = preparing_intent(
        db.reserve_task_board_dispatch(&plan, "control-plane", Some("/tmp/project"), false)
            .await
            .expect("reserve dispatch"),
    );
    let preparation = db
        .claim_task_board_dispatch_preparation(&intent)
        .await
        .expect("claim preparation")
        .expect("pending preparation");
    let item_snapshot = db
        .task_board_item_snapshot("admission-read-only")
        .await
        .expect("source item snapshot");
    launch.source_item_revision = item_snapshot.item_revision;
    launch.prepared_item_revision = item_snapshot.item_revision;
    launch.run_context.session_id = preparation.preparation.session_id.clone();
    let applied = db
        .complete_task_board_dispatch_preparation_with_workflow(
            &preparation,
            "branch",
            "/tmp/worktree",
            Some(launch),
            None,
        )
        .await
        .expect("complete preparation");
    let published_launch = applied
        .read_only_workflow
        .as_ref()
        .expect("published read-only launch");
    let source_item_revision = published_launch.source_item_revision;
    assert_eq!(
        published_launch.prepared_item_revision,
        source_item_revision + 1
    );
    let execution_id = applied
        .item
        .workflow
        .execution_id
        .clone()
        .expect("execution id");
    let claim = db
        .claim_task_board_dispatch("admission-read-only")
        .await
        .expect("claim dispatch")
        .expect("pending dispatch");
    let owner = workflow_owner(&execution_id);

    db.complete_task_board_dispatch(&intent, &claim.claim_token, &owner)
        .await
        .expect("commit read-only dispatch");

    assert_prepared_read_only_dispatch(&db, &intent, &execution_id, &owner, source_item_revision)
        .await;
}

async fn assert_prepared_read_only_dispatch(
    db: &AsyncDaemonDb,
    intent: &str,
    execution_id: &str,
    owner: &str,
    source_item_revision: i64,
) {
    let execution = db
        .task_board_workflow_execution(execution_id)
        .await
        .expect("load execution")
        .expect("durable execution");
    assert_eq!(
        execution.attempts[0].state,
        crate::task_board::TaskBoardAttemptState::Preparing
    );
    assert_eq!(execution.attempts[0].available_at, None);
    let item = db
        .task_board_item_snapshot("admission-read-only")
        .await
        .expect("load item snapshot");
    assert_eq!(item.item_revision, source_item_revision + 2);
    assert_eq!(execution.snapshot.item_revision, item.item_revision);
    assert_eq!(
        execution.transition.phase,
        Some(crate::task_board::TaskBoardExecutionPhase::Review)
    );
    assert_eq!(
        execution.transition.execution_state,
        crate::task_board::TaskBoardExecutionState::Preparing
    );
    assert_eq!(execution.attempts.len(), 1);
    assert_eq!(
        execution.attempts[0].action_key,
        "review:default-code-reviewer"
    );
    let side_effect_worker_id = format!("codex-{intent}");
    assert_eq!(execution.attempts[0].idempotency_key, side_effect_worker_id);
    assert_eq!(
        execution
            .ownership
            .resources
            .get("admission_owner")
            .map(String::as_str),
        Some(owner)
    );
    assert_completion_evidence(db, intent, execution_id, owner, &side_effect_worker_id).await;
}

pub(super) async fn read_only_launch(
    db: &AsyncDaemonDb,
    execution_repository: Option<&str>,
) -> TaskBoardReadOnlyWorkflowLaunch {
    let settings = db
        .task_board_orchestrator_settings_snapshot()
        .await
        .expect("settings snapshot");
    TaskBoardReadOnlyWorkflowLaunch {
        workflow_kind: TaskBoardWorkflowKind::Review,
        execution_repository: execution_repository.map(str::to_owned),
        configuration_revision: u64::try_from(settings.row_revision).expect("settings revision"),
        policy_version: settings.settings.policy_version.clone(),
        resolved_reviewers: resolve_task_board_reviewers(
            &settings.settings.reviewers,
            TaskBoardWorkflowKind::Review,
            execution_repository,
        )
        .expect("resolved reviewers"),
        source_item_revision: 1,
        prepared_item_revision: 1,
        run_context: crate::task_board::TaskBoardReadOnlyRunContext {
            schema_version: crate::task_board::TASK_BOARD_READ_ONLY_RUN_CONTEXT_VERSION,
            session_id: "session-existing".into(),
            title: "Review exact head".into(),
            body: "Review without workspace writes".into(),
            tags: Vec::new(),
            worktree: "/tmp/worktree".into(),
        },
        provider_revision: None,
        pull_request: None,
        exact_head_revision: "1111111111111111111111111111111111111111".into(),
    }
}

pub(super) async fn configure_remote_controller(db: &AsyncDaemonDb) {
    let mut settings = db
        .task_board_orchestrator_settings()
        .await
        .expect("load settings");
    settings.execution_hosts = vec![TaskBoardExecutionHostConfig {
        host_id: "executor-a".into(),
        endpoint: "https://executor.example.test".into(),
        certificate_fingerprint: crate::task_board::remote_spki_pin::encode([0x11; 32]),
        credential_reference: "env://HARNESS_REMOTE_TOKEN".into(),
        enabled: true,
    }];
    settings.repositories = vec![TaskBoardRepositoryAutomationConfig {
        repository: "example/harness".into(),
        enabled: true,
        workflows: vec![TaskBoardOrchestratorWorkflow::Review],
        preferred_host_id: Some("executor-a".into()),
        execution_checkout_path: None,
    }];
    db.replace_task_board_orchestrator_settings(&settings)
        .await
        .expect("configure remote controller");
    db.record_task_board_execution_host_observation(
        &TaskBoardExecutionHostAdvertisement {
            host_id: "executor-a".into(),
            host_instance_id: "instance-a".into(),
            protocol_version: TASK_BOARD_REMOTE_PROTOCOL_VERSION,
            repositories: vec!["example/harness".into()],
            runtimes: vec!["codex".into()],
            capabilities: vec![TaskBoardPhaseCapabilityProfile::ReviewReadOnly],
            capacity: 1,
            active_assignments: 0,
            heartbeat_at: "2026-07-19T10:00:00Z".into(),
        },
        "2026-07-19T10:00:00Z",
    )
    .await
    .expect("record host observation");
}

pub(super) async fn configure_remote_implementation_controller(db: &AsyncDaemonDb) {
    configure_remote_controller(db).await;
    let mut settings = db
        .task_board_orchestrator_settings()
        .await
        .expect("load implementation remote settings");
    settings.repositories[0].workflows = vec![TaskBoardOrchestratorWorkflow::DefaultTask];
    db.replace_task_board_orchestrator_settings(&settings)
        .await
        .expect("configure remote implementation workflow");
    db.record_task_board_execution_host_observation(
        &TaskBoardExecutionHostAdvertisement {
            host_id: "executor-a".into(),
            host_instance_id: "instance-a".into(),
            protocol_version: TASK_BOARD_REMOTE_PROTOCOL_VERSION,
            repositories: vec!["example/harness".into()],
            runtimes: vec!["codex".into()],
            capabilities: vec![TaskBoardPhaseCapabilityProfile::ImplementationWrite],
            capacity: 1,
            active_assignments: 0,
            heartbeat_at: "2026-07-19T10:00:00Z".into(),
        },
        "2026-07-19T10:00:00Z",
    )
    .await
    .expect("record implementation host observation");
}

pub(super) fn remote_offer(
    execution: &crate::task_board::TaskBoardWorkflowExecutionRecord,
    attempt: &crate::task_board::TaskBoardExecutionAttemptRecord,
) -> RemoteOfferRequest {
    let request = crate::daemon::service::task_board_read_only_coordinator::requests::remote_codex_attempt_request(
        execution,
        attempt,
    )
    .expect("build canonical remote Codex launch");
    RemoteOfferRequest {
        schema_version: TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
        binding: RemoteAttemptBinding {
            assignment_id: "assignment-admission".into(),
            execution_id: execution.execution_id.clone(),
            phase: TaskBoardExecutionPhase::Review,
            workflow_kind: TaskBoardWorkflowKind::Review,
            action_key: attempt.action_key.clone(),
            attempt: attempt.attempt,
            idempotency_key: attempt.idempotency_key.clone(),
            host_id: "executor-a".into(),
            host_instance_id: "instance-a".into(),
            fencing_epoch: 1,
            configuration_revision: execution.snapshot.configuration_revision,
            execution_record_sha256: TaskBoardWorkflowExecutionCas::from(execution).record_sha256,
            repository: "example/harness".into(),
            base_revision: "1111111111111111111111111111111111111111".into(),
            expected_head_revision: Some("1111111111111111111111111111111111111111".into()),
        },
        lease_seconds: 60,
        deadline_at: "2026-07-19T10:10:00Z".into(),
        launch: RemoteCodexLaunchEnvelope::from_codex_request("codex", &request)
            .expect("freeze canonical remote Codex launch"),
        source: RemoteSourceMaterial::repository_revision(
            "example/harness",
            "1111111111111111111111111111111111111111",
        ),
        artifacts: RemoteArtifactManifest::default(),
        request_sha256: String::new(),
    }
    .seal()
    .expect("seal offer")
}

pub(super) fn accepted_offer(offer: &RemoteOfferRequest) -> RemoteOfferResponse {
    RemoteOfferResponse {
        schema_version: TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
        binding: offer.binding.clone(),
        offer_request_sha256: offer.request_sha256.clone(),
        disposition: RemoteOfferDisposition::Accepted,
        lease: Some(
            crate::daemon::task_board_remote_transport::wire::RemoteLease {
                lease_id: "lease-admission".into(),
                expires_at: "2026-07-19T10:01:00Z".into(),
            },
        ),
        rejection_code: None,
    }
}

pub(super) fn remote_status(
    offer: &RemoteOfferRequest,
    state: RemoteAssignmentWireState,
    started: bool,
) -> RemoteStatusResponse {
    RemoteStatusResponse {
        schema_version: TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
        binding: offer.binding.clone(),
        state,
        offer_request_sha256: offer.request_sha256.clone(),
        status_sha256: String::new(),
        // A promoting status must echo the accepted lease to reconstruct a lost claim.
        lease: Some(
            crate::daemon::task_board_remote_transport::wire::RemoteLease {
                lease_id: "lease-admission".into(),
                expires_at: "2026-07-19T10:01:00Z".into(),
            },
        ),
        result: None,
        output_artifacts: RemoteArtifactManifest::default(),
        claimed_at: Some("2026-07-19T10:00:02Z".into()),
        started_at: started.then(|| "2026-07-19T10:00:03Z".into()),
        workspace_ref: started.then(|| "workspace-admission".into()),
        error_code: None,
        failure_class: None,
        observed_at: if started {
            "2026-07-19T10:00:04Z".into()
        } else {
            "2026-07-19T10:00:02Z".into()
        },
    }
    .seal()
    .expect("seal status")
}

pub(super) fn remote_status_request(offer: &RemoteOfferRequest) -> RemoteStatusRequest {
    RemoteStatusRequest {
        schema_version: TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
        binding: offer.binding.clone(),
        lease_id: "lease-admission".into(),
        offer_request_sha256: offer.request_sha256.clone(),
        request_sha256: String::new(),
    }
    .seal()
    .expect("seal status request")
}

pub(super) async fn intent_status(db: &AsyncDaemonDb, intent_id: &str) -> String {
    sqlx::query_scalar("SELECT status FROM task_board_dispatch_intents WHERE intent_id = ?1")
        .bind(intent_id)
        .fetch_one(db.pool())
        .await
        .expect("load dispatch intent status")
}

async fn assert_completion_evidence(
    db: &AsyncDaemonDb,
    intent_id: &str,
    execution_id: &str,
    owner: &str,
    side_effect_worker_id: &str,
) {
    assert!(
        completion_matches(
            db,
            intent_id,
            execution_id,
            owner,
            owner,
            side_effect_worker_id,
        )
        .await
    );
    for (ledger_owner, workflow_owner, worker_id) in [
        ("wrong-ledger-worker", owner, side_effect_worker_id),
        (owner, "wrong-workflow-owner", side_effect_worker_id),
        (owner, owner, "wrong-side-effect-worker"),
    ] {
        assert!(
            !completion_matches(
                db,
                intent_id,
                execution_id,
                ledger_owner,
                workflow_owner,
                worker_id,
            )
            .await
        );
    }
    sqlx::query(
        "DELETE FROM task_board_dispatch_admission_ledger
         WHERE intent_id = ?1 AND kind = 'concurrency'",
    )
    .bind(intent_id)
    .execute(db.pool())
    .await
    .expect("remove required completion evidence");
    assert!(
        !completion_matches(
            db,
            intent_id,
            execution_id,
            owner,
            owner,
            side_effect_worker_id,
        )
        .await
    );
}

async fn completion_matches(
    db: &AsyncDaemonDb,
    intent_id: &str,
    execution_id: &str,
    managed_worker_id: &str,
    admission_owner_id: &str,
    side_effect_worker_id: &str,
) -> bool {
    db.task_board_dispatch_completion_matches(
        intent_id,
        execution_id,
        managed_worker_id,
        admission_owner_id,
        side_effect_worker_id,
        true,
    )
    .await
    .expect("check exact dispatch completion")
}
