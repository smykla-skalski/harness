use crate::daemon::db::AsyncDaemonDb;
use crate::task_board::{
    TaskBoardExecutionDiagnostic, TaskBoardExecutionState, TaskBoardFailureClass,
    TaskBoardRetrySchedule, TaskBoardWorkflowExecutionCas, TaskBoardWorkflowExecutionCasOutcome,
    TaskBoardWorkflowKind, TaskBoardWorkflowRevisionGuard,
};

use super::task_board_workflow_execution::{
    TaskBoardWorkflowExecutionCreateRequest, advance_workflow_execution,
    create_or_load_workflow_execution, resume_workflow_retry, schedule_workflow_retry,
};
use super::task_board_workflow_test_support::{
    CREATED_AT, TestDatabase, create_execution, outcome_record, reviewers, seed_snapshot,
};

#[tokio::test]
async fn write_workflow_is_rejected_without_a_durable_execution() {
    let test = TestDatabase::open().await;
    let snapshot = seed_snapshot(
        &test.db,
        "task-write",
        TaskBoardWorkflowKind::DefaultTask,
        reviewers(1, 1),
    )
    .await;

    let error = create_or_load_workflow_execution(
        &test.db,
        &TaskBoardWorkflowExecutionCreateRequest {
            execution_id: "execution-write".into(),
            item_id: "task-write".into(),
            snapshot,
            pull_request: None,
            exact_head_revision: Some("head-amber".into()),
            created_at: CREATED_AT.into(),
        },
    )
    .await
    .expect_err("write workflows belong to PR6");

    assert!(error.to_string().contains("Review or PrReview"));
    assert!(
        test.db
            .task_board_workflow_execution("execution-write")
            .await
            .expect("load execution")
            .is_none()
    );
}

#[tokio::test]
async fn frozen_revision_change_requires_human_without_moving_the_head() {
    let test = TestDatabase::open().await;
    let record = create_execution(
        &test.db,
        "task-frozen",
        TaskBoardWorkflowKind::Review,
        reviewers(1, 1),
        Some("head-amber"),
    )
    .await;
    let expected = TaskBoardWorkflowExecutionCas::from(&record);
    let mut revisions = TaskBoardWorkflowRevisionGuard::from(&record.snapshot);
    revisions.item_revision += 1;

    let updated = outcome_record(
        advance_workflow_execution(
            &test.db,
            &expected,
            &revisions,
            None,
            Some("head-amber"),
            "2026-07-15T10:02:00Z",
        )
        .await
        .expect("freeze stale execution"),
    );

    assert_eq!(
        updated.transition.execution_state,
        TaskBoardExecutionState::HumanRequired
    );
    assert_eq!(
        updated.transition.exact_head_revision.as_deref(),
        Some("head-amber")
    );
    assert_eq!(
        updated.blocked_reason.as_deref(),
        Some("frozen_revision_changed")
    );
}

#[tokio::test]
async fn retry_schedule_is_idempotent_durable_and_resumes_only_when_due() {
    let test = TestDatabase::open().await;
    let record = create_execution(
        &test.db,
        "task-retry",
        TaskBoardWorkflowKind::Review,
        reviewers(1, 1),
        Some("head-amber"),
    )
    .await;
    let retry = TaskBoardRetrySchedule {
        action_key: "review:reviewer-amber".into(),
        next_attempt: 2,
        failure_class: TaskBoardFailureClass::Transient,
        available_at: "2026-07-15T10:05:00Z".into(),
    };
    let diagnostic = TaskBoardExecutionDiagnostic {
        code: "attempt_transient".into(),
        message: "reviewer runtime temporarily unavailable".into(),
        recorded_at: "2026-07-15T10:02:00Z".into(),
    };
    let retrying = outcome_record(
        schedule_workflow_retry(
            &test.db,
            &TaskBoardWorkflowExecutionCas::from(&record),
            retry.clone(),
            diagnostic.clone(),
            "2026-07-15T10:02:00Z",
        )
        .await
        .expect("schedule retry"),
    );
    let sequence = test.db.current_change_sequence().await.expect("sequence");
    let duplicate = schedule_workflow_retry(
        &test.db,
        &TaskBoardWorkflowExecutionCas::from(&retrying),
        retry,
        diagnostic,
        "2026-07-15T10:02:00Z",
    )
    .await
    .expect("duplicate retry");
    assert!(matches!(
        duplicate,
        TaskBoardWorkflowExecutionCasOutcome::Unchanged(_)
    ));
    assert_eq!(
        test.db.current_change_sequence().await.expect("sequence"),
        sequence
    );

    let early = outcome_record(
        resume_workflow_retry(
            &test.db,
            &TaskBoardWorkflowExecutionCas::from(&retrying),
            "2026-07-15T10:04:59Z",
        )
        .await
        .expect("early retry"),
    );
    assert_eq!(
        early.transition.execution_state,
        TaskBoardExecutionState::RetryWait
    );

    drop(test.db);
    let reopened = AsyncDaemonDb::connect(&test.path)
        .await
        .expect("reopen database");
    let durable = reopened
        .task_board_workflow_execution(&retrying.execution_id)
        .await
        .expect("load execution")
        .expect("execution");
    let resumed = outcome_record(
        resume_workflow_retry(
            &reopened,
            &TaskBoardWorkflowExecutionCas::from(&durable),
            "2026-07-15T10:05:00Z",
        )
        .await
        .expect("resume due retry"),
    );
    assert_eq!(
        resumed.transition.execution_state,
        TaskBoardExecutionState::Pending
    );
    assert!(resumed.available_at.is_none());
    assert!(resumed.artifacts.retry.is_none());
}
