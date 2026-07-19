use std::collections::BTreeMap;

use super::workflow_executions::{NOW, workflow_database};
use super::*;
use crate::task_board::{
    AgentMode, TASK_BOARD_READ_ONLY_RUN_CONTEXT_VERSION, TaskBoardAttemptResultArtifact,
    TaskBoardAttemptState, TaskBoardExecutionAttemptCas, TaskBoardExecutionAttemptRecord,
    TaskBoardExecutionDiagnostic, TaskBoardExecutionOwnership, TaskBoardExecutionPhase,
    TaskBoardExecutionState, TaskBoardFailureClass, TaskBoardLifecycleOutcome,
    TaskBoardPullRequestHeadIdentity, TaskBoardPullRequestIdentity, TaskBoardReadOnlyRunContext,
    TaskBoardResolvedReviewer, TaskBoardReviewerProfile, TaskBoardWorkflowExecutionArtifacts,
    TaskBoardWorkflowExecutionCas, TaskBoardWorkflowExecutionRecord, TaskBoardWorkflowKind,
    TaskBoardWorkflowSnapshot, TaskBoardWorkflowTransitionState,
};

const UPDATED_AT: &str = "2026-07-17T10:01:00Z";
const RETRY_AT: &str = "2026-07-17T10:05:00Z";
const PUBLICATION_URL: &str = "https://github.com/example/repo/pull/42";

#[tokio::test]
async fn verification_retry_updates_parent_and_exact_attempt_atomically() {
    let (db, _temp, current) = verification_fixture("atomic-success").await;
    let (updated_parent, updated_attempt) = retry_update(&current);

    let combined = db
        .compare_and_set_task_board_workflow_execution_and_attempt(
            &TaskBoardWorkflowExecutionCas::from(&current),
            &updated_parent,
            &TaskBoardExecutionAttemptCas::from(&current.attempts[0]),
            &updated_attempt,
        )
        .await
        .expect("atomic retry CAS")
        .expect("retry CAS winner");

    assert_retry_evidence(&combined);
    assert_eq!(
        db.task_board_workflow_execution(&current.execution_id)
            .await
            .expect("load committed retry")
            .expect("retry execution"),
        combined
    );
}

#[tokio::test]
async fn same_state_attempt_drift_stales_full_record_without_partial_update() {
    let (db, _temp, current) = verification_fixture("attempt-drift").await;
    let (updated_parent, updated_attempt) = retry_update(&current);
    let mut drifted = current.attempts[0].clone();
    drifted.error = Some("concurrent verifier detail".into());
    drifted.updated_at = UPDATED_AT.into();
    db.compare_and_set_task_board_execution_attempt(
        &TaskBoardExecutionAttemptCas::from(&current.attempts[0]),
        &drifted,
    )
    .await
    .expect("persist same-state attempt drift");

    let outcome = db
        .compare_and_set_task_board_workflow_execution_and_attempt(
            &TaskBoardWorkflowExecutionCas::from(&current),
            &updated_parent,
            &TaskBoardExecutionAttemptCas::from(&current.attempts[0]),
            &updated_attempt,
        )
        .await
        .expect("stale retry CAS");

    assert!(outcome.is_none());
    let durable = load_execution(&db, &current.execution_id).await;
    assert!(durable.artifacts.diagnostics.is_empty());
    assert_eq!(durable.attempts[0], drifted);
}

#[tokio::test]
async fn parent_drift_stales_atomic_retry_without_overwriting_either_record() {
    let (db, _temp, current) = verification_fixture("parent-drift").await;
    let (updated_parent, updated_attempt) = retry_update(&current);
    let mut drifted = current.clone();
    drifted
        .artifacts
        .diagnostics
        .push(TaskBoardExecutionDiagnostic {
            code: "concurrent_parent_update".into(),
            message: "another reconciler recorded evidence".into(),
            recorded_at: UPDATED_AT.into(),
        });
    drifted.updated_at = UPDATED_AT.into();
    db.compare_and_set_task_board_workflow_execution(
        &TaskBoardWorkflowExecutionCas::from(&current),
        &drifted,
    )
    .await
    .expect("persist parent drift");

    let outcome = db
        .compare_and_set_task_board_workflow_execution_and_attempt(
            &TaskBoardWorkflowExecutionCas::from(&current),
            &updated_parent,
            &TaskBoardExecutionAttemptCas::from(&current.attempts[0]),
            &updated_attempt,
        )
        .await
        .expect("stale parent retry CAS");

    assert!(outcome.is_none());
    assert_eq!(load_execution(&db, &current.execution_id).await, drifted);
}

#[tokio::test]
async fn child_update_failure_rolls_back_parent_update() {
    let (db, _temp, current) = verification_fixture("child-rollback").await;
    let (updated_parent, updated_attempt) = retry_update(&current);
    sqlx::query(
        "CREATE TRIGGER fail_verification_attempt_update
         BEFORE UPDATE ON task_board_execution_attempts
         BEGIN SELECT RAISE(ABORT, 'injected child update failure'); END",
    )
    .execute(db.pool())
    .await
    .expect("install child update failure");

    db.compare_and_set_task_board_workflow_execution_and_attempt(
        &TaskBoardWorkflowExecutionCas::from(&current),
        &updated_parent,
        &TaskBoardExecutionAttemptCas::from(&current.attempts[0]),
        &updated_attempt,
    )
    .await
    .expect_err("child SQL failure must roll back the parent update");

    assert_eq!(load_execution(&db, &current.execution_id).await, current);
}

fn retry_update(
    current: &TaskBoardWorkflowExecutionRecord,
) -> (
    TaskBoardWorkflowExecutionRecord,
    TaskBoardExecutionAttemptRecord,
) {
    let mut parent = current.clone();
    parent
        .artifacts
        .diagnostics
        .push(TaskBoardExecutionDiagnostic {
            code: "publish_verification_failed".into(),
            message: "GitHub head is not visible yet".into(),
            recorded_at: UPDATED_AT.into(),
        });
    parent.updated_at = UPDATED_AT.into();
    let mut attempt = current.attempts[0].clone();
    attempt.failure_class = Some(TaskBoardFailureClass::Transient);
    attempt.error = Some("GitHub head is not visible yet".into());
    attempt.available_at = Some(RETRY_AT.into());
    attempt.artifact = Some(TaskBoardAttemptResultArtifact::Lifecycle(
        TaskBoardLifecycleOutcome {
            mutated: true,
            terminal: false,
            provider_revision: None,
            external_url: Some(PUBLICATION_URL.into()),
        },
    ));
    attempt.updated_at = UPDATED_AT.into();
    (parent, attempt)
}

fn assert_retry_evidence(execution: &TaskBoardWorkflowExecutionRecord) {
    assert_eq!(execution.artifacts.diagnostics.len(), 1);
    assert_eq!(
        execution.attempts[0].available_at.as_deref(),
        Some(RETRY_AT)
    );
    assert!(matches!(
        execution.attempts[0].artifact.as_ref(),
        Some(TaskBoardAttemptResultArtifact::Lifecycle(outcome))
            if outcome.mutated && outcome.external_url.as_deref() == Some(PUBLICATION_URL)
    ));
}

async fn verification_fixture(
    label: &str,
) -> (
    AsyncDaemonDb,
    tempfile::TempDir,
    TaskBoardWorkflowExecutionRecord,
) {
    let (db, temp) = workflow_database().await;
    let reviewers = resolved_reviewers();
    let item_id = format!("verification-{label}");
    let mut item = TaskBoardItem::new(
        item_id.clone(),
        "Verification retry".into(),
        "Atomic parent and child persistence".into(),
        NOW.into(),
    );
    item.workflow_kind = TaskBoardWorkflowKind::PrReview;
    item.execution_repository = Some("example/repo".into());
    let mutation = db
        .create_task_board_item(item)
        .await
        .expect("create verification item");
    let execution_id = format!("execution-{item_id}");
    let pull_request = TaskBoardPullRequestIdentity {
        repository: "example/repo".into(),
        number: 42,
        head: Some(TaskBoardPullRequestHeadIdentity {
            repository: "example/repo".into(),
            branch: "feature/write".into(),
            revision: "published-head".into(),
        }),
    };
    let record = TaskBoardWorkflowExecutionRecord {
        execution_id: execution_id.clone(),
        item_id,
        snapshot: TaskBoardWorkflowSnapshot {
            workflow_kind: TaskBoardWorkflowKind::PrReview,
            execution_repository: Some("example/repo".into()),
            item_revision: mutation.item_revision,
            configuration_revision: db
                .task_board_configuration_revision()
                .await
                .expect("configuration revision"),
            policy_version: "policy-v1".into(),
            reviewer: reviewers.clone(),
            read_only_run_context: Some(TaskBoardReadOnlyRunContext {
                schema_version: TASK_BOARD_READ_ONLY_RUN_CONTEXT_VERSION,
                session_id: format!("session-{label}"),
                title: "Verification retry".into(),
                body: "Atomic parent and child persistence".into(),
                tags: Vec::new(),
                worktree: "/tmp/verification-retry".into(),
            }),
            provider_revision: None,
        },
        resolved_reviewers: reviewers,
        transition: TaskBoardWorkflowTransitionState {
            workflow_kind: TaskBoardWorkflowKind::PrReview,
            phase: Some(TaskBoardExecutionPhase::Publish),
            execution_state: TaskBoardExecutionState::Running,
            pull_request: Some(pull_request),
            exact_head_revision: Some("published-head".into()),
        },
        artifacts: TaskBoardWorkflowExecutionArtifacts::default(),
        ownership: TaskBoardExecutionOwnership {
            host_id: None,
            fencing_epoch: 0,
            resources: BTreeMap::new(),
        },
        available_at: None,
        blocked_reason: None,
        created_at: NOW.into(),
        updated_at: NOW.into(),
        completed_at: None,
        attempts: Vec::new(),
    };
    db.create_or_load_task_board_workflow_execution(&record)
        .await
        .expect("create verification execution");
    db.create_task_board_execution_attempt(&TaskBoardExecutionAttemptRecord {
        execution_id,
        action_key: "publish".into(),
        attempt: 1,
        idempotency_key: format!("publish-{label}"),
        state: TaskBoardAttemptState::Running,
        failure_class: None,
        available_at: None,
        error: None,
        artifact: None,
        started_at: NOW.into(),
        updated_at: NOW.into(),
        completed_at: None,
    })
    .await
    .expect("create running publish attempt");
    let current = load_execution(&db, &record.execution_id).await;
    (db, temp, current)
}

async fn load_execution(
    db: &AsyncDaemonDb,
    execution_id: &str,
) -> TaskBoardWorkflowExecutionRecord {
    db.task_board_workflow_execution(execution_id)
        .await
        .expect("load execution")
        .expect("execution exists")
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
