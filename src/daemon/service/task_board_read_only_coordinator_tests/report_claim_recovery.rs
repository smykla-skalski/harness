use crate::daemon::db::AsyncDaemonDb;
use crate::task_board::{
    TaskBoardAttemptState, TaskBoardExecutionState, TaskBoardFailureClass, TaskBoardWorkflowKind,
};

use super::fixture::{AttemptSeed, NOW, RETRY_AT, seed_dispatched_initial_report, seed_execution};
use super::load_execution;
use super::runtime::{FakeReadOnlyRuntime, PlannedReport};

#[tokio::test]
async fn second_reconciler_waits_for_claimed_report_without_orphaning_run() {
    let fixture = seed_execution(
        "report-exclusive",
        TaskBoardWorkflowKind::Review,
        TaskBoardExecutionState::Running,
        Some(starting_attempt()),
    )
    .await;
    let runtime = FakeReadOnlyRuntime::new([PlannedReport::passing_review()]);
    runtime.block_report();

    let first = super::super::task_board_read_only_coordinator::
        reconcile_task_board_read_only_workflows_with_runtime(&fixture.test.db, &runtime, NOW, 8);
    let observe_and_reconcile = async {
        runtime.wait_for_report_start().await;
        let claimed = load_execution(&fixture).await;
        assert_eq!(
            claimed.transition.execution_state,
            TaskBoardExecutionState::Starting
        );
        assert_eq!(claimed.attempts[0].state, TaskBoardAttemptState::Running);
        assert!(claimed.attempts[0].available_at.is_some());
        let second = super::super::task_board_read_only_coordinator::
            reconcile_task_board_read_only_workflows_with_runtime(
                &fixture.test.db,
                &runtime,
                NOW,
                8,
            )
            .await
            .expect("second report reconciliation");
        assert!(second.failures.is_empty(), "{:?}", second.failures);
        let still_claimed = load_execution(&fixture).await;
        assert_eq!(
            still_claimed.attempts[0].state,
            TaskBoardAttemptState::Running
        );
        assert_eq!(runtime.start_count(), 1);
        runtime.release_report();
    };
    let (first, ()) = tokio::join!(first, observe_and_reconcile);
    assert!(
        first
            .expect("first report reconciliation")
            .failures
            .is_empty()
    );
    assert_eq!(runtime.start_count(), 1);
    assert_eq!(
        load_execution(&fixture).await.attempts[0].state,
        TaskBoardAttemptState::Completed
    );
}

#[tokio::test]
async fn missing_claimed_report_waits_until_deadline_then_becomes_unknown() {
    let fixture = seed_execution(
        "report-missing-grace",
        TaskBoardWorkflowKind::Review,
        TaskBoardExecutionState::Running,
        Some(AttemptSeed {
            state: TaskBoardAttemptState::Running,
            failure_class: None,
            available_at: Some(RETRY_AT),
            error: None,
            completed_at: None,
        }),
    )
    .await;
    let runtime = FakeReadOnlyRuntime::new([]);

    let before_deadline = super::super::task_board_read_only_coordinator::
        reconcile_task_board_read_only_workflows_with_runtime(&fixture.test.db, &runtime, NOW, 8)
        .await
        .expect("wait for report claim deadline");
    assert!(before_deadline.failures.is_empty());
    assert_eq!(
        load_execution(&fixture).await.attempts[0].state,
        TaskBoardAttemptState::Running
    );

    let after_deadline = super::super::task_board_read_only_coordinator::
        reconcile_task_board_read_only_workflows_with_runtime(
            &fixture.test.db,
            &runtime,
            "2026-07-17T10:06:00Z",
            8,
        )
        .await
        .expect("settle missing claimed report");
    assert!(after_deadline.failures.is_empty());
    let execution = load_execution(&fixture).await;
    assert_eq!(execution.attempts[0].state, TaskBoardAttemptState::Unknown);
    assert_eq!(
        execution.transition.execution_state,
        TaskBoardExecutionState::HumanRequired
    );
    assert_eq!(runtime.start_count(), 0);
}

#[tokio::test]
async fn failed_start_without_durable_run_enters_retry_wait() {
    let fixture = seed_execution(
        "report-start-absent",
        TaskBoardWorkflowKind::Review,
        TaskBoardExecutionState::Running,
        Some(starting_attempt()),
    )
    .await;
    let runtime = FakeReadOnlyRuntime::new([]);

    let report = super::super::task_board_read_only_coordinator::
        reconcile_task_board_read_only_workflows_with_runtime(
            &fixture.test.db,
            &runtime,
            NOW,
            8,
        )
        .await
        .expect("reconcile absent durable report after start error");

    assert!(report.failures.is_empty(), "{:?}", report.failures);
    let execution = load_execution(&fixture).await;
    assert_eq!(
        execution.attempts[0].state,
        TaskBoardAttemptState::RetryWait
    );
    assert_eq!(
        execution.attempts[0].failure_class,
        Some(TaskBoardFailureClass::Transient)
    );
    assert_eq!(
        execution.transition.execution_state,
        TaskBoardExecutionState::RetryWait
    );
    assert_eq!(runtime.start_count(), 1);
}

#[tokio::test]
async fn failed_start_with_durable_run_reconciles_without_duplicate() {
    let fixture = seed_execution(
        "report-start-durable",
        TaskBoardWorkflowKind::Review,
        TaskBoardExecutionState::Running,
        Some(starting_attempt()),
    )
    .await;
    let runtime = FakeReadOnlyRuntime::new([PlannedReport::passing_review()]);
    runtime.fail_next_start_after_persist();

    let first = super::super::task_board_read_only_coordinator::
        reconcile_task_board_read_only_workflows_with_runtime(
            &fixture.test.db,
            &runtime,
            NOW,
            8,
        )
        .await
        .expect("reconcile durable report after start response loss");
    assert!(first.failures.is_empty(), "{:?}", first.failures);
    assert_eq!(
        load_execution(&fixture).await.attempts[0].state,
        TaskBoardAttemptState::Completed
    );

    let second = super::super::task_board_read_only_coordinator::
        reconcile_task_board_read_only_workflows_with_runtime(
            &fixture.test.db,
            &runtime,
            NOW,
            8,
        )
        .await
        .expect("ingest recovered durable report");
    assert!(second.failures.is_empty(), "{:?}", second.failures);
    assert_eq!(runtime.start_count(), 1);
}

#[tokio::test]
async fn initial_dispatched_report_grace_survives_restart_before_worker_start() {
    let fixture = seed_dispatched_initial_report("initial-report-grace").await;
    let before = load_execution(&fixture).await;
    let attempt = &before.attempts[0];
    assert_eq!(attempt.state, TaskBoardAttemptState::Running);
    let deadline = chrono::DateTime::parse_from_rfc3339(
        attempt
            .available_at
            .as_deref()
            .expect("persisted initial report deadline"),
    )
    .expect("parse initial report deadline");
    let started = chrono::DateTime::parse_from_rfc3339(&attempt.started_at)
        .expect("parse initial report start");
    assert_eq!(
        deadline.signed_duration_since(started),
        chrono::Duration::seconds(crate::task_board::TASK_BOARD_SIDE_EFFECT_CLAIM_GRACE_SECONDS)
    );
    assert_eq!(codex_run_count(&fixture.test.db).await, 0);

    let runtime = FakeReadOnlyRuntime::new([]);
    let first = super::super::task_board_read_only_coordinator::
        reconcile_task_board_read_only_workflows_with_runtime(
            &fixture.test.db,
            &runtime,
            &attempt.started_at,
            8,
        )
        .await
        .expect("reconcile before initial report deadline");
    assert!(first.failures.is_empty());
    assert_eq!(load_execution(&fixture).await, before);
    assert_eq!(runtime.start_count(), 0);

    let restarted = AsyncDaemonDb::connect(&fixture.test.path)
        .await
        .expect("reopen workflow database after simulated restart");
    let restarted_runtime = FakeReadOnlyRuntime::new([]);
    let second = super::super::task_board_read_only_coordinator::
        reconcile_task_board_read_only_workflows_with_runtime(
            &restarted,
            &restarted_runtime,
            &attempt.started_at,
            8,
        )
        .await
        .expect("reconcile restarted workflow before deadline");
    assert!(second.failures.is_empty());
    assert_eq!(
        restarted
            .task_board_workflow_execution(&fixture.execution_id)
            .await
            .expect("load restarted workflow")
            .expect("restarted workflow"),
        before
    );

    let expired = (deadline + chrono::Duration::seconds(1)).to_rfc3339();
    let after = super::super::task_board_read_only_coordinator::
        reconcile_task_board_read_only_workflows_with_runtime(
            &restarted,
            &restarted_runtime,
            &expired,
            8,
        )
        .await
        .expect("settle expired initial report claim");
    assert!(after.failures.is_empty());
    let settled = restarted
        .task_board_workflow_execution(&fixture.execution_id)
        .await
        .expect("load settled workflow")
        .expect("settled workflow");
    assert_eq!(settled.attempts.len(), 1);
    assert_eq!(settled.attempts[0].state, TaskBoardAttemptState::Unknown);
    assert_eq!(
        settled.attempts[0].failure_class,
        Some(TaskBoardFailureClass::UnknownOutcome)
    );
    assert_eq!(
        settled.transition.execution_state,
        TaskBoardExecutionState::HumanRequired
    );
    assert_eq!(restarted_runtime.start_count(), 0);
    assert_eq!(codex_run_count(&restarted).await, 0);
}

async fn codex_run_count(db: &AsyncDaemonDb) -> i64 {
    sqlx::query_scalar("SELECT COUNT(*) FROM codex_runs")
        .fetch_one(db.pool())
        .await
        .expect("count Codex runs")
}

const fn starting_attempt() -> AttemptSeed {
    AttemptSeed {
        state: TaskBoardAttemptState::Starting,
        failure_class: None,
        available_at: None,
        error: None,
        completed_at: None,
    }
}
