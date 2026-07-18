use crate::daemon::protocol::CodexRunStatus;
use crate::task_board::{
    TaskBoardAttemptState, TaskBoardExecutionState, TaskBoardFailureClass,
    TaskBoardTerminalOutcomeKind, TaskBoardWorkflowKind,
};

use super::fixture::{AttemptSeed, NOW, RETRY_AT, seed_execution, seed_publish_attempt};
use super::runtime::{FakeReadOnlyRuntime, PlannedReport};
use super::{load_execution, tick};

#[tokio::test]
async fn retry_wait_child_recovers_running_starting_and_pending_parents_without_launch() {
    for (label, parent) in [
        ("retry-running", TaskBoardExecutionState::Running),
        ("retry-starting", TaskBoardExecutionState::Starting),
        ("retry-pending", TaskBoardExecutionState::Pending),
    ] {
        let fixture = seed_execution(
            label,
            TaskBoardWorkflowKind::Review,
            parent,
            Some(AttemptSeed::retry_wait(RETRY_AT)),
        )
        .await;
        let runtime = FakeReadOnlyRuntime::new([]);

        tick(&fixture, &runtime, NOW).await;

        let execution = load_execution(&fixture).await;
        assert_eq!(
            execution.transition.execution_state,
            TaskBoardExecutionState::RetryWait
        );
        assert_eq!(execution.attempts.len(), 1);
        assert_eq!(
            execution.attempts[0].state,
            TaskBoardAttemptState::RetryWait
        );
        assert_eq!(
            execution
                .artifacts
                .retry
                .as_ref()
                .map(|retry| retry.next_attempt),
            Some(2)
        );
        assert_eq!(runtime.start_count(), 0);
    }
}

#[tokio::test]
async fn due_recovered_retry_progresses_to_attempt_n_plus_one() {
    let fixture = seed_execution(
        "retry-progress",
        TaskBoardWorkflowKind::Review,
        TaskBoardExecutionState::Running,
        Some(AttemptSeed::retry_wait(NOW)),
    )
    .await;
    let runtime = FakeReadOnlyRuntime::new([]);

    tick(&fixture, &runtime, NOW).await;
    tick(&fixture, &runtime, NOW).await;
    tick(&fixture, &runtime, NOW).await;

    let execution = load_execution(&fixture).await;
    assert_eq!(
        execution.transition.execution_state,
        TaskBoardExecutionState::Preparing
    );
    assert_eq!(execution.attempts.len(), 2);
    assert_eq!(execution.attempts[1].attempt, 2);
    assert_eq!(
        execution.attempts[1].state,
        TaskBoardAttemptState::Preparing
    );
    assert_eq!(runtime.start_count(), 0);
}

#[tokio::test]
async fn unknown_and_cancelled_children_never_launch_attempt_n_plus_one() {
    for (label, parent, seed, expected_kind) in [
        (
            "unknown-child",
            TaskBoardExecutionState::Running,
            AttemptSeed::unknown(),
            TaskBoardTerminalOutcomeKind::Unknown,
        ),
        (
            "cancelled-child",
            TaskBoardExecutionState::Starting,
            AttemptSeed::cancelled(),
            TaskBoardTerminalOutcomeKind::HumanRequired,
        ),
    ] {
        let fixture =
            seed_execution(label, TaskBoardWorkflowKind::Review, parent, Some(seed)).await;
        let runtime = FakeReadOnlyRuntime::new([]);

        tick(&fixture, &runtime, NOW).await;

        let execution = load_execution(&fixture).await;
        assert_eq!(
            execution.transition.execution_state,
            TaskBoardExecutionState::HumanRequired
        );
        assert_eq!(execution.attempts.len(), 1);
        assert_eq!(
            execution
                .artifacts
                .terminal_outcome
                .as_ref()
                .map(|outcome| outcome.kind),
            Some(expected_kind)
        );
        assert!(execution.artifacts.review_cycles.is_empty());
        assert_eq!(runtime.start_count(), 0);
    }
}

#[tokio::test]
async fn provider_head_resolution_error_schedules_durable_retry_wait() {
    let fixture = seed_execution(
        "provider-retry",
        TaskBoardWorkflowKind::Review,
        TaskBoardExecutionState::Pending,
        None,
    )
    .await;
    let runtime = FakeReadOnlyRuntime::new([PlannedReport::passing_review()]);
    runtime.set_head_error("provider exact-head lookup unavailable");

    tick(&fixture, &runtime, NOW).await;
    tick(&fixture, &runtime, NOW).await;
    tick(&fixture, &runtime, NOW).await;

    let execution = load_execution(&fixture).await;
    assert_eq!(
        execution.transition.execution_state,
        TaskBoardExecutionState::RetryWait
    );
    assert_eq!(execution.attempts.len(), 1);
    assert_eq!(
        execution.attempts[0].state,
        TaskBoardAttemptState::Completed
    );
    let retry = execution
        .artifacts
        .retry
        .as_ref()
        .expect("resolution retry");
    assert_eq!(retry.failure_class, TaskBoardFailureClass::Transient);
    assert!(!retry.available_at.is_empty());
    assert_eq!(runtime.start_count(), 1);
}

#[tokio::test]
async fn starting_publish_child_repairs_running_parent_before_side_effect() {
    let fixture = seed_publish_attempt(
        "publish-parent-repair",
        TaskBoardExecutionState::Running,
        TaskBoardAttemptState::Starting,
    )
    .await;
    let runtime = FakeReadOnlyRuntime::new([]);
    runtime.block_publish();

    let reconcile = super::super::task_board_read_only_coordinator::
        reconcile_task_board_read_only_workflows_with_runtime(
            &fixture.test.db,
            &runtime,
            NOW,
            8,
        );
    let observe = async {
        runtime.wait_for_publish().await;
        let execution = load_execution(&fixture).await;
        assert_eq!(
            execution.transition.execution_state,
            TaskBoardExecutionState::Starting
        );
        runtime.release_publish();
    };
    let (report, ()) = tokio::join!(reconcile, observe);
    assert!(report.expect("reconcile publish").failures.is_empty());

    let execution = load_execution(&fixture).await;
    assert_eq!(
        execution.transition.execution_state,
        TaskBoardExecutionState::Running
    );
    assert_eq!(
        execution.attempts[0].state,
        TaskBoardAttemptState::Completed
    );
    assert_eq!(runtime.publish_count(), 1);
}

#[tokio::test]
async fn contextless_legacy_execution_fails_closed_without_launch() {
    let fixture = seed_execution(
        "contextless",
        TaskBoardWorkflowKind::Review,
        TaskBoardExecutionState::Pending,
        None,
    )
    .await;
    sqlx::query(
        "UPDATE task_board_workflow_executions
         SET snapshot_json = json_remove(snapshot_json, '$.read_only_run_context')
         WHERE execution_id = ?1",
    )
    .bind(&fixture.execution_id)
    .execute(fixture.test.db.pool())
    .await
    .expect("remove legacy run context");
    let runtime = FakeReadOnlyRuntime::new([]);

    tick(&fixture, &runtime, NOW).await;

    let execution = load_execution(&fixture).await;
    assert_eq!(
        execution.transition.execution_state,
        TaskBoardExecutionState::HumanRequired
    );
    assert_eq!(
        execution.blocked_reason.as_deref(),
        Some("read_only_run_context_missing")
    );
    assert_eq!(runtime.start_count(), 0);
}

#[tokio::test]
async fn running_report_uses_frozen_context_until_settlement_rechecks_revision() {
    let fixture = seed_execution(
        "frozen-context",
        TaskBoardWorkflowKind::Review,
        TaskBoardExecutionState::Pending,
        None,
    )
    .await;
    let runtime = FakeReadOnlyRuntime::new([PlannedReport::running_review()]);
    tick(&fixture, &runtime, NOW).await;
    tick(&fixture, &runtime, NOW).await;

    fixture
        .test
        .db
        .update_task_board_item(&fixture.item_id, |item| {
            item.title = "Mutated title".into();
            item.body = "Mutated body".into();
            item.tags = vec!["mutated-tag".into()];
            item.session_id = Some("mutated-session".into());
            item.workflow.worktree = Some("/tmp/mutated-worktree".into());
            Ok(true)
        })
        .await
        .expect("mutate active item")
        .expect("item mutation");

    tick(&fixture, &runtime, NOW).await;

    let execution = load_execution(&fixture).await;
    assert_eq!(
        execution.transition.execution_state,
        TaskBoardExecutionState::Running
    );
    assert_eq!(execution.attempts[0].state, TaskBoardAttemptState::Running);
    assert_eq!(runtime.start_count(), 1);
    let request = runtime.last_request();
    assert!(request.prompt.contains("Read-only workflow frozen-context"));
    assert!(request.prompt.contains("Inspect the exact frozen revision"));
    assert!(request.prompt.contains("/tmp/read-only-worktree"));
    assert!(!request.prompt.contains("Mutated"));
    assert!(
        !request
            .capabilities
            .contains(&"task-board:tag:mutated-tag".into())
    );

    runtime.set_all_run_statuses(CodexRunStatus::Completed);
    tick(&fixture, &runtime, NOW).await;

    let execution = load_execution(&fixture).await;
    assert_eq!(
        execution.attempts[0].state,
        TaskBoardAttemptState::Completed
    );
    assert_eq!(
        execution.transition.execution_state,
        TaskBoardExecutionState::HumanRequired
    );
    assert_eq!(
        execution.blocked_reason.as_deref(),
        Some("frozen_revision_changed")
    );
    assert_eq!(runtime.start_count(), 1);
}

#[tokio::test]
async fn completed_review_head_drift_before_ingestion_requires_human_without_evidence() {
    for (label, workflow_kind) in [
        ("local-head-drift", TaskBoardWorkflowKind::Review),
        ("provider-head-drift", TaskBoardWorkflowKind::PrReview),
    ] {
        let fixture =
            seed_execution(label, workflow_kind, TaskBoardExecutionState::Pending, None).await;
        let runtime = FakeReadOnlyRuntime::new([PlannedReport::passing_review()]);
        tick(&fixture, &runtime, NOW).await;
        tick(&fixture, &runtime, NOW).await;

        let completed = load_execution(&fixture).await;
        assert_eq!(
            completed.attempts[0].state,
            TaskBoardAttemptState::Completed
        );
        assert!(completed.artifacts.review_cycles.is_empty());
        runtime.set_head("head-replaced");

        tick(&fixture, &runtime, NOW).await;

        let fenced = load_execution(&fixture).await;
        assert_eq!(fenced.attempts[0].state, TaskBoardAttemptState::Completed);
        assert!(fenced.artifacts.review_cycles.is_empty());
        assert_eq!(
            fenced.transition.execution_state,
            TaskBoardExecutionState::HumanRequired
        );
        assert_eq!(fenced.blocked_reason.as_deref(), Some("exact_head_changed"));
        assert_eq!(runtime.start_count(), 1);
        assert_eq!(runtime.publish_count(), 0);
    }
}
