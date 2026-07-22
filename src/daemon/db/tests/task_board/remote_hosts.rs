use std::collections::BTreeMap;
use tempfile::tempdir;

use super::super::*;
use crate::task_board::{
    AgentMode, TASK_BOARD_READ_ONLY_RUN_CONTEXT_VERSION, TASK_BOARD_REMOTE_PROTOCOL_VERSION,
    TaskBoardExecutionHostAdvertisement, TaskBoardExecutionHostConfig, TaskBoardExecutionOwnership,
    TaskBoardExecutionPhase, TaskBoardExecutionState, TaskBoardLocalExecutionHostConfig,
    TaskBoardLocalExecutionRepositoryConfig, TaskBoardPhaseCapabilityProfile,
    TaskBoardReadOnlyRunContext, TaskBoardRemoteHostState, TaskBoardRepositoryAutomationConfig,
    TaskBoardResolvedReviewer, TaskBoardReviewerProfile, TaskBoardWorkflowExecutionArtifacts,
    TaskBoardWorkflowExecutionRecord, TaskBoardWorkflowKind, TaskBoardWorkflowSnapshot,
    TaskBoardWorkflowTransitionState,
};

#[tokio::test]
async fn settings_sync_preserves_the_local_executor_self_row() {
    let dir = tempdir().expect("tempdir");
    let db = AsyncDaemonDb::connect(&dir.path().join("harness.db"))
        .await
        .expect("open db");
    let mut settings = db
        .task_board_orchestrator_settings()
        .await
        .expect("load settings");
    settings.local_execution_host = local_executor("executor-a");
    db.replace_task_board_orchestrator_settings(&settings)
        .await
        .expect("configure local executor");
    settings.dry_run_default = !settings.dry_run_default;

    db.replace_task_board_orchestrator_settings(&settings)
        .await
        .expect("update unrelated settings");

    assert_eq!(
        host_role_and_enabled(&db, "executor-a").await,
        ("executor_self".into(), true)
    );
}

#[tokio::test]
async fn settings_sync_rejects_a_cross_role_host_id_collision() {
    let dir = tempdir().expect("tempdir");
    let db = AsyncDaemonDb::connect(&dir.path().join("harness.db"))
        .await
        .expect("open db");
    let mut settings = db
        .task_board_orchestrator_settings()
        .await
        .expect("load settings");
    settings.local_execution_host = local_executor("executor-a");
    db.replace_task_board_orchestrator_settings(&settings)
        .await
        .expect("configure local executor");
    settings.execution_hosts.push(TaskBoardExecutionHostConfig {
        host_id: "executor-a".into(),
        endpoint: "https://executor.example.test".into(),
        certificate_fingerprint: crate::task_board::remote_spki_pin::encode([0x11; 32]),
        credential_reference: "env://HARNESS_REMOTE_TOKEN".into(),
        enabled: true,
    });

    let error = db
        .replace_task_board_orchestrator_settings(&settings)
        .await
        .expect_err("cross-role host identity must fail closed");

    assert!(error.to_string().contains("local executor identity"));
    assert_eq!(
        host_role_and_enabled(&db, "executor-a").await,
        ("executor_self".into(), true)
    );
}

#[tokio::test]
async fn disabled_and_removed_remote_hosts_require_a_fresh_advertisement() {
    let dir = tempdir().expect("tempdir");
    let db = AsyncDaemonDb::connect(&dir.path().join("harness.db"))
        .await
        .expect("open db");
    let mut settings = db
        .task_board_orchestrator_settings()
        .await
        .expect("load settings");
    settings
        .execution_hosts
        .push(controller_host("controller-a"));
    db.replace_task_board_orchestrator_settings(&settings)
        .await
        .expect("configure controller host");
    record_controller_observation(&db, "controller-a").await;
    assert_eq!(observation_field_count(&db, "controller-a").await, 11);

    settings.execution_hosts[0].enabled = false;
    db.replace_task_board_orchestrator_settings(&settings)
        .await
        .expect("disable controller host");
    assert_eq!(observation_field_count(&db, "controller-a").await, 0);

    settings.execution_hosts[0].enabled = true;
    db.replace_task_board_orchestrator_settings(&settings)
        .await
        .expect("re-enable controller host");
    assert_eq!(observation_field_count(&db, "controller-a").await, 0);
    record_controller_observation(&db, "controller-a").await;

    let configured = settings.execution_hosts.remove(0);
    db.replace_task_board_orchestrator_settings(&settings)
        .await
        .expect("remove controller host");
    assert_eq!(
        host_role_and_enabled(&db, "controller-a").await,
        ("controller_remote".into(), false)
    );
    assert_eq!(observation_field_count(&db, "controller-a").await, 0);

    settings.execution_hosts.push(configured);
    db.replace_task_board_orchestrator_settings(&settings)
        .await
        .expect("restore controller host");
    assert_eq!(
        host_role_and_enabled(&db, "controller-a").await,
        ("controller_remote".into(), true)
    );
    assert_eq!(observation_field_count(&db, "controller-a").await, 0);
    record_controller_observation(&db, "controller-a").await;
    assert_eq!(observation_field_count(&db, "controller-a").await, 11);
}

#[tokio::test]
async fn invalid_or_colliding_host_updates_roll_back_without_disabling_existing_hosts() {
    let dir = tempdir().expect("tempdir");
    let db = AsyncDaemonDb::connect(&dir.path().join("harness.db"))
        .await
        .expect("open db");
    let mut baseline = db
        .task_board_orchestrator_settings()
        .await
        .expect("load settings");
    baseline.local_execution_host = local_executor("executor-self");
    baseline
        .execution_hosts
        .push(controller_host("controller-a"));
    db.replace_task_board_orchestrator_settings(&baseline)
        .await
        .expect("configure baseline hosts");
    record_controller_observation(&db, "controller-a").await;

    let mut invalid = baseline.clone();
    invalid.execution_hosts.clear();
    let mut invalid_host = controller_host("controller-b");
    invalid_host.endpoint = "http://controller.example.test".into();
    invalid.execution_hosts.push(invalid_host);
    db.replace_task_board_orchestrator_settings(&invalid)
        .await
        .expect_err("invalid replacement must fail closed");
    assert_host_sync_rolled_back(&db, &baseline).await;

    let mut collision = baseline.clone();
    collision.execution_hosts.clear();
    collision
        .execution_hosts
        .push(controller_host("executor-self"));
    db.replace_task_board_orchestrator_settings(&collision)
        .await
        .expect_err("cross-role replacement must fail closed");
    assert_host_sync_rolled_back(&db, &baseline).await;
}

#[tokio::test]
async fn outbound_resolution_ignores_executor_self_rows() {
    let dir = tempdir().expect("tempdir");
    let db = AsyncDaemonDb::connect(&dir.path().join("harness.db"))
        .await
        .expect("open db");
    let mut settings = db
        .task_board_orchestrator_settings()
        .await
        .expect("load settings");
    settings.local_execution_host = local_executor("executor-self");
    settings
        .execution_hosts
        .push(controller_host("controller-a"));
    settings
        .repositories
        .push(TaskBoardRepositoryAutomationConfig {
            repository: "example/repo".into(),
            enabled: true,
            workflows: vec![crate::task_board::TaskBoardOrchestratorWorkflow::Review],
            preferred_host_id: Some("controller-a".into()),
            execution_checkout_path: None,
        });
    db.replace_task_board_orchestrator_settings(&settings)
        .await
        .expect("configure controller host");
    let now = "2026-07-19T10:00:00Z";
    db.record_task_board_execution_host_observation(
        &TaskBoardExecutionHostAdvertisement {
            host_id: "controller-a".into(),
            host_instance_id: "instance-a".into(),
            protocol_version: TASK_BOARD_REMOTE_PROTOCOL_VERSION,
            repositories: vec!["example/repo".into()],
            runtimes: vec!["codex".into()],
            capabilities: vec![TaskBoardPhaseCapabilityProfile::ReviewReadOnly],
            capacity: 1,
            active_assignments: 0,
            heartbeat_at: now.into(),
        },
        now,
    )
    .await
    .expect("record controller observation");

    // The resolver requires the execution's configuration revision to match the current
    // settings row; replacing the settings above advanced it past the fixture default.
    let revision = db
        .task_board_orchestrator_settings_snapshot()
        .await
        .expect("load settings revision")
        .row_revision;
    let mut execution = review_execution();
    execution.snapshot.configuration_revision =
        u64::try_from(revision).expect("settings revision fits u64");
    let selected = db
        .resolve_task_board_remote_host(
            &execution,
            "example/repo",
            TaskBoardExecutionPhase::Review,
            "codex",
            now,
        )
        .await
        .expect("resolve mixed-role hosts")
        .expect("controller host selected");

    assert_eq!(selected.config.host_id, "controller-a");
    assert_eq!(
        host_role_and_enabled(&db, "executor-self").await,
        ("executor_self".into(), true)
    );
}

#[tokio::test]
async fn disabled_is_rejected_as_an_observed_state_without_mutation() {
    let dir = tempdir().expect("tempdir");
    let db = AsyncDaemonDb::connect(&dir.path().join("harness.db"))
        .await
        .expect("open db");
    let mut settings = db
        .task_board_orchestrator_settings()
        .await
        .expect("load settings");
    settings
        .execution_hosts
        .push(controller_host("controller-a"));
    db.replace_task_board_orchestrator_settings(&settings)
        .await
        .expect("configure controller host");
    let expected = db
        .task_board_remote_host_trust_fence("controller-a")
        .await
        .expect("capture host trust fence");
    let now = "2026-07-19T10:00:00Z";
    let advertisement = TaskBoardExecutionHostAdvertisement {
        host_id: "controller-a".into(),
        host_instance_id: "instance-a".into(),
        protocol_version: TASK_BOARD_REMOTE_PROTOCOL_VERSION,
        repositories: vec!["example/repo".into()],
        runtimes: vec!["codex".into()],
        capabilities: vec![TaskBoardPhaseCapabilityProfile::ReviewReadOnly],
        capacity: 1,
        active_assignments: 0,
        heartbeat_at: now.into(),
    };

    let error = db
        .record_task_board_execution_host_observation_state_for_test(
            &advertisement,
            now,
            &expected,
            TaskBoardRemoteHostState::Disabled,
        )
        .await
        .expect_err("operator-disabled state cannot be written as an observation");

    assert!(error.to_string().contains("cannot be observed"));
    assert_eq!(observed_evidence(&db, "controller-a").await, (None, None, None));
}

fn local_executor(host_id: &str) -> TaskBoardLocalExecutionHostConfig {
    TaskBoardLocalExecutionHostConfig {
        enabled: true,
        host_id: host_id.into(),
        capacity: 1,
        repositories: vec![TaskBoardLocalExecutionRepositoryConfig {
            repository: "example/repo".into(),
            checkout_path: "/tmp/executor-repo".into(),
        }],
        runtimes: vec!["codex".into()],
        capabilities: vec![TaskBoardPhaseCapabilityProfile::ReviewReadOnly],
    }
}

fn controller_host(host_id: &str) -> TaskBoardExecutionHostConfig {
    TaskBoardExecutionHostConfig {
        host_id: host_id.into(),
        endpoint: "https://controller.example.test".into(),
        certificate_fingerprint: crate::task_board::remote_spki_pin::encode([0x11; 32]),
        credential_reference: "env://HARNESS_REMOTE_TOKEN".into(),
        enabled: true,
    }
}

async fn record_controller_observation(db: &AsyncDaemonDb, host_id: &str) {
    let now = "2026-07-19T10:00:00Z";
    db.record_task_board_execution_host_observation(
        &TaskBoardExecutionHostAdvertisement {
            host_id: host_id.into(),
            host_instance_id: "instance-a".into(),
            protocol_version: TASK_BOARD_REMOTE_PROTOCOL_VERSION,
            repositories: vec!["example/repo".into()],
            runtimes: vec!["codex".into()],
            capabilities: vec![TaskBoardPhaseCapabilityProfile::ReviewReadOnly],
            capacity: 1,
            active_assignments: 0,
            heartbeat_at: now.into(),
        },
        now,
    )
    .await
    .expect("record controller observation");
}

async fn assert_host_sync_rolled_back(
    db: &AsyncDaemonDb,
    baseline: &crate::task_board::TaskBoardOrchestratorSettings,
) {
    assert_eq!(
        db.task_board_orchestrator_settings()
            .await
            .expect("reload orchestrator settings"),
        *baseline
    );
    assert_eq!(
        host_role_and_enabled(db, "controller-a").await,
        ("controller_remote".into(), true)
    );
    assert_eq!(observation_field_count(db, "controller-a").await, 11);
    assert_eq!(
        host_role_and_enabled(db, "executor-self").await,
        ("executor_self".into(), true)
    );
}

fn review_execution() -> TaskBoardWorkflowExecutionRecord {
    let reviewer = TaskBoardResolvedReviewer {
        reviewer_count: 2,
        required_approvals: 1,
        max_revision_cycles: 1,
        profiles: vec![
            TaskBoardReviewerProfile {
                id: "reviewer".into(),
                runtime: "codex".into(),
                persona: "reviewer".into(),
                agent_mode: AgentMode::Evaluate,
                model: None,
                effort: None,
            },
            TaskBoardReviewerProfile {
                id: "unrelated".into(),
                runtime: "claude".into(),
                persona: "other reviewer".into(),
                agent_mode: AgentMode::Evaluate,
                model: None,
                effort: None,
            },
        ],
    };
    TaskBoardWorkflowExecutionRecord {
        execution_id: "execution-review".into(),
        item_id: "item-review".into(),
        snapshot: TaskBoardWorkflowSnapshot {
            workflow_kind: TaskBoardWorkflowKind::Review,
            execution_repository: Some("example/repo".into()),
            item_revision: 1,
            configuration_revision: 1,
            policy_version: "policy-v1".into(),
            reviewer: reviewer.clone(),
            read_only_run_context: Some(TaskBoardReadOnlyRunContext {
                schema_version: TASK_BOARD_READ_ONLY_RUN_CONTEXT_VERSION,
                session_id: "session-review".into(),
                title: "Review".into(),
                body: "Review safely".into(),
                tags: Vec::new(),
                worktree: "/tmp/review".into(),
            }),
            provider_revision: None,
        },
        resolved_reviewers: reviewer,
        transition: TaskBoardWorkflowTransitionState {
            workflow_kind: TaskBoardWorkflowKind::Review,
            phase: Some(TaskBoardExecutionPhase::Review),
            execution_state: TaskBoardExecutionState::Preparing,
            pull_request: None,
            exact_head_revision: Some("head".into()),
        },
        artifacts: TaskBoardWorkflowExecutionArtifacts::default(),
        ownership: TaskBoardExecutionOwnership {
            host_id: None,
            fencing_epoch: 0,
            resources: BTreeMap::new(),
        },
        available_at: None,
        blocked_reason: None,
        created_at: "2026-07-19T10:00:00Z".into(),
        updated_at: "2026-07-19T10:00:00Z".into(),
        completed_at: None,
        attempts: Vec::new(),
    }
}

async fn host_role_and_enabled(db: &AsyncDaemonDb, host_id: &str) -> (String, bool) {
    sqlx::query_as("SELECT host_role, enabled FROM task_board_execution_hosts WHERE host_id = ?1")
        .bind(host_id)
        .fetch_one(db.pool())
        .await
        .expect("load execution host row")
}

async fn observed_evidence(
    db: &AsyncDaemonDb,
    host_id: &str,
) -> (Option<String>, Option<String>, Option<String>) {
    sqlx::query_as(
        "SELECT observed_state, observed_host_instance_id, advertisement_sha256
         FROM task_board_execution_hosts WHERE host_id = ?1",
    )
    .bind(host_id)
    .fetch_one(db.pool())
    .await
    .expect("load observed host evidence")
}

async fn observation_field_count(db: &AsyncDaemonDb, host_id: &str) -> i64 {
    sqlx::query_scalar(
        "SELECT
           (observed_host_instance_id IS NOT NULL)
           + (observed_protocol_version IS NOT NULL)
           + (observed_capabilities_json IS NOT NULL)
           + (observed_repositories_json IS NOT NULL)
           + (observed_runtimes_json IS NOT NULL)
           + (observed_capacity IS NOT NULL)
           + (observed_active_assignments IS NOT NULL)
           + (observed_state IS NOT NULL)
           + (observed_heartbeat_at IS NOT NULL)
           + (observed_received_at IS NOT NULL)
           + (advertisement_sha256 IS NOT NULL)
         FROM task_board_execution_hosts WHERE host_id = ?1",
    )
    .bind(host_id)
    .fetch_one(db.pool())
    .await
    .expect("count observed host evidence")
}
