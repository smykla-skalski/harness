use std::collections::BTreeMap;

use super::*;
use crate::daemon::db::workflow_owner;
use crate::task_board::{
    AgentMode, TaskBoardExecutionOwnership, TaskBoardExecutionPhase, TaskBoardExecutionState,
    TaskBoardOrchestratorSettings, TaskBoardResolvedReviewer, TaskBoardReviewerProfile,
    TaskBoardTerminalOutcome, TaskBoardTerminalOutcomeKind, TaskBoardWorkflowExecutionArtifacts,
    TaskBoardWorkflowExecutionCas, TaskBoardWorkflowExecutionCasOutcome,
    TaskBoardWorkflowExecutionRecord, TaskBoardWorkflowKind, TaskBoardWorkflowSnapshot,
    TaskBoardWorkflowStatus, TaskBoardWorkflowTransitionState, start_task_board_workflow,
};

pub(super) const NOW: &str = "2026-07-17T10:00:00Z";

#[tokio::test]
async fn active_execution_adopts_only_the_exact_frozen_contract() {
    let (db, _temp) = workflow_database().await;
    let record = create_execution(&db, "task-exact", "2026-07-17T09:00:00Z").await;
    let sequence = db.current_change_sequence().await.expect("change sequence");

    let adopted = db
        .create_or_load_task_board_workflow_execution(&record)
        .await
        .expect("adopt exact execution");
    assert!(!adopted.created);
    assert_eq!(adopted.execution, record);
    assert_eq!(
        db.current_change_sequence().await.expect("change sequence"),
        sequence
    );

    let running = set_state(
        &db,
        record.clone(),
        TaskBoardExecutionState::Running,
        None,
        "2026-07-17T09:05:00Z",
    )
    .await;
    let sequence = db.current_change_sequence().await.expect("change sequence");
    let resumed = db
        .create_or_load_task_board_workflow_execution(&record)
        .await
        .expect("adopt progressed exact execution");
    assert!(!resumed.created);
    assert_eq!(resumed.execution, running);
    assert_eq!(
        db.current_change_sequence().await.expect("change sequence"),
        sequence
    );
}

#[tokio::test]
async fn active_execution_rejects_conflicting_identity_or_frozen_contract() {
    let (db, _temp) = workflow_database().await;
    let record = create_execution(&db, "task-conflict", "2026-07-17T09:00:00Z").await;
    let sequence = db.current_change_sequence().await.expect("change sequence");
    let mut conflicting_id = record.clone();
    conflicting_id.execution_id = "execution-conflicting".into();
    let mut conflicting_contract = record.clone();
    conflicting_contract.snapshot.policy_version = "policy-v2".into();

    for conflict in [&conflicting_id, &conflicting_contract] {
        let error = db
            .create_or_load_task_board_workflow_execution(conflict)
            .await
            .expect_err("conflicting active execution must fail");
        assert!(error.to_string().contains("immutable contract"));
    }

    assert_eq!(
        db.task_board_workflow_execution(&record.execution_id)
            .await
            .expect("load original execution"),
        Some(record)
    );
    assert_eq!(
        db.current_change_sequence().await.expect("change sequence"),
        sequence
    );
}

#[tokio::test]
async fn admission_ready_and_recoverable_queues_are_disjoint_and_ordered() {
    let (db, _temp) = workflow_database().await;
    let retry_due = create_execution(&db, "task-retry-due", "2026-07-17T09:00:00Z").await;
    let _pending = create_execution(&db, "task-pending", "2026-07-17T09:45:00Z").await;
    let retry_future = create_execution(&db, "task-retry-future", "2026-07-17T09:05:00Z").await;
    let preparing = create_execution(&db, "task-preparing", "2026-07-17T09:10:00Z").await;
    let starting = create_execution(&db, "task-starting", "2026-07-17T09:20:00Z").await;
    let running = create_execution(&db, "task-running", "2026-07-17T09:30:00Z").await;
    set_state(
        &db,
        retry_due,
        TaskBoardExecutionState::RetryWait,
        Some("2026-07-17T09:30:00Z"),
        "2026-07-17T09:00:00Z",
    )
    .await;
    set_state(
        &db,
        retry_future,
        TaskBoardExecutionState::RetryWait,
        Some("2026-07-17T11:00:00Z"),
        "2026-07-17T09:05:00Z",
    )
    .await;
    set_state(
        &db,
        preparing,
        TaskBoardExecutionState::Preparing,
        None,
        "2026-07-17T09:50:00Z",
    )
    .await;
    set_state(
        &db,
        starting,
        TaskBoardExecutionState::Starting,
        None,
        "2026-07-17T09:40:00Z",
    )
    .await;
    set_state(
        &db,
        running,
        TaskBoardExecutionState::Running,
        None,
        "2026-07-17T09:30:00Z",
    )
    .await;

    let ready = db
        .ready_task_board_workflow_executions(NOW, 10)
        .await
        .expect("load admission-ready executions");
    assert_eq!(
        execution_ids(&ready),
        ["execution-task-retry-due", "execution-task-pending"]
    );
    assert_eq!(
        execution_ids(
            &db.ready_task_board_workflow_executions(NOW, 1)
                .await
                .expect("independently bounded ready queue")
        ),
        ["execution-task-retry-due"]
    );
    let recoverable = db
        .recoverable_task_board_workflow_executions(10)
        .await
        .expect("load recoverable executions");
    assert_eq!(
        execution_ids(&recoverable),
        [
            "execution-task-running",
            "execution-task-starting",
            "execution-task-preparing"
        ]
    );
    assert_eq!(
        execution_ids(
            &db.recoverable_task_board_workflow_executions(1)
                .await
                .expect("independently bounded recovery queue")
        ),
        ["execution-task-running"]
    );
    assert!(
        db.ready_task_board_workflow_executions(NOW, 0)
            .await
            .expect("zero ready limit")
            .is_empty()
    );
    assert!(
        db.recoverable_task_board_workflow_executions(0)
            .await
            .expect("zero recovery limit")
            .is_empty()
    );
}

#[tokio::test]
async fn terminal_queue_includes_unprojected_execution_without_a_concurrency_ledger() {
    let (db, _temp) = workflow_database().await;
    let execution = create_unprojected_terminal_execution(&db, "task-no-ledger").await;

    let projectable = db
        .projectable_task_board_read_only_workflow_executions(10)
        .await
        .expect("load terminal projection queue");

    assert_eq!(
        execution_ids(&projectable),
        [execution.execution_id.as_str()]
    );
    let ledger_count = sqlx::query_scalar::<_, i64>(
        "SELECT COUNT(*) FROM task_board_dispatch_admission_ledger
         WHERE managed_worker_id = ?1",
    )
    .bind(workflow_owner(&execution.execution_id))
    .fetch_one(db.pool())
    .await
    .expect("count workflow admission ledger rows");
    assert_eq!(ledger_count, 0);
}

#[tokio::test]
async fn terminal_queue_excludes_no_ledger_execution_after_projection() {
    let (db, _temp) = workflow_database().await;
    let execution = create_unprojected_terminal_execution(&db, "task-projected").await;

    let projection = db
        .project_task_board_read_only_workflow_terminal(&execution.execution_id)
        .await
        .expect("project terminal execution without an admission ledger");

    assert!(projection.item_changed);
    assert!(!projection.admission_released);
    assert!(
        db.projectable_task_board_read_only_workflow_executions(10)
            .await
            .expect("reload terminal projection queue")
            .is_empty()
    );
}

pub(super) async fn workflow_database() -> (AsyncDaemonDb, tempfile::TempDir) {
    let temp = tempfile::tempdir().expect("tempdir");
    let db = AsyncDaemonDb::connect(&temp.path().join("harness.db"))
        .await
        .expect("open database");
    db.replace_task_board_orchestrator_settings(&TaskBoardOrchestratorSettings::default())
        .await
        .expect("seed settings");
    (db, temp)
}

pub(super) async fn create_execution(
    db: &AsyncDaemonDb,
    item_id: &str,
    created_at: &str,
) -> TaskBoardWorkflowExecutionRecord {
    let reviewers = resolved_reviewers();
    let mut item = TaskBoardItem::new(
        item_id.into(),
        "Read-only workflow".into(),
        "Repository queue fixture".into(),
        created_at.into(),
    );
    item.workflow_kind = TaskBoardWorkflowKind::Review;
    item.execution_repository = Some("example/harness".into());
    let mutation = db
        .create_task_board_item(item)
        .await
        .expect("create workflow item");
    let snapshot = TaskBoardWorkflowSnapshot {
        workflow_kind: TaskBoardWorkflowKind::Review,
        execution_repository: Some("example/harness".into()),
        item_revision: mutation.item_revision,
        configuration_revision: db
            .task_board_configuration_revision()
            .await
            .expect("configuration revision"),
        policy_version: "policy-v1".into(),
        reviewer: reviewers.clone(),
        read_only_run_context: Some(crate::task_board::TaskBoardReadOnlyRunContext {
            schema_version: crate::task_board::TASK_BOARD_READ_ONLY_RUN_CONTEXT_VERSION,
            session_id: format!("session-{item_id}"),
            title: "Read-only workflow".into(),
            body: "Repository queue fixture".into(),
            tags: Vec::new(),
            worktree: "/tmp/read-only-worktree".into(),
        }),
        provider_revision: None,
    };
    let record = TaskBoardWorkflowExecutionRecord {
        execution_id: format!("execution-{item_id}"),
        item_id: item_id.into(),
        snapshot,
        resolved_reviewers: reviewers,
        transition: start_task_board_workflow(
            TaskBoardWorkflowKind::Review,
            None,
            Some("head-exact"),
        )
        .expect("start workflow"),
        artifacts: TaskBoardWorkflowExecutionArtifacts::default(),
        ownership: TaskBoardExecutionOwnership {
            host_id: None,
            fencing_epoch: 0,
            resources: BTreeMap::new(),
        },
        available_at: None,
        blocked_reason: None,
        created_at: created_at.into(),
        updated_at: created_at.into(),
        completed_at: None,
        attempts: Vec::new(),
    };
    db.create_or_load_task_board_workflow_execution(&record)
        .await
        .expect("create workflow execution")
        .execution
}

async fn create_unprojected_terminal_execution(
    db: &AsyncDaemonDb,
    item_id: &str,
) -> TaskBoardWorkflowExecutionRecord {
    let execution_id = format!("execution-{item_id}");
    let reviewers = resolved_reviewers();
    let mut item = TaskBoardItem::new(
        item_id.into(),
        "Read-only workflow".into(),
        "Terminal projection fixture".into(),
        NOW.into(),
    );
    item.status = crate::task_board::TaskBoardStatus::InProgress;
    item.workflow_kind = TaskBoardWorkflowKind::Review;
    item.execution_repository = Some("example/harness".into());
    item.workflow.execution_id = Some(execution_id.clone());
    item.workflow.status = TaskBoardWorkflowStatus::Running;
    item.workflow.current_step_id = Some("cleanup".into());
    let mutation = db
        .create_task_board_item(item)
        .await
        .expect("create terminal workflow item");
    let record = TaskBoardWorkflowExecutionRecord {
        execution_id,
        item_id: item_id.into(),
        snapshot: TaskBoardWorkflowSnapshot {
            workflow_kind: TaskBoardWorkflowKind::Review,
            execution_repository: Some("example/harness".into()),
            item_revision: mutation.item_revision,
            configuration_revision: db
                .task_board_configuration_revision()
                .await
                .expect("configuration revision"),
            policy_version: "policy-v1".into(),
            reviewer: reviewers.clone(),
            read_only_run_context: Some(crate::task_board::TaskBoardReadOnlyRunContext {
                schema_version: crate::task_board::TASK_BOARD_READ_ONLY_RUN_CONTEXT_VERSION,
                session_id: format!("session-{item_id}"),
                title: "Read-only workflow".into(),
                body: "Terminal projection fixture".into(),
                tags: Vec::new(),
                worktree: "/tmp/read-only-worktree".into(),
            }),
            provider_revision: None,
        },
        resolved_reviewers: reviewers,
        transition: TaskBoardWorkflowTransitionState {
            workflow_kind: TaskBoardWorkflowKind::Review,
            phase: Some(TaskBoardExecutionPhase::Terminal),
            execution_state: TaskBoardExecutionState::Completed,
            pull_request: None,
            exact_head_revision: Some("head-exact".into()),
        },
        artifacts: TaskBoardWorkflowExecutionArtifacts {
            terminal_outcome: Some(TaskBoardTerminalOutcome {
                kind: TaskBoardTerminalOutcomeKind::Succeeded,
                summary: "review completed".into(),
                recorded_at: NOW.into(),
            }),
            ..TaskBoardWorkflowExecutionArtifacts::default()
        },
        ownership: TaskBoardExecutionOwnership {
            host_id: None,
            fencing_epoch: 0,
            resources: BTreeMap::from([(
                "admission_owner".into(),
                workflow_owner(&format!("execution-{item_id}")),
            )]),
        },
        available_at: None,
        blocked_reason: None,
        created_at: NOW.into(),
        updated_at: NOW.into(),
        completed_at: Some(NOW.into()),
        attempts: Vec::new(),
    };
    db.create_or_load_task_board_workflow_execution(&record)
        .await
        .expect("create terminal workflow execution")
        .execution
}

fn resolved_reviewers() -> TaskBoardResolvedReviewer {
    TaskBoardResolvedReviewer {
        reviewer_count: 1,
        required_approvals: 1,
        max_revision_cycles: 3,
        profiles: vec![TaskBoardReviewerProfile {
            id: "reviewer".into(),
            runtime: "codex".into(),
            persona: "code-reviewer".into(),
            agent_mode: AgentMode::Evaluate,
            model: None,
            effort: None,
        }],
    }
}

pub(super) async fn set_state(
    db: &AsyncDaemonDb,
    current: TaskBoardWorkflowExecutionRecord,
    state: TaskBoardExecutionState,
    available_at: Option<&str>,
    updated_at: &str,
) -> TaskBoardWorkflowExecutionRecord {
    let mut updated = current.clone();
    updated.transition.execution_state = state;
    updated.available_at = available_at.map(str::to_owned);
    updated.updated_at = updated_at.into();
    let outcome = db
        .compare_and_set_task_board_workflow_execution(
            &TaskBoardWorkflowExecutionCas::from(&current),
            &updated,
        )
        .await
        .expect("set execution state");
    match outcome {
        TaskBoardWorkflowExecutionCasOutcome::Updated(record) => record,
        other => panic!("expected updated execution, got {other:?}"),
    }
}

pub(super) fn execution_ids<const N: usize>(
    executions: &[TaskBoardWorkflowExecutionRecord],
) -> [&str; N] {
    executions
        .iter()
        .map(|execution| execution.execution_id.as_str())
        .collect::<Vec<_>>()
        .try_into()
        .ok()
        .expect("expected execution count")
}
