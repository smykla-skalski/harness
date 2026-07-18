use crate::task_board::{
    TaskBoardAttemptResultArtifact, TaskBoardAttemptState, TaskBoardExecutionAttemptCas,
    TaskBoardExecutionAttemptRecord, TaskBoardExecutionPhase, TaskBoardExecutionState,
    TaskBoardFailureClass, TaskBoardLifecycleOutcome, TaskBoardPhaseVerdict, TaskBoardReviewResult,
    TaskBoardReviewerOutcome, TaskBoardTerminalOutcomeKind, TaskBoardWorkflowExecutionCas,
    TaskBoardWorkflowKind, TaskBoardWorkflowRevisionGuard,
};

use super::task_board_workflow_execution::{
    advance_workflow_execution, create_workflow_execution_attempt,
    record_workflow_execution_attempt,
};
use super::task_board_workflow_review::record_workflow_reviewer_outcome;
use super::task_board_workflow_test_support::{
    CREATED_AT, TestDatabase, create_execution, outcome_record, reviewers,
};

#[tokio::test]
async fn reviewer_outcome_rejects_stale_head_and_preserves_exact_pr_head() {
    let test = TestDatabase::open().await;
    let record = create_execution(
        &test.db,
        "task-pr-head",
        TaskBoardWorkflowKind::PrReview,
        reviewers(1, 1),
        Some("head-amber"),
    )
    .await;

    let error = record_workflow_reviewer_outcome(
        &test.db,
        &TaskBoardWorkflowExecutionCas::from(&record),
        review_outcome("reviewer-amber", TaskBoardPhaseVerdict::Pass, "head-indigo"),
        "2026-07-15T10:02:00Z",
    )
    .await
    .expect_err("stale review must fail closed");

    assert!(error.to_string().contains("stale head"));
    let durable = test
        .db
        .task_board_workflow_execution(&record.execution_id)
        .await
        .expect("load execution")
        .expect("execution");
    assert_eq!(
        durable.transition.exact_head_revision.as_deref(),
        Some("head-amber")
    );
    assert!(durable.artifacts.review_cycles.is_empty());
}

#[tokio::test]
async fn read_only_changes_required_requires_human_without_changing_head() {
    for workflow_kind in [
        TaskBoardWorkflowKind::Review,
        TaskBoardWorkflowKind::PrReview,
    ] {
        let test = TestDatabase::open().await;
        let record = create_execution(
            &test.db,
            &format!("task-{workflow_kind:?}"),
            workflow_kind,
            reviewers(1, 1),
            Some("head-amber"),
        )
        .await;

        let changed = outcome_record(
            record_workflow_reviewer_outcome(
                &test.db,
                &TaskBoardWorkflowExecutionCas::from(&record),
                review_outcome(
                    "reviewer-amber",
                    TaskBoardPhaseVerdict::ChangesRequired,
                    "head-amber",
                ),
                "2026-07-15T10:02:00Z",
            )
            .await
            .expect("record changes required"),
        );

        assert_eq!(
            changed.transition.execution_state,
            TaskBoardExecutionState::HumanRequired
        );
        assert_eq!(
            changed.transition.phase,
            Some(TaskBoardExecutionPhase::Review)
        );
        assert_eq!(
            changed.transition.exact_head_revision.as_deref(),
            Some("head-amber")
        );
        assert_eq!(changed.artifacts.current_revision_cycle, 1);
        assert_eq!(
            changed
                .artifacts
                .terminal_outcome
                .as_ref()
                .map(|outcome| outcome.kind),
            Some(TaskBoardTerminalOutcomeKind::HumanRequired)
        );
    }
}

#[tokio::test]
async fn unknown_attempt_outcome_never_claims_terminal_success() {
    let test = TestDatabase::open().await;
    let record = create_execution(
        &test.db,
        "task-unknown",
        TaskBoardWorkflowKind::Review,
        reviewers(1, 1),
        Some("head-amber"),
    )
    .await;
    let attempt = preparing_attempt(
        &record.execution_id,
        "review:reviewer-amber",
        "attempt-unknown",
    );
    create_workflow_execution_attempt(&test.db, &attempt)
        .await
        .expect("create attempt");
    let mut unknown = attempt.clone();
    unknown.state = TaskBoardAttemptState::Unknown;
    unknown.failure_class = Some(TaskBoardFailureClass::UnknownOutcome);
    unknown.error = Some("runtime disappeared after start".into());
    unknown.updated_at = "2026-07-15T10:02:00Z".into();
    record_workflow_execution_attempt(
        &test.db,
        &TaskBoardExecutionAttemptCas::from(&attempt),
        &unknown,
    )
    .await
    .expect("record unknown outcome");
    let reloaded = test
        .db
        .task_board_workflow_execution(&record.execution_id)
        .await
        .expect("reload")
        .expect("execution");

    let stopped = outcome_record(
        advance_workflow_execution(
            &test.db,
            &TaskBoardWorkflowExecutionCas::from(&reloaded),
            &TaskBoardWorkflowRevisionGuard::from(&reloaded.snapshot),
            reloaded.transition.pull_request.as_ref(),
            reloaded.transition.exact_head_revision.as_deref(),
            "2026-07-15T10:03:00Z",
        )
        .await
        .expect("reconcile unknown attempt"),
    );

    assert_eq!(
        stopped.transition.execution_state,
        TaskBoardExecutionState::HumanRequired
    );
    assert_eq!(
        stopped
            .artifacts
            .terminal_outcome
            .as_ref()
            .map(|outcome| outcome.kind),
        Some(TaskBoardTerminalOutcomeKind::Unknown)
    );
}

#[tokio::test]
async fn pr_review_publish_and_cleanup_require_evidence_then_finish_idempotently() {
    let test = TestDatabase::open().await;
    let record = create_execution(
        &test.db,
        "task-terminal",
        TaskBoardWorkflowKind::PrReview,
        reviewers(1, 1),
        Some("head-amber"),
    )
    .await;
    let publish = outcome_record(
        record_workflow_reviewer_outcome(
            &test.db,
            &TaskBoardWorkflowExecutionCas::from(&record),
            review_outcome("reviewer-amber", TaskBoardPhaseVerdict::Pass, "head-amber"),
            "2026-07-15T10:01:00Z",
        )
        .await
        .expect("approve exact head"),
    );
    assert_eq!(
        publish.transition.phase,
        Some(TaskBoardExecutionPhase::Publish)
    );

    let waiting = advance(&test, &publish, "2026-07-15T10:02:00Z").await;
    assert_eq!(
        waiting.transition.phase,
        Some(TaskBoardExecutionPhase::Publish)
    );
    assert_eq!(
        waiting.blocked_reason.as_deref(),
        Some("publish_evidence_pending")
    );

    let published =
        completed_lifecycle_attempt(&test, &waiting, "publish", false, "2026-07-15T10:03:00Z")
            .await;
    let cleanup = advance(&test, &published, "2026-07-15T10:04:00Z").await;
    assert_eq!(
        cleanup.transition.phase,
        Some(TaskBoardExecutionPhase::Cleanup)
    );

    let cleaned =
        completed_lifecycle_attempt(&test, &cleanup, "cleanup", true, "2026-07-15T10:05:00Z").await;
    let terminal = advance(&test, &cleaned, "2026-07-15T10:06:00Z").await;
    assert_eq!(
        terminal.transition.phase,
        Some(TaskBoardExecutionPhase::Terminal)
    );
    assert_eq!(
        terminal.transition.execution_state,
        TaskBoardExecutionState::Completed
    );

    let sequence = test.db.current_change_sequence().await.expect("sequence");
    let duplicate = advance(&test, &terminal, "2026-07-15T10:07:00Z").await;
    assert_eq!(duplicate, terminal);
    assert_eq!(
        test.db.current_change_sequence().await.expect("sequence"),
        sequence
    );
}

async fn completed_lifecycle_attempt(
    test: &TestDatabase,
    record: &crate::task_board::TaskBoardWorkflowExecutionRecord,
    action_key: &str,
    terminal: bool,
    completed_at: &str,
) -> crate::task_board::TaskBoardWorkflowExecutionRecord {
    let attempt = preparing_attempt(
        &record.execution_id,
        action_key,
        &format!("attempt-{action_key}"),
    );
    create_workflow_execution_attempt(&test.db, &attempt)
        .await
        .expect("create lifecycle attempt");
    let mut completed = attempt.clone();
    completed.state = TaskBoardAttemptState::Completed;
    completed.artifact = Some(TaskBoardAttemptResultArtifact::Lifecycle(
        TaskBoardLifecycleOutcome {
            mutated: false,
            terminal,
            provider_revision: record.snapshot.provider_revision.clone(),
            external_url: None,
        },
    ));
    completed.updated_at = completed_at.into();
    completed.completed_at = Some(completed_at.into());
    record_workflow_execution_attempt(
        &test.db,
        &TaskBoardExecutionAttemptCas::from(&attempt),
        &completed,
    )
    .await
    .expect("record lifecycle result");
    test.db
        .task_board_workflow_execution(&record.execution_id)
        .await
        .expect("reload execution")
        .expect("execution")
}

async fn advance(
    test: &TestDatabase,
    record: &crate::task_board::TaskBoardWorkflowExecutionRecord,
    updated_at: &str,
) -> crate::task_board::TaskBoardWorkflowExecutionRecord {
    outcome_record(
        advance_workflow_execution(
            &test.db,
            &TaskBoardWorkflowExecutionCas::from(record),
            &TaskBoardWorkflowRevisionGuard::from(&record.snapshot),
            record.transition.pull_request.as_ref(),
            record.transition.exact_head_revision.as_deref(),
            updated_at,
        )
        .await
        .expect("advance workflow"),
    )
}

fn review_outcome(
    profile_id: &str,
    verdict: TaskBoardPhaseVerdict,
    head_revision: &str,
) -> TaskBoardReviewerOutcome {
    TaskBoardReviewerOutcome {
        profile_id: profile_id.into(),
        result: TaskBoardReviewResult {
            verdict,
            head_revision: head_revision.into(),
            summary: "reviewed exact head".into(),
            findings: Vec::new(),
        },
    }
}

fn preparing_attempt(
    execution_id: &str,
    action_key: &str,
    idempotency_key: &str,
) -> TaskBoardExecutionAttemptRecord {
    TaskBoardExecutionAttemptRecord {
        execution_id: execution_id.into(),
        action_key: action_key.into(),
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
