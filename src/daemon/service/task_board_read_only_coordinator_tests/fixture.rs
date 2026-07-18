use std::collections::{BTreeMap, HashMap};

use crate::daemon::db::{AsyncDaemonDb, workflow_owner};
use crate::task_board::{
    AgentMode, ExternalRef, ExternalRefProvider, SpawnGateSwitches,
    TASK_BOARD_READ_ONLY_RUN_CONTEXT_VERSION, TaskBoardAttemptState,
    TaskBoardExecutionAttemptRecord, TaskBoardExecutionOwnership, TaskBoardExecutionState,
    TaskBoardFailureClass, TaskBoardItem, TaskBoardOrchestratorSettings,
    TaskBoardPullRequestIdentity, TaskBoardReadOnlyRunContext, TaskBoardReadOnlyWorkflowLaunch,
    TaskBoardWorkflowExecutionArtifacts, TaskBoardWorkflowExecutionRecord, TaskBoardWorkflowKind,
    TaskBoardWorkflowSnapshot, TaskBoardWorkflowStatus, TaskBoardWorkflowTransitionState,
    build_dispatch_plans_with_policy, resolve_task_board_reviewers,
};

use super::super::task_board_workflow_test_support::{TestDatabase, reviewers};

pub(super) const NOW: &str = "2026-07-17T10:00:00Z";
pub(super) const RETRY_AT: &str = "2026-07-17T10:05:00Z";
pub(super) const FROZEN_HEAD: &str = "head-frozen";

pub(super) struct Fixture {
    pub(super) test: TestDatabase,
    pub(super) item_id: String,
    pub(super) execution_id: String,
}

pub(super) struct AttemptSeed {
    pub(super) state: TaskBoardAttemptState,
    pub(super) failure_class: Option<TaskBoardFailureClass>,
    pub(super) available_at: Option<&'static str>,
    pub(super) error: Option<&'static str>,
    pub(super) completed_at: Option<&'static str>,
}

impl AttemptSeed {
    pub(super) const fn retry_wait(available_at: &'static str) -> Self {
        Self {
            state: TaskBoardAttemptState::RetryWait,
            failure_class: Some(TaskBoardFailureClass::Transient),
            available_at: Some(available_at),
            error: Some("provider temporarily unavailable"),
            completed_at: None,
        }
    }

    pub(super) const fn unknown() -> Self {
        Self {
            state: TaskBoardAttemptState::Unknown,
            failure_class: Some(TaskBoardFailureClass::UnknownOutcome),
            available_at: None,
            error: Some("durable run outcome is unknown"),
            completed_at: None,
        }
    }

    pub(super) const fn cancelled() -> Self {
        Self {
            state: TaskBoardAttemptState::Cancelled,
            failure_class: None,
            available_at: None,
            error: Some("report cancelled"),
            completed_at: Some(NOW),
        }
    }
}

pub(super) async fn seed_execution(
    label: &str,
    workflow_kind: TaskBoardWorkflowKind,
    execution_state: TaskBoardExecutionState,
    attempt: Option<AttemptSeed>,
) -> Fixture {
    seed_execution_at_phase(
        label,
        workflow_kind,
        crate::task_board::TaskBoardExecutionPhase::Review,
        execution_state,
        attempt,
    )
    .await
}

async fn seed_execution_at_phase(
    label: &str,
    workflow_kind: TaskBoardWorkflowKind,
    phase: crate::task_board::TaskBoardExecutionPhase,
    execution_state: TaskBoardExecutionState,
    attempt: Option<AttemptSeed>,
) -> Fixture {
    let test = TestDatabase::open().await;
    let (item_id, execution_id) = seed_execution_in_database(
        &test.db,
        label,
        workflow_kind,
        phase,
        execution_state,
        attempt,
        reviewers(1, 1),
    )
    .await;
    Fixture {
        test,
        item_id,
        execution_id,
    }
}

pub(super) async fn seed_execution_with_reviewers(
    label: &str,
    workflow_kind: TaskBoardWorkflowKind,
    reviewer_count: u32,
    required_approvals: u32,
) -> Fixture {
    let test = TestDatabase::open().await;
    let (item_id, execution_id) = seed_execution_in_database(
        &test.db,
        label,
        workflow_kind,
        crate::task_board::TaskBoardExecutionPhase::Review,
        TaskBoardExecutionState::Pending,
        None,
        reviewers(reviewer_count, required_approvals),
    )
    .await;
    Fixture {
        test,
        item_id,
        execution_id,
    }
}

pub(super) async fn seed_additional_execution(
    db: &AsyncDaemonDb,
    label: &str,
    workflow_kind: TaskBoardWorkflowKind,
    phase: crate::task_board::TaskBoardExecutionPhase,
    execution_state: TaskBoardExecutionState,
    attempt: Option<AttemptSeed>,
) -> (String, String) {
    seed_execution_in_database(
        db,
        label,
        workflow_kind,
        phase,
        execution_state,
        attempt,
        reviewers(1, 1),
    )
    .await
}

async fn seed_execution_in_database(
    db: &AsyncDaemonDb,
    label: &str,
    workflow_kind: TaskBoardWorkflowKind,
    phase: crate::task_board::TaskBoardExecutionPhase,
    execution_state: TaskBoardExecutionState,
    attempt: Option<AttemptSeed>,
    resolved_reviewers: crate::task_board::TaskBoardResolvedReviewer,
) -> (String, String) {
    seed_settings(db).await;
    let item_id = format!("coordinator-{label}");
    let execution_id = format!("execution-{label}");
    let mut item = TaskBoardItem::new(
        item_id.clone(),
        format!("Read-only workflow {label}"),
        "Inspect the exact frozen revision".into(),
        NOW.into(),
    );
    prepare_item(&mut item, workflow_kind, &execution_id);
    let mutation = db
        .create_task_board_item(item)
        .await
        .expect("create coordinator item");
    let settings = db
        .task_board_orchestrator_settings_snapshot()
        .await
        .expect("load settings snapshot");
    let pull_request = pull_request(workflow_kind);
    let execution = TaskBoardWorkflowExecutionRecord {
        execution_id: execution_id.clone(),
        item_id: item_id.clone(),
        snapshot: TaskBoardWorkflowSnapshot {
            workflow_kind,
            execution_repository: (workflow_kind == TaskBoardWorkflowKind::PrReview)
                .then(|| "example/compass".into()),
            item_revision: mutation.item_revision,
            configuration_revision: db
                .task_board_configuration_revision()
                .await
                .expect("configuration revision"),
            policy_version: settings.settings.policy_version,
            reviewer: resolved_reviewers.clone(),
            read_only_run_context: Some(TaskBoardReadOnlyRunContext {
                schema_version: TASK_BOARD_READ_ONLY_RUN_CONTEXT_VERSION,
                session_id: format!("session-{item_id}"),
                title: format!("Read-only workflow {label}"),
                body: "Inspect the exact frozen revision".into(),
                tags: Vec::new(),
                worktree: "/tmp/read-only-worktree".into(),
            }),
            provider_revision: None,
        },
        resolved_reviewers,
        transition: TaskBoardWorkflowTransitionState {
            workflow_kind,
            phase: Some(phase),
            execution_state,
            pull_request,
            exact_head_revision: Some(FROZEN_HEAD.into()),
        },
        artifacts: TaskBoardWorkflowExecutionArtifacts::default(),
        ownership: TaskBoardExecutionOwnership {
            host_id: None,
            fencing_epoch: 0,
            resources: BTreeMap::from([("admission_owner".into(), workflow_owner(&execution_id))]),
        },
        available_at: None,
        blocked_reason: None,
        created_at: NOW.into(),
        updated_at: NOW.into(),
        completed_at: None,
        attempts: Vec::new(),
    };
    db.create_or_load_task_board_workflow_execution(&execution)
        .await
        .expect("create workflow execution");
    if let Some(seed) = attempt {
        seed_attempt(db, &execution, seed).await;
    }
    insert_committed_admission(db, &item_id, &execution_id, mutation.item_revision).await;
    (item_id, execution_id)
}

fn prepare_item(
    item: &mut TaskBoardItem,
    workflow_kind: TaskBoardWorkflowKind,
    execution_id: &str,
) {
    item.status = crate::task_board::TaskBoardStatus::InProgress;
    item.agent_mode = AgentMode::Evaluate;
    item.workflow_kind = workflow_kind;
    item.session_id = Some(format!("session-{}", item.id));
    item.workflow.execution_id = Some(execution_id.into());
    item.workflow.status = TaskBoardWorkflowStatus::Running;
    item.workflow.current_step_id = Some("review".into());
    item.workflow.worktree = Some("/tmp/read-only-worktree".into());
    if workflow_kind == TaskBoardWorkflowKind::PrReview {
        item.execution_repository = Some("example/compass".into());
        item.workflow.pr_number = Some(17);
        item.workflow.pr_url = Some("https://github.com/example/compass/pull/17".into());
        item.external_refs = vec![ExternalRef {
            provider: ExternalRefProvider::GitHub,
            external_id: "example/compass#17".into(),
            url: item.workflow.pr_url.clone(),
            sync_state: None,
        }];
    }
}

async fn seed_settings(db: &AsyncDaemonDb) {
    if db
        .task_board_configuration_revision()
        .await
        .expect("configuration revision")
        == 0
    {
        db.replace_task_board_orchestrator_settings(&TaskBoardOrchestratorSettings::default())
            .await
            .expect("seed orchestrator settings");
    }
}

fn pull_request(workflow_kind: TaskBoardWorkflowKind) -> Option<TaskBoardPullRequestIdentity> {
    (workflow_kind == TaskBoardWorkflowKind::PrReview).then(|| TaskBoardPullRequestIdentity {
        repository: "example/compass".into(),
        number: 17,
    })
}

async fn seed_attempt(
    db: &AsyncDaemonDb,
    execution: &TaskBoardWorkflowExecutionRecord,
    seed: AttemptSeed,
) {
    let profile = &execution.resolved_reviewers.profiles[0];
    db.create_task_board_execution_attempt(&TaskBoardExecutionAttemptRecord {
        execution_id: execution.execution_id.clone(),
        action_key: format!("review:{}", profile.id),
        attempt: 1,
        idempotency_key: format!("codex-{}-review-1", execution.execution_id),
        state: seed.state,
        failure_class: seed.failure_class,
        available_at: seed.available_at.map(str::to_owned),
        error: seed.error.map(str::to_owned),
        artifact: None,
        started_at: NOW.into(),
        updated_at: NOW.into(),
        completed_at: seed.completed_at.map(str::to_owned),
    })
    .await
    .expect("seed workflow attempt");
}

async fn insert_committed_admission(
    db: &AsyncDaemonDb,
    item_id: &str,
    execution_id: &str,
    item_revision: i64,
) {
    let intent_id = format!("intent-{execution_id}");
    let decision_id = format!("decision-{execution_id}");
    sqlx::query(
        "INSERT INTO task_board_dispatch_intents (
         intent_id, item_id, session_id, work_item_id, workflow_execution_id,
         payload_json, status, attempts, available_at, created_at, updated_at, completed_at
         ) VALUES (?1, ?2, ?3, ?4, ?5, '{}', 'completed', 1, ?6, ?6, ?6, ?6)",
    )
    .bind(&intent_id)
    .bind(item_id)
    .bind(format!("session-{item_id}"))
    .bind(format!("work-{item_id}"))
    .bind(execution_id)
    .bind(NOW)
    .execute(db.pool())
    .await
    .expect("insert completed dispatch intent");
    sqlx::query(
        "INSERT INTO task_board_dispatch_admission_decisions (
         decision_id, intent_id, generation, item_id, item_revision, settings_revision,
         decision, policy_json, context_json, requirements_json, blockers_json,
         launch_profile, evaluated_at, is_current, created_at
         ) VALUES (?1, ?2, 1, ?3, ?4, 1, 'allowed', '{}', '{}', '[]', '[]',
                   'read_only', ?5, 1, ?5)",
    )
    .bind(&decision_id)
    .bind(&intent_id)
    .bind(item_id)
    .bind(item_revision)
    .bind(NOW)
    .execute(db.pool())
    .await
    .expect("insert admission decision");
    sqlx::query(
        "INSERT INTO task_board_dispatch_admission_ledger (
         ledger_id, decision_id, decision, intent_id, generation, item_id,
         canonical_key, kind, scope, amount, limit_value, state, managed_worker_id,
         reserved_at, committed_at
         ) VALUES (?1, ?2, 'allowed', ?3, 1, ?4, 'concurrency:global', 'concurrency',
                   'global', 1, 1, 'committed', ?5, ?6, ?6)",
    )
    .bind(format!("ledger-{execution_id}"))
    .bind(decision_id)
    .bind(intent_id)
    .bind(item_id)
    .bind(workflow_owner(execution_id))
    .bind(NOW)
    .execute(db.pool())
    .await
    .expect("insert committed admission");
}

pub(super) async fn admission_state(fixture: &Fixture) -> String {
    sqlx::query_scalar(
        "SELECT state FROM task_board_dispatch_admission_ledger WHERE ledger_id = ?1",
    )
    .bind(format!("ledger-{}", fixture.execution_id))
    .fetch_one(fixture.test.db.pool())
    .await
    .expect("load admission state")
}

pub(super) async fn seed_publish_attempt(
    label: &str,
    parent_state: TaskBoardExecutionState,
    attempt_state: TaskBoardAttemptState,
) -> Fixture {
    let fixture = seed_execution_at_phase(
        label,
        TaskBoardWorkflowKind::PrReview,
        crate::task_board::TaskBoardExecutionPhase::Publish,
        parent_state,
        None,
    )
    .await;
    fixture
        .test
        .db
        .create_task_board_execution_attempt(&TaskBoardExecutionAttemptRecord {
            execution_id: fixture.execution_id.clone(),
            action_key: "publish".into(),
            attempt: 1,
            idempotency_key: format!("publish-{}-1", fixture.execution_id),
            state: attempt_state,
            failure_class: None,
            available_at: None,
            error: None,
            artifact: None,
            started_at: NOW.into(),
            updated_at: NOW.into(),
            completed_at: None,
        })
        .await
        .expect("seed publish attempt");
    fixture
}

pub(super) async fn seed_dispatched_initial_report(label: &str) -> Fixture {
    let test = TestDatabase::open().await;
    seed_settings(&test.db).await;
    let item_id = format!("coordinator-{label}");
    let mut item = TaskBoardItem::new(
        item_id.clone(),
        format!("Read-only workflow {label}"),
        "Inspect the exact frozen revision".into(),
        NOW.into(),
    );
    item.agent_mode = AgentMode::Evaluate;
    item.workflow_kind = TaskBoardWorkflowKind::Review;
    test.db
        .create_task_board_item(item.clone())
        .await
        .expect("create dispatched report item");
    let plan = build_dispatch_plans_with_policy(
        &[item],
        None,
        None,
        SpawnGateSwitches::default(),
        &HashMap::new(),
    )
    .remove(0);
    let intent_id = match test
        .db
        .reserve_task_board_dispatch(&plan, "control-plane", Some("/tmp/project"), false)
        .await
        .expect("reserve dispatched report")
    {
        crate::daemon::db::ReservedTaskBoardDispatch::Preparing { intent_id, .. } => intent_id,
        other => panic!("unexpected dispatched report reservation: {other:?}"),
    };
    let preparation = test
        .db
        .claim_task_board_dispatch_preparation(&intent_id)
        .await
        .expect("claim dispatched report preparation")
        .expect("pending dispatched report preparation");
    let snapshot = test
        .db
        .task_board_item_snapshot(&item_id)
        .await
        .expect("dispatched report source item");
    let settings = test
        .db
        .task_board_orchestrator_settings_snapshot()
        .await
        .expect("dispatched report settings");
    let launch = TaskBoardReadOnlyWorkflowLaunch {
        workflow_kind: TaskBoardWorkflowKind::Review,
        execution_repository: None,
        configuration_revision: u64::try_from(settings.row_revision).expect("settings revision"),
        policy_version: settings.settings.policy_version,
        resolved_reviewers: resolve_task_board_reviewers(
            &settings.settings.reviewers,
            TaskBoardWorkflowKind::Review,
            None,
        )
        .expect("dispatched report reviewers"),
        source_item_revision: snapshot.item_revision,
        prepared_item_revision: snapshot.item_revision,
        run_context: TaskBoardReadOnlyRunContext {
            schema_version: TASK_BOARD_READ_ONLY_RUN_CONTEXT_VERSION,
            session_id: preparation.preparation.session_id.clone(),
            title: snapshot.item.title,
            body: snapshot.item.body,
            tags: snapshot.item.tags,
            worktree: "/tmp/read-only-worktree".into(),
        },
        provider_revision: None,
        pull_request: None,
        exact_head_revision: FROZEN_HEAD.into(),
    };
    let applied = test
        .db
        .complete_task_board_dispatch_preparation_with_workflow(
            &preparation,
            "branch",
            "/tmp/read-only-worktree",
            Some(launch),
            None,
        )
        .await
        .expect("complete dispatched report preparation");
    let execution_id = applied
        .item
        .workflow
        .execution_id
        .clone()
        .expect("dispatched report execution id");
    let claim = test
        .db
        .claim_task_board_dispatch(&item_id)
        .await
        .expect("claim dispatched report")
        .expect("pending dispatched report");
    test.db
        .complete_task_board_dispatch(
            &intent_id,
            &claim.claim_token,
            &workflow_owner(&execution_id),
        )
        .await
        .expect("persist dispatched report workflow before worker start");
    Fixture {
        test,
        item_id,
        execution_id,
    }
}
