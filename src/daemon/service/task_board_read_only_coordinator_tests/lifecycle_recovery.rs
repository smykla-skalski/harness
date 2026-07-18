use crate::task_board::{
    TaskBoardAttemptState, TaskBoardExecutionAttemptCas, TaskBoardExecutionState,
    TaskBoardFailureClass, TaskBoardTerminalOutcomeKind, TaskBoardWorkflowExecutionCas,
    TaskBoardWorkflowExecutionCasOutcome, TaskBoardWorkflowKind,
};

use super::fixture::{AttemptSeed, Fixture, NOW, RETRY_AT, seed_execution, seed_publish_attempt};
use super::runtime::FakeReadOnlyRuntime;
use super::{load_execution, tick};

#[tokio::test]
async fn concurrent_reconcilers_claim_one_publish_side_effect() {
    let fixture = seed_publish_attempt(
        "publish-exclusive",
        TaskBoardExecutionState::Running,
        TaskBoardAttemptState::Starting,
    )
    .await;
    let runtime = FakeReadOnlyRuntime::new([]);
    runtime.block_publish();

    let first = super::super::task_board_read_only_coordinator::
        reconcile_task_board_read_only_workflows_with_runtime(
            &fixture.test.db,
            &runtime,
            NOW,
            8,
        );
    let second = super::super::task_board_read_only_coordinator::
        reconcile_task_board_read_only_workflows_with_runtime(
            &fixture.test.db,
            &runtime,
            NOW,
            8,
        );
    let observe = async {
        runtime.wait_for_publish().await;
        tokio::task::yield_now().await;
        assert_eq!(runtime.publish_count(), 1);
        assert_eq!(runtime.verification_count(), 0);
        runtime.release_publish();
    };
    let (first, second, ()) = tokio::join!(first, second, observe);
    assert!(first.expect("first reconcile").failures.is_empty());
    assert!(second.expect("second reconcile").failures.is_empty());

    let execution = load_execution(&fixture).await;
    assert_eq!(
        execution.attempts[0].state,
        TaskBoardAttemptState::Completed
    );
    assert_eq!(runtime.publish_count(), 1);
    assert_eq!(runtime.verification_count(), 1);
}

#[tokio::test]
async fn recovered_running_publish_accepts_exact_head_approval_without_mutation() {
    let fixture = seed_publish_attempt(
        "publish-recovered-approved",
        TaskBoardExecutionState::Running,
        TaskBoardAttemptState::Running,
    )
    .await;
    let runtime = FakeReadOnlyRuntime::new([]);
    runtime.set_approved(true);

    tick(&fixture, &runtime, NOW).await;

    let execution = load_execution(&fixture).await;
    assert_eq!(
        execution.attempts[0].state,
        TaskBoardAttemptState::Completed
    );
    assert_eq!(runtime.publish_count(), 0);
    assert_eq!(runtime.verification_count(), 1);
    let lifecycle = execution.attempts[0]
        .artifact
        .as_ref()
        .expect("verified lifecycle evidence");
    assert!(matches!(
        lifecycle,
        crate::task_board::TaskBoardAttemptResultArtifact::Lifecycle(outcome)
            if !outcome.mutated
    ));
}

#[tokio::test]
async fn recovered_running_publish_absent_fails_closed_without_retry() {
    let fixture = seed_publish_attempt(
        "publish-recovered-absent",
        TaskBoardExecutionState::Running,
        TaskBoardAttemptState::Running,
    )
    .await;
    let runtime = FakeReadOnlyRuntime::new([]);

    tick(&fixture, &runtime, NOW).await;

    let execution = load_execution(&fixture).await;
    assert_eq!(execution.attempts[0].state, TaskBoardAttemptState::Unknown);
    assert_eq!(
        execution.attempts[0].failure_class,
        Some(TaskBoardFailureClass::UnknownOutcome)
    );
    assert_eq!(
        execution.transition.execution_state,
        TaskBoardExecutionState::HumanRequired
    );
    assert_eq!(
        execution.blocked_reason.as_deref(),
        Some("publish_outcome_unknown")
    );
    assert_eq!(runtime.publish_count(), 0);
    assert_eq!(runtime.verification_count(), 1);
}

#[tokio::test]
async fn unknown_publish_child_repairs_parent_without_publish_or_verification() {
    let fixture = seed_publish_attempt(
        "publish-unknown-crash-gap",
        TaskBoardExecutionState::Starting,
        TaskBoardAttemptState::Running,
    )
    .await;
    let execution = load_execution(&fixture).await;
    let current = execution.attempts[0].clone();
    let mut unknown = current.clone();
    unknown.state = TaskBoardAttemptState::Unknown;
    unknown.failure_class = Some(TaskBoardFailureClass::UnknownOutcome);
    unknown.error = Some("approval outcome became ambiguous before parent settlement".into());
    super::super::task_board_workflow_execution::record_workflow_execution_attempt(
        &fixture.test.db,
        &TaskBoardExecutionAttemptCas::from(&current),
        &unknown,
    )
    .await
    .expect("persist publish child before simulated crash");
    let runtime = FakeReadOnlyRuntime::new([]);
    runtime.set_approved(true);

    tick(&fixture, &runtime, NOW).await;
    tick(&fixture, &runtime, NOW).await;

    let settled = load_execution(&fixture).await;
    assert_eq!(settled.attempts.len(), 1);
    assert_eq!(settled.attempts[0].state, TaskBoardAttemptState::Unknown);
    assert_eq!(
        settled.transition.execution_state,
        TaskBoardExecutionState::HumanRequired
    );
    assert_eq!(
        settled.blocked_reason.as_deref(),
        Some("attempt_outcome_unknown")
    );
    assert_eq!(
        settled
            .artifacts
            .terminal_outcome
            .as_ref()
            .map(|outcome| outcome.kind),
        Some(TaskBoardTerminalOutcomeKind::Unknown)
    );
    assert_eq!(runtime.publish_count(), 0);
    assert_eq!(runtime.verification_count(), 0);
}

#[tokio::test]
async fn ambiguous_publish_absent_never_reposts_on_later_ticks() {
    let fixture = seed_publish_attempt(
        "publish-error-absent",
        TaskBoardExecutionState::Running,
        TaskBoardAttemptState::Starting,
    )
    .await;
    let runtime = FakeReadOnlyRuntime::new([]);
    runtime.set_publish_error("approval response was lost", false);

    tick(&fixture, &runtime, NOW).await;
    tick(&fixture, &runtime, "2026-07-17T11:00:00Z").await;
    tick(&fixture, &runtime, "2026-07-17T12:00:00Z").await;

    let execution = load_execution(&fixture).await;
    assert_eq!(execution.attempts.len(), 1);
    assert_eq!(execution.attempts[0].state, TaskBoardAttemptState::Unknown);
    assert_eq!(
        execution.transition.execution_state,
        TaskBoardExecutionState::HumanRequired
    );
    assert_eq!(runtime.publish_count(), 1);
    assert_eq!(runtime.verification_count(), 1);
}

#[tokio::test]
async fn young_running_publish_waits_without_verification_or_mutation() {
    let fixture = seed_publish_attempt(
        "publish-young-running",
        TaskBoardExecutionState::Running,
        TaskBoardAttemptState::Running,
    )
    .await;
    set_publish_deadline(&fixture, RETRY_AT).await;
    let runtime = FakeReadOnlyRuntime::new([]);
    runtime.set_approved(true);

    tick(&fixture, &runtime, NOW).await;

    let execution = load_execution(&fixture).await;
    assert_eq!(execution.attempts[0].state, TaskBoardAttemptState::Running);
    assert_eq!(runtime.publish_count(), 0);
    assert_eq!(runtime.verification_count(), 0);
}

#[tokio::test]
async fn unavailable_approval_verification_fails_closed_as_unknown() {
    let fixture = seed_publish_attempt(
        "publish-verification-unknown",
        TaskBoardExecutionState::Running,
        TaskBoardAttemptState::Running,
    )
    .await;
    let runtime = FakeReadOnlyRuntime::new([]);
    runtime.set_verification_error("approval lookup unavailable");

    tick(&fixture, &runtime, NOW).await;

    let execution = load_execution(&fixture).await;
    assert_eq!(execution.attempts[0].state, TaskBoardAttemptState::Unknown);
    assert_eq!(
        execution.transition.execution_state,
        TaskBoardExecutionState::HumanRequired
    );
    assert_eq!(
        execution.blocked_reason.as_deref(),
        Some("publish_outcome_unknown")
    );
    assert_eq!(runtime.publish_count(), 0);
    assert_eq!(runtime.verification_count(), 1);
}

#[tokio::test]
async fn ambiguous_publish_error_completes_when_exact_head_approval_is_observed() {
    let fixture = seed_publish_attempt(
        "publish-error-applied",
        TaskBoardExecutionState::Running,
        TaskBoardAttemptState::Starting,
    )
    .await;
    let runtime = FakeReadOnlyRuntime::new([]);
    runtime.set_publish_error("approval response was lost", true);

    tick(&fixture, &runtime, NOW).await;

    let execution = load_execution(&fixture).await;
    assert_eq!(
        execution.attempts[0].state,
        TaskBoardAttemptState::Completed
    );
    assert_eq!(runtime.publish_count(), 1);
    assert_eq!(runtime.verification_count(), 1);
}

#[tokio::test]
async fn starting_publish_revision_drift_is_rejected_by_atomic_claim() {
    let fixture = seed_publish_attempt(
        "publish-starting-fenced",
        TaskBoardExecutionState::Running,
        TaskBoardAttemptState::Starting,
    )
    .await;
    fixture
        .test
        .db
        .update_task_board_item(&fixture.item_id, |item| {
            item.title = "Changed before publish claim".into();
            Ok(true)
        })
        .await
        .expect("mutate before publish claim")
        .expect("publish item mutation");
    let execution = load_execution(&fixture).await;
    let current = execution.attempts[0].clone();
    let mut claimed = current.clone();
    claimed.state = TaskBoardAttemptState::Running;
    claimed.available_at = Some(RETRY_AT.into());

    let error = fixture
        .test
        .db
        .claim_task_board_workflow_side_effect(
            &TaskBoardWorkflowExecutionCas::from(&execution),
            &TaskBoardExecutionAttemptCas::from(&current),
            &claimed,
            NOW,
        )
        .await
        .expect_err("stale revision must reject the publish claim");

    assert!(
        error
            .to_string()
            .contains("changed before side-effect claim")
    );
    assert_eq!(
        load_execution(&fixture).await.attempts[0].state,
        TaskBoardAttemptState::Starting
    );
}

#[tokio::test]
async fn running_publish_claim_rejects_public_item_mutation() {
    let fixture = seed_publish_attempt(
        "publish-running-fenced",
        TaskBoardExecutionState::Running,
        TaskBoardAttemptState::Running,
    )
    .await;
    let before = fixture
        .test
        .db
        .task_board_item_snapshot(&fixture.item_id)
        .await
        .expect("item before mutation");

    let error = fixture
        .test
        .db
        .update_task_board_item(&fixture.item_id, |item| {
            item.title = "Changed while publish was claimed".into();
            Ok(true)
        })
        .await
        .expect_err("running publish claim must fence item mutation");

    assert!(
        error
            .to_string()
            .contains("read-only side effect is claimed")
    );
    let after = fixture
        .test
        .db
        .task_board_item_snapshot(&fixture.item_id)
        .await
        .expect("item after rejected mutation");
    assert_eq!(after.item_revision, before.item_revision);
    assert_eq!(after.item.title, before.item.title);
}

#[tokio::test]
async fn successful_publish_requires_final_exact_head_verification() {
    let fixture = seed_publish_attempt(
        "publish-success-head-drift",
        TaskBoardExecutionState::Running,
        TaskBoardAttemptState::Starting,
    )
    .await;
    let runtime = FakeReadOnlyRuntime::new([]);
    runtime.block_publish();
    let reconcile = super::super::task_board_read_only_coordinator::
        reconcile_task_board_read_only_workflows_with_runtime(&fixture.test.db, &runtime, NOW, 8);
    let drift = async {
        runtime.wait_for_publish().await;
        runtime.set_head("head-moved-after-publish-claim");
        runtime.release_publish();
    };

    let (report, ()) = tokio::join!(reconcile, drift);

    assert!(report.expect("reconcile publish").failures.is_empty());
    let execution = load_execution(&fixture).await;
    assert_eq!(execution.attempts[0].state, TaskBoardAttemptState::Unknown);
    assert_eq!(
        execution.transition.execution_state,
        TaskBoardExecutionState::HumanRequired
    );
    assert_eq!(runtime.publish_count(), 1);
    assert_eq!(runtime.verification_count(), 1);
}

#[tokio::test]
async fn stale_parent_state_claim_prevents_report_start_and_publish() {
    let report = seed_execution(
        "stale-report-parent",
        TaskBoardWorkflowKind::Review,
        TaskBoardExecutionState::Running,
        Some(AttemptSeed {
            state: TaskBoardAttemptState::Starting,
            failure_class: None,
            available_at: None,
            error: None,
            completed_at: None,
        }),
    )
    .await;
    let stale_report = load_execution(&report).await;
    stop_parent_after_load(&report).await;
    let report_runtime = FakeReadOnlyRuntime::new([]);

    let error =
        super::super::task_board_read_only_coordinator::reconcile_preloaded_read_only_execution(
            &report.test.db,
            &report_runtime,
            stale_report,
            NOW,
        )
        .await
        .expect_err("stale report parent claim must fail");
    assert_eq!(error.code(), "WORKFLOW_CONCURRENT");
    assert_eq!(report_runtime.start_count(), 0);

    let publish = seed_publish_attempt(
        "stale-publish-parent",
        TaskBoardExecutionState::Running,
        TaskBoardAttemptState::Starting,
    )
    .await;
    let stale_publish = load_execution(&publish).await;
    stop_parent_after_load(&publish).await;
    let publish_runtime = FakeReadOnlyRuntime::new([]);

    let error =
        super::super::task_board_read_only_coordinator::reconcile_preloaded_read_only_execution(
            &publish.test.db,
            &publish_runtime,
            stale_publish,
            NOW,
        )
        .await
        .expect_err("stale publish parent claim must fail");
    assert_eq!(error.code(), "WORKFLOW_CONCURRENT");
    assert_eq!(publish_runtime.publish_count(), 0);
    assert_eq!(publish_runtime.verification_count(), 0);
}

async fn set_publish_deadline(fixture: &Fixture, available_at: &str) {
    let execution = load_execution(fixture).await;
    let current = execution.attempts[0].clone();
    let mut updated = current.clone();
    updated.available_at = Some(available_at.into());
    super::super::task_board_workflow_execution::record_workflow_execution_attempt(
        &fixture.test.db,
        &TaskBoardExecutionAttemptCas::from(&current),
        &updated,
    )
    .await
    .expect("set publish claim deadline");
}

async fn stop_parent_after_load(fixture: &Fixture) {
    let current = load_execution(fixture).await;
    let mut stopped = current.clone();
    super::super::task_board_workflow_execution::require_human(
        &mut stopped,
        "concurrent_stop",
        NOW,
    );
    let outcome = fixture
        .test
        .db
        .compare_and_set_task_board_workflow_execution(
            &TaskBoardWorkflowExecutionCas::from(&current),
            &stopped,
        )
        .await
        .expect("stop parent after stale load");
    assert!(matches!(
        outcome,
        TaskBoardWorkflowExecutionCasOutcome::Updated(_)
    ));
}
