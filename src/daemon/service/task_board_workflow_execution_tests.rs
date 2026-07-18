use crate::daemon::db::AsyncDaemonDb;
use crate::task_board::{
    TaskBoardAttemptResultArtifact, TaskBoardAttemptState, TaskBoardExecutionAttemptCas,
    TaskBoardExecutionAttemptCasOutcome, TaskBoardExecutionAttemptRecord,
    TaskBoardExecutionDiagnostic, TaskBoardExecutionPhase, TaskBoardExecutionState,
    TaskBoardFailureClass, TaskBoardPhaseVerdict, TaskBoardRetrySchedule, TaskBoardReviewResult,
    TaskBoardReviewerOutcome, TaskBoardWorkflowExecutionCas, TaskBoardWorkflowExecutionCasOutcome,
    TaskBoardWorkflowKind, TaskBoardWorkflowRevisionGuard,
};

use super::task_board_workflow_execution::{
    TaskBoardWorkflowExecutionCreateRequest, advance_workflow_execution,
    create_or_load_workflow_execution, create_workflow_execution_attempt,
    record_workflow_execution_attempt, resume_workflow_retry, schedule_workflow_retry,
};
use super::task_board_workflow_review::record_workflow_reviewer_outcome;
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

#[tokio::test]
async fn completed_attempt_replay_survives_phase_advance_but_conflict_fails() {
    let test = TestDatabase::open().await;
    let record = create_execution(
        &test.db,
        "task-replay",
        TaskBoardWorkflowKind::PrReview,
        reviewers(1, 1),
        Some("head-amber"),
    )
    .await;
    let preparing = review_attempt(&record.execution_id, "attempt-replay");
    create_workflow_execution_attempt(&test.db, &preparing)
        .await
        .expect("create review attempt");
    let completed = completed_review_attempt(&preparing, "review complete");
    record_workflow_execution_attempt(
        &test.db,
        &TaskBoardExecutionAttemptCas::from(&preparing),
        &completed,
    )
    .await
    .expect("record review result");
    let current = test
        .db
        .task_board_workflow_execution(&record.execution_id)
        .await
        .expect("load execution with completed attempt")
        .expect("durable execution");
    let published = outcome_record(
        record_workflow_reviewer_outcome(
            &test.db,
            &TaskBoardWorkflowExecutionCas::from(&current),
            review_outcome("review complete"),
            "2026-07-15T10:03:00Z",
        )
        .await
        .expect("advance after review"),
    );
    assert_eq!(
        published.transition.phase,
        Some(TaskBoardExecutionPhase::Publish)
    );

    let sequence = test.db.current_change_sequence().await.expect("sequence");
    let replay = record_workflow_execution_attempt(
        &test.db,
        &TaskBoardExecutionAttemptCas::from(&preparing),
        &completed,
    )
    .await
    .expect("replay completed attempt");
    assert!(matches!(
        replay,
        TaskBoardExecutionAttemptCasOutcome::Unchanged(_)
    ));
    assert_eq!(
        test.db.current_change_sequence().await.expect("sequence"),
        sequence
    );

    let mut conflicting = completed.clone();
    conflicting.artifact = Some(TaskBoardAttemptResultArtifact::Review(review_outcome(
        "conflicting review",
    )));
    let error = record_workflow_execution_attempt(
        &test.db,
        &TaskBoardExecutionAttemptCas::from(&preparing),
        &conflicting,
    )
    .await
    .expect_err("conflicting completed replay must fail");
    assert!(error.to_string().contains("does not belong to phase"));
}

#[tokio::test]
async fn attempt_create_and_cas_are_fenced_by_durable_parent_phase() {
    let test = TestDatabase::open().await;
    let record = create_execution(
        &test.db,
        "task-phase-fence",
        TaskBoardWorkflowKind::PrReview,
        reviewers(1, 1),
        Some("head-amber"),
    )
    .await;
    let preparing = review_attempt(&record.execution_id, "attempt-before-advance");
    test.db
        .create_task_board_execution_attempt(&preparing)
        .await
        .expect("create initial review attempt");
    let current = test
        .db
        .task_board_workflow_execution(&record.execution_id)
        .await
        .expect("load execution with initial attempt")
        .expect("durable execution");
    let published = outcome_record(
        record_workflow_reviewer_outcome(
            &test.db,
            &TaskBoardWorkflowExecutionCas::from(&current),
            review_outcome("advance parent"),
            "2026-07-15T10:02:00Z",
        )
        .await
        .expect("advance parent phase"),
    );
    assert_eq!(
        published.transition.phase,
        Some(TaskBoardExecutionPhase::Publish)
    );

    let sequence = test.db.current_change_sequence().await.expect("sequence");
    let duplicate = test
        .db
        .create_task_board_execution_attempt(&preparing)
        .await
        .expect("identical create remains idempotent after phase advance");
    assert!(!duplicate.created);
    assert_eq!(
        test.db.current_change_sequence().await.expect("sequence"),
        sequence
    );

    let mut late = review_attempt(&record.execution_id, "attempt-after-advance");
    late.attempt = 2;
    let create_error = test
        .db
        .create_task_board_execution_attempt(&late)
        .await
        .expect_err("wrong-phase create must fail inside transaction");
    assert!(
        create_error
            .to_string()
            .contains("does not belong to phase")
    );

    let mut running = preparing.clone();
    running.state = TaskBoardAttemptState::Running;
    running.updated_at = "2026-07-15T10:03:00Z".into();
    let cas_error = test
        .db
        .compare_and_set_task_board_execution_attempt(
            &TaskBoardExecutionAttemptCas::from(&preparing),
            &running,
        )
        .await
        .expect_err("wrong-phase CAS must fail inside transaction");
    assert!(cas_error.to_string().contains("does not belong to phase"));
}

fn review_attempt(execution_id: &str, idempotency_key: &str) -> TaskBoardExecutionAttemptRecord {
    TaskBoardExecutionAttemptRecord {
        execution_id: execution_id.into(),
        action_key: "review:reviewer-amber".into(),
        attempt: 1,
        idempotency_key: idempotency_key.into(),
        state: TaskBoardAttemptState::Preparing,
        failure_class: None,
        available_at: None,
        error: None,
        artifact: None,
        started_at: CREATED_AT.into(),
        updated_at: CREATED_AT.into(),
        completed_at: None,
    }
}

fn completed_review_attempt(
    attempt: &TaskBoardExecutionAttemptRecord,
    summary: &str,
) -> TaskBoardExecutionAttemptRecord {
    let mut completed = attempt.clone();
    completed.state = TaskBoardAttemptState::Completed;
    completed.artifact = Some(TaskBoardAttemptResultArtifact::Review(review_outcome(
        summary,
    )));
    completed.updated_at = "2026-07-15T10:02:00Z".into();
    completed.completed_at = Some("2026-07-15T10:02:00Z".into());
    completed
}

fn review_outcome(summary: &str) -> TaskBoardReviewerOutcome {
    TaskBoardReviewerOutcome {
        profile_id: "reviewer-amber".into(),
        result: TaskBoardReviewResult {
            verdict: TaskBoardPhaseVerdict::Pass,
            head_revision: "head-amber".into(),
            summary: summary.into(),
            findings: Vec::new(),
        },
    }
}
