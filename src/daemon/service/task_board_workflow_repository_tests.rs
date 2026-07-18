use sqlx::query;

use crate::daemon::db::AsyncDaemonDb;
use crate::task_board::{
    TaskBoardAttemptResultArtifact, TaskBoardAttemptState, TaskBoardExecutionAttemptCas,
    TaskBoardExecutionAttemptRecord, TaskBoardExecutionDiagnostic, TaskBoardExecutionState,
    TaskBoardPhaseVerdict, TaskBoardReviewResult, TaskBoardReviewerOutcome,
    TaskBoardWorkflowCasMismatch, TaskBoardWorkflowExecutionCas,
    TaskBoardWorkflowExecutionCasOutcome, TaskBoardWorkflowKind,
};

use super::task_board_workflow_execution::{
    create_workflow_execution_attempt, record_workflow_execution_attempt,
};
use super::task_board_workflow_test_support::{
    CREATED_AT, TestDatabase, create_execution, reviewers,
};

#[tokio::test]
async fn active_execution_create_is_idempotent_and_rejects_competing_contracts() {
    let test = TestDatabase::open().await;
    let record = create_execution(
        &test.db,
        "task-lantern",
        TaskBoardWorkflowKind::Review,
        reviewers(1, 1),
        Some("head-amber"),
    )
    .await;
    let sequence = test.db.current_change_sequence().await.expect("sequence");

    let duplicate = test
        .db
        .create_or_load_task_board_workflow_execution(&record)
        .await
        .expect("duplicate create");
    let mut competing = record.clone();
    competing.execution_id = "execution-competing".into();
    let error = test
        .db
        .create_or_load_task_board_workflow_execution(&competing)
        .await
        .expect_err("competing active execution must fail closed");

    assert!(!duplicate.created);
    assert!(error.to_string().contains("immutable contract"));
    assert_eq!(
        test.db.current_change_sequence().await.expect("sequence"),
        sequence
    );

    drop(test.db);
    let reopened = AsyncDaemonDb::connect(&test.path)
        .await
        .expect("reopen database");
    assert_eq!(
        reopened
            .active_task_board_workflow_execution("task-lantern")
            .await
            .expect("load active execution"),
        Some(record)
    );
}

#[tokio::test]
async fn execution_cas_rejects_stale_guards_without_change_churn() {
    let test = TestDatabase::open().await;
    let current = create_execution(
        &test.db,
        "task-compass",
        TaskBoardWorkflowKind::Review,
        reviewers(1, 1),
        Some("head-amber"),
    )
    .await;
    let mut updated = current.clone();
    updated.transition.execution_state = TaskBoardExecutionState::Blocked;
    updated.blocked_reason = Some("waiting_for_evidence".into());
    updated.updated_at = "2026-07-15T10:02:00Z".into();
    let sequence = test.db.current_change_sequence().await.expect("sequence");

    let mut stale_guards = Vec::new();
    let mut stale = TaskBoardWorkflowExecutionCas::from(&current);
    stale.execution_id = "execution-stale".into();
    stale_guards.push((stale, TaskBoardWorkflowCasMismatch::ExecutionId));
    let mut stale = TaskBoardWorkflowExecutionCas::from(&current);
    stale.phase = Some(crate::task_board::TaskBoardExecutionPhase::Evaluate);
    stale_guards.push((stale, TaskBoardWorkflowCasMismatch::Phase));
    let mut stale = TaskBoardWorkflowExecutionCas::from(&current);
    stale.state = TaskBoardExecutionState::Running;
    stale_guards.push((stale, TaskBoardWorkflowCasMismatch::State));
    let mut stale = TaskBoardWorkflowExecutionCas::from(&current);
    stale.revisions.item_revision += 1;
    stale_guards.push((stale, TaskBoardWorkflowCasMismatch::ItemRevision));
    let mut stale = TaskBoardWorkflowExecutionCas::from(&current);
    stale.revisions.configuration_revision += 1;
    stale_guards.push((stale, TaskBoardWorkflowCasMismatch::ConfigurationRevision));
    let mut stale = TaskBoardWorkflowExecutionCas::from(&current);
    stale.revisions.provider_revision = Some("provider-indigo".into());
    stale_guards.push((stale, TaskBoardWorkflowCasMismatch::ProviderRevision));
    let mut stale = TaskBoardWorkflowExecutionCas::from(&current);
    stale.record_sha256 = "stale-record".into();
    stale_guards.push((stale, TaskBoardWorkflowCasMismatch::Record));

    for (expected, mismatch) in stale_guards {
        let outcome = test
            .db
            .compare_and_set_task_board_workflow_execution(&expected, &updated)
            .await
            .expect("stale CAS");
        assert!(matches!(
            outcome,
            TaskBoardWorkflowExecutionCasOutcome::Stale {
                mismatch: actual,
                ..
            } if actual == mismatch
        ));
    }
    assert_eq!(
        test.db.current_change_sequence().await.expect("sequence"),
        sequence
    );

    let outcome = test
        .db
        .compare_and_set_task_board_workflow_execution(
            &TaskBoardWorkflowExecutionCas::from(&current),
            &updated,
        )
        .await
        .expect("valid CAS");
    assert!(matches!(
        outcome,
        TaskBoardWorkflowExecutionCasOutcome::Updated(_)
    ));
}

#[tokio::test]
async fn execution_cas_fences_same_state_record_content() {
    let test = TestDatabase::open().await;
    let current = create_execution(
        &test.db,
        "task-content-fence",
        TaskBoardWorkflowKind::Review,
        reviewers(1, 1),
        Some("head-amber"),
    )
    .await;
    let expected = TaskBoardWorkflowExecutionCas::from(&current);
    let mut first = current.clone();
    first.artifacts.diagnostics.push(diagnostic("writer-a"));
    let mut stale = current.clone();
    stale.artifacts.diagnostics.push(diagnostic("writer-b"));

    let applied = test
        .db
        .compare_and_set_task_board_workflow_execution(&expected, &first)
        .await
        .expect("apply first content update");
    assert!(matches!(
        applied,
        TaskBoardWorkflowExecutionCasOutcome::Updated(_)
    ));
    let sequence = test.db.current_change_sequence().await.expect("sequence");
    let rejected = test
        .db
        .compare_and_set_task_board_workflow_execution(&expected, &stale)
        .await
        .expect("reject stale content update");
    assert!(matches!(
        rejected,
        TaskBoardWorkflowExecutionCasOutcome::Stale {
            mismatch: TaskBoardWorkflowCasMismatch::Record,
            ..
        }
    ));
    assert_eq!(
        test.db.current_change_sequence().await.expect("sequence"),
        sequence
    );
    let persisted = test
        .db
        .task_board_workflow_execution(&current.execution_id)
        .await
        .expect("load fenced execution")
        .expect("fenced execution");
    assert_eq!(
        persisted.artifacts.diagnostics,
        vec![diagnostic("writer-a")]
    );
}

#[tokio::test]
async fn execution_cas_fences_concurrent_child_evidence() {
    let test = TestDatabase::open().await;
    let current = create_execution(
        &test.db,
        "task-child-fence",
        TaskBoardWorkflowKind::Review,
        reviewers(1, 1),
        Some("head-amber"),
    )
    .await;
    let expected = TaskBoardWorkflowExecutionCas::from(&current);
    let attempt = preparing_attempt(
        &current.execution_id,
        "review:reviewer-amber",
        1,
        "attempt-child-fence",
    );
    create_workflow_execution_attempt(&test.db, &attempt)
        .await
        .expect("create concurrent child evidence");
    let mut stale_parent = current.clone();
    stale_parent.transition.execution_state = TaskBoardExecutionState::Preparing;

    let rejected = test
        .db
        .compare_and_set_task_board_workflow_execution(&expected, &stale_parent)
        .await
        .expect("reject parent update after child evidence");
    assert!(matches!(
        rejected,
        TaskBoardWorkflowExecutionCasOutcome::Stale {
            mismatch: TaskBoardWorkflowCasMismatch::Record,
            ..
        }
    ));
}

#[tokio::test]
async fn malformed_json_and_missing_exact_head_fail_closed() {
    let test = TestDatabase::open().await;
    let malformed = create_execution(
        &test.db,
        "task-prism",
        TaskBoardWorkflowKind::Review,
        reviewers(1, 1),
        Some("head-amber"),
    )
    .await;
    query(
        "UPDATE task_board_workflow_executions
         SET diagnostics_json = json_set(diagnostics_json, '$.unexpected', 1)
         WHERE execution_id = ?1",
    )
    .bind(&malformed.execution_id)
    .execute(test.db.pool())
    .await
    .expect("corrupt execution JSON");
    let error = test
        .db
        .task_board_workflow_execution(&malformed.execution_id)
        .await
        .expect_err("malformed execution must fail closed");
    assert!(error.to_string().contains("workflow execution artifacts"));

    let pr = create_execution(
        &test.db,
        "task-headless-pr",
        TaskBoardWorkflowKind::PrReview,
        reviewers(1, 1),
        Some("head-indigo"),
    )
    .await;
    query(
        "UPDATE task_board_workflow_executions
         SET diagnostics_json = json_remove(
             diagnostics_json, '$.transition.exact_head_revision')
         WHERE execution_id = ?1",
    )
    .bind(&pr.execution_id)
    .execute(test.db.pool())
    .await
    .expect("remove durable exact head");
    let error = test
        .db
        .task_board_workflow_execution(&pr.execution_id)
        .await
        .expect_err("missing durable exact head must fail closed");
    assert!(error.to_string().contains("exact head revision"));
}

#[tokio::test]
async fn same_phase_cas_cannot_replace_pr_identity_or_exact_head() {
    let test = TestDatabase::open().await;
    let record = create_execution(
        &test.db,
        "task-frozen-pr",
        TaskBoardWorkflowKind::PrReview,
        reviewers(1, 1),
        Some("head-amber"),
    )
    .await;
    let expected = TaskBoardWorkflowExecutionCas::from(&record);
    let mut changed_head = record.clone();
    changed_head.transition.exact_head_revision = Some("head-indigo".into());
    changed_head.updated_at = "2026-07-15T10:02:00Z".into();
    let error = test
        .db
        .compare_and_set_task_board_workflow_execution(&expected, &changed_head)
        .await
        .expect_err("same-phase head replacement must fail");
    assert!(error.to_string().contains("exact head changed"));

    let mut changed_pr = record;
    changed_pr
        .transition
        .pull_request
        .as_mut()
        .expect("pull request")
        .number += 1;
    changed_pr.updated_at = "2026-07-15T10:02:00Z".into();
    let error = test
        .db
        .compare_and_set_task_board_workflow_execution(&expected, &changed_pr)
        .await
        .expect_err("same-phase PR replacement must fail");
    assert!(error.to_string().contains("identity or exact head"));
}

#[tokio::test]
async fn review_attempt_result_rejects_a_stale_exact_head() {
    let test = TestDatabase::open().await;
    let record = create_execution(
        &test.db,
        "task-review-attempt",
        TaskBoardWorkflowKind::PrReview,
        reviewers(1, 1),
        Some("head-amber"),
    )
    .await;
    let attempt = preparing_attempt(
        &record.execution_id,
        "review:reviewer-amber",
        1,
        "attempt-review",
    );
    create_workflow_execution_attempt(&test.db, &attempt)
        .await
        .expect("create review attempt");
    let mut result = attempt.clone();
    result.state = TaskBoardAttemptState::Completed;
    result.artifact = Some(TaskBoardAttemptResultArtifact::Review(
        TaskBoardReviewerOutcome {
            profile_id: "reviewer-amber".into(),
            result: TaskBoardReviewResult {
                verdict: TaskBoardPhaseVerdict::Pass,
                head_revision: "head-indigo".into(),
                summary: "stale result".into(),
                findings: Vec::new(),
            },
        },
    ));
    result.updated_at = "2026-07-15T10:02:00Z".into();
    result.completed_at = Some("2026-07-15T10:02:00Z".into());

    let error = record_workflow_execution_attempt(
        &test.db,
        &TaskBoardExecutionAttemptCas::from(&attempt),
        &result,
    )
    .await
    .expect_err("stale review head must fail closed");
    assert!(
        error
            .to_string()
            .contains("frozen reviewer profile and exact head")
    );
}

#[tokio::test]
async fn ready_queue_is_due_bounded_and_deterministic() {
    let test = TestDatabase::open().await;
    let first = create_execution(
        &test.db,
        "task-a",
        TaskBoardWorkflowKind::Review,
        reviewers(1, 1),
        Some("head-a"),
    )
    .await;
    let second = create_execution(
        &test.db,
        "task-b",
        TaskBoardWorkflowKind::PrReview,
        reviewers(1, 1),
        Some("head-b"),
    )
    .await;

    let ready = test
        .db
        .ready_task_board_workflow_executions("2026-07-15T10:00:00Z", 10)
        .await
        .expect("load ready queue");
    assert_eq!(
        ready
            .iter()
            .map(|record| record.execution_id.as_str())
            .collect::<Vec<_>>(),
        vec![first.execution_id.as_str(), second.execution_id.as_str()]
    );
    assert!(
        test.db
            .ready_task_board_workflow_executions("2026-07-15T10:00:00Z", 0)
            .await
            .expect("zero limit")
            .is_empty()
    );
}

fn preparing_attempt(
    execution_id: &str,
    action_key: &str,
    attempt: u32,
    idempotency_key: &str,
) -> TaskBoardExecutionAttemptRecord {
    TaskBoardExecutionAttemptRecord {
        execution_id: execution_id.into(),
        action_key: action_key.into(),
        attempt,
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

fn diagnostic(code: &str) -> TaskBoardExecutionDiagnostic {
    TaskBoardExecutionDiagnostic {
        code: code.into(),
        message: format!("diagnostic from {code}"),
        recorded_at: CREATED_AT.into(),
    }
}
