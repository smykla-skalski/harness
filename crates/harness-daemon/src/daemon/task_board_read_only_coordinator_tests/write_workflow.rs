use crate::task_board::{
    TaskBoardAttemptResultArtifact, TaskBoardAttemptState, TaskBoardExecutionAttemptRecord,
    TaskBoardExecutionPhase, TaskBoardExecutionState, TaskBoardPhaseVerdict,
    TaskBoardPlanApprovalInvalidation, TaskBoardStatus, TaskBoardWorkflowExecutionRecord,
    TaskBoardWorkflowKind, TaskBoardWorkflowStatus,
};

use self::fixture as write_fixture;
use super::driver::HeadlessWorkflowDriver;
use super::fixture::{Fixture, NOW};
use runtime::{FakeWriteRuntime, PlannedRun};

mod fixture;
mod runtime;
mod verification_exhaustion;

const BASE_HEAD: &str = "head-base";
const FIRST_HEAD: &str = "head-first";
const SECOND_HEAD: &str = "head-second";
const RETRY_AT: &str = "2026-07-17T10:05:00Z";

#[tokio::test]
async fn write_workflow_runs_revision_cycle_publish_cleanup_and_projection() {
    let fixture = Box::pin(write_fixture::seed_write_execution("write-lifecycle")).await;
    let runtime = FakeWriteRuntime::new([
        PlannedRun::implementation(1, 1, BASE_HEAD, FIRST_HEAD),
        PlannedRun::review(1, FIRST_HEAD, TaskBoardPhaseVerdict::ChangesRequired),
        PlannedRun::implementation(2, 1, FIRST_HEAD, SECOND_HEAD),
        PlannedRun::review(2, SECOND_HEAD, TaskBoardPhaseVerdict::Pass),
        PlannedRun::evaluation(2, SECOND_HEAD),
    ]);

    drive_to_terminal(&fixture, &runtime).await;

    let execution = load_execution(&fixture).await;
    assert_eq!(execution.artifacts.current_revision_cycle, 2);
    assert_eq!(
        execution.transition.phase,
        Some(TaskBoardExecutionPhase::Terminal)
    );
    assert_eq!(
        execution.transition.execution_state,
        TaskBoardExecutionState::Completed
    );
    assert_eq!(
        execution.transition.exact_head_revision.as_deref(),
        Some(SECOND_HEAD)
    );
    assert_eq!(
        execution
            .transition
            .pull_request
            .as_ref()
            .map(|pr| pr.number),
        Some(42)
    );
    assert_eq!(execution.artifacts.review_cycles.len(), 2);
    assert!(
        execution.attempts.iter().all(|attempt| {
            attempt.state == crate::task_board::TaskBoardAttemptState::Completed
        })
    );
    assert_eq!(runtime.start_count(), 5);
    assert_eq!(runtime.publish_count(), 1);
    let item = fixture
        .test
        .db
        .task_board_item(&fixture.item_id)
        .await
        .expect("load projected item");
    assert_eq!(item.status, TaskBoardStatus::Done);
    assert_eq!(item.workflow.status, TaskBoardWorkflowStatus::Completed);
    assert_eq!(item.workflow.pr_number, Some(42));
    assert_eq!(
        item.workflow.pr_url.as_deref(),
        Some("https://github.com/example/compass/pull/42")
    );
}

#[tokio::test]
async fn dependency_update_review_resumes_every_stage_after_restart() {
    let fixture = Box::pin(write_fixture::seed_write_execution_kind(
        "dependency-update",
        TaskBoardWorkflowKind::PrFixReview,
    ))
    .await;
    let runtime = FakeWriteRuntime::new([
        PlannedRun::implementation(1, 1, BASE_HEAD, FIRST_HEAD),
        PlannedRun::review(1, FIRST_HEAD, TaskBoardPhaseVerdict::Pass),
        PlannedRun::evaluation(1, FIRST_HEAD),
    ]);

    drive_to_terminal(&fixture, &runtime).await;

    let execution = load_execution(&fixture).await;
    assert_eq!(
        execution.transition.phase,
        Some(TaskBoardExecutionPhase::Terminal)
    );
    assert_eq!(
        execution.transition.execution_state,
        TaskBoardExecutionState::Completed
    );
    assert_eq!(
        execution
            .transition
            .pull_request
            .as_ref()
            .map(|pull_request| pull_request.number),
        Some(17)
    );
    let item = fixture
        .test
        .db
        .task_board_item(&fixture.item_id)
        .await
        .expect("load projected dependency-update item");
    assert_eq!(
        item.workflow.pr_url.as_deref(),
        Some("https://github.com/example/compass/pull/17")
    );
    assert_eq!(runtime.start_count(), 3);
    assert_eq!(runtime.publish_count(), 1);

    let attempts_before_restart = execution.attempts.clone();
    tick(&fixture, &runtime).await;
    let after_restart = load_execution(&fixture).await;
    assert_eq!(after_restart.attempts, attempts_before_restart);
    assert_eq!(runtime.start_count(), 3);
    assert_eq!(runtime.publish_count(), 1);
}

#[tokio::test]
async fn transient_publication_verification_recovers_on_bounded_retry() {
    let fixture = Box::pin(write_fixture::seed_write_execution(
        "write-publication-verification-retry",
    ))
    .await;
    let runtime = FakeWriteRuntime::new([
        PlannedRun::implementation(1, 1, BASE_HEAD, FIRST_HEAD),
        PlannedRun::review(1, FIRST_HEAD, TaskBoardPhaseVerdict::Pass),
        PlannedRun::evaluation(1, FIRST_HEAD),
    ]);
    runtime.fail_next_verification("GitHub head is not visible yet");

    for _ in 0..24 {
        tick(&fixture, &runtime).await;
        if runtime.verification_count() == 1 {
            break;
        }
    }
    let waiting = load_execution(&fixture).await;
    assert_eq!(runtime.publish_count(), 1);
    assert_eq!(runtime.verification_count(), 1);
    assert_eq!(
        waiting.transition.execution_state,
        TaskBoardExecutionState::Running
    );
    assert!(
        waiting.artifacts.diagnostics.iter().any(|diagnostic| {
            diagnostic.code == "publish_verification_failed"
                && diagnostic
                    .message
                    .contains("GitHub head is not visible yet")
        }),
        "{waiting:#?}"
    );
    let waiting_publish = waiting
        .attempts
        .iter()
        .find(|attempt| attempt.action_key == "publish")
        .expect("waiting publish attempt");
    assert!(waiting_publish.available_at.is_some());
    assert!(matches!(
        waiting_publish.artifact.as_ref(),
        Some(TaskBoardAttemptResultArtifact::Lifecycle(outcome))
            if outcome.mutated
                && outcome.external_url.as_deref()
                    == Some("https://github.com/example/compass/pull/42")
    ));

    for _ in 0..12 {
        tick_at(&fixture, &runtime, RETRY_AT).await;
        if load_execution(&fixture).await.transition.phase
            == Some(TaskBoardExecutionPhase::Terminal)
        {
            break;
        }
    }
    let completed = load_execution(&fixture).await;
    assert_eq!(runtime.verification_count(), 2);
    assert_eq!(
        runtime.verification_urls(),
        vec![
            Some("https://github.com/example/compass/pull/42".into()),
            Some("https://github.com/example/compass/pull/42".into()),
        ]
    );
    assert_eq!(
        completed.transition.phase,
        Some(TaskBoardExecutionPhase::Terminal)
    );
    assert!(completed.attempts.iter().any(|attempt| {
        matches!(
            attempt.artifact.as_ref(),
            Some(TaskBoardAttemptResultArtifact::Lifecycle(outcome)) if outcome.mutated
        )
    }));
}

#[tokio::test]
async fn ambiguous_write_publication_is_verified_without_a_second_mutation() {
    let fixture = Box::pin(write_fixture::seed_write_execution(
        "write-publication-ambiguous",
    ))
    .await;
    let runtime = FakeWriteRuntime::new([
        PlannedRun::implementation(1, 1, BASE_HEAD, FIRST_HEAD),
        PlannedRun::review(1, FIRST_HEAD, TaskBoardPhaseVerdict::Pass),
        PlannedRun::evaluation(1, FIRST_HEAD),
    ]);
    runtime.fail_next_publish_after_mutation("connection closed after push");

    drive_to_terminal(&fixture, &runtime).await;

    assert_eq!(runtime.publish_count(), 1);
    assert_eq!(runtime.verification_count(), 1);
    assert_eq!(
        load_execution(&fixture).await.transition.phase,
        Some(TaskBoardExecutionPhase::Terminal)
    );
}

#[tokio::test]
async fn merged_after_ambiguous_publish_recovers_without_a_second_mutation() {
    let fixture = Box::pin(write_fixture::seed_write_execution(
        "write-publication-merged-recovery",
    ))
    .await;
    let runtime = FakeWriteRuntime::new([
        PlannedRun::implementation(1, 1, BASE_HEAD, FIRST_HEAD),
        PlannedRun::review(1, FIRST_HEAD, TaskBoardPhaseVerdict::Pass),
        PlannedRun::evaluation(1, FIRST_HEAD),
    ]);
    runtime.fail_next_publish_after_mutation("pull request merged before response arrived");

    drive_to_terminal(&fixture, &runtime).await;

    let execution = load_execution(&fixture).await;
    assert_eq!(runtime.publish_count(), 1);
    assert_eq!(runtime.verification_count(), 1);
    assert_eq!(
        execution.transition.execution_state,
        TaskBoardExecutionState::Completed
    );
    assert!(
        execution.attempts.iter().any(|attempt| {
            matches!(
                attempt.artifact.as_ref(),
                Some(TaskBoardAttemptResultArtifact::Lifecycle(outcome))
                    if outcome.external_url.as_deref()
                            == Some("https://github.com/example/compass/pull/42")
            )
        }),
        "{execution:#?}"
    );
}

#[tokio::test]
async fn implementation_result_with_unrelated_base_is_rejected_before_review() {
    let fixture = Box::pin(write_fixture::seed_write_execution(
        "write-unrelated-implementation",
    ))
    .await;
    let runtime = FakeWriteRuntime::new([PlannedRun::implementation(1, 1, BASE_HEAD, FIRST_HEAD)]);
    runtime.reject_implementation_ancestry();

    for _ in 0..4 {
        tick(&fixture, &runtime).await;
    }

    let execution = load_execution(&fixture).await;
    assert_eq!(
        execution.transition.execution_state,
        TaskBoardExecutionState::HumanRequired
    );
    assert_eq!(
        execution.blocked_reason.as_deref(),
        Some("implementation_ancestry_invalid")
    );
    assert_eq!(runtime.start_count(), 1);
    assert_eq!(runtime.publish_count(), 0);
}

#[tokio::test]
async fn write_workflow_policy_drift_invalidates_the_approved_plan() {
    let fixture = Box::pin(write_fixture::seed_write_execution("write-policy-drift")).await;
    let runtime = FakeWriteRuntime::new([]);
    let mut settings = fixture
        .test
        .db
        .task_board_orchestrator_settings()
        .await
        .expect("load settings");
    settings.policy_version = "policy-v2".into();
    fixture
        .test
        .db
        .replace_task_board_orchestrator_settings(&settings)
        .await
        .expect("replace settings");

    tick(&fixture, &runtime).await;

    let execution = load_execution(&fixture).await;
    assert_eq!(
        execution.transition.execution_state,
        TaskBoardExecutionState::HumanRequired
    );
    assert_eq!(
        execution.blocked_reason.as_deref(),
        Some("plan_approval_invalidated")
    );
    assert_eq!(
        execution.artifacts.approval_invalidations,
        vec![
            TaskBoardPlanApprovalInvalidation::ConfigurationRevisionChanged,
            TaskBoardPlanApprovalInvalidation::PolicyVersionChanged,
        ]
    );
    assert_eq!(runtime.start_count(), 0);
}

#[tokio::test]
async fn legacy_write_execution_without_task_identity_fails_closed() {
    let fixture = Box::pin(write_fixture::seed_write_execution_with_task(
        "write-missing-task",
        None,
    ))
    .await;
    let runtime = FakeWriteRuntime::new([]);

    tick(&fixture, &runtime).await;

    let execution = load_execution(&fixture).await;
    assert_eq!(
        execution.transition.execution_state,
        TaskBoardExecutionState::HumanRequired
    );
    assert_eq!(
        execution.blocked_reason.as_deref(),
        Some("write_task_id_missing")
    );
    assert_eq!(runtime.start_count(), 0);
}

#[tokio::test]
async fn invalid_recovery_state_requires_human_instead_of_retrying_forever() {
    let fixture = Box::pin(write_fixture::seed_write_execution(
        "write-invalid-recovery",
    ))
    .await;
    let mut corrupted = load_execution(&fixture).await;
    let execution_id = corrupted.execution_id.clone();
    corrupted.attempts = vec![
        active_attempt(&execution_id, 1),
        active_attempt(&execution_id, 2),
    ];

    assert!(
        crate::daemon::task_board_read_only_coordinator::refuse_invalid_recovery(
            &fixture.test.db,
            &corrupted,
            NOW,
        )
        .await
        .expect("refuse invalid recovery")
    );

    let execution = load_execution(&fixture).await;
    assert_eq!(
        execution.transition.execution_state,
        TaskBoardExecutionState::HumanRequired
    );
    assert_eq!(
        execution.blocked_reason.as_deref(),
        Some("dependency_recovery_invalid")
    );
    assert!(
        execution
            .artifacts
            .terminal_outcome
            .as_ref()
            .is_some_and(|outcome| outcome.summary.contains("multiple active attempts"))
    );
}

fn active_attempt(execution_id: &str, attempt: u32) -> TaskBoardExecutionAttemptRecord {
    TaskBoardExecutionAttemptRecord {
        execution_id: execution_id.into(),
        action_key: "implementation:1".into(),
        attempt,
        idempotency_key: format!("{execution_id}:implementation:1:{attempt}"),
        state: TaskBoardAttemptState::Running,
        failure_class: None,
        available_at: None,
        error: None,
        artifact: None,
        started_at: NOW.into(),
        updated_at: NOW.into(),
        completed_at: None,
    }
}

async fn drive_to_terminal(fixture: &Fixture, runtime: &FakeWriteRuntime) {
    HeadlessWorkflowDriver::new(fixture, runtime)
        .drive_to_terminal_projection(NOW, 32)
        .await;
}

async fn tick(fixture: &Fixture, runtime: &FakeWriteRuntime) {
    tick_at(fixture, runtime, NOW).await;
}

async fn tick_at(fixture: &Fixture, runtime: &FakeWriteRuntime, now: &str) {
    HeadlessWorkflowDriver::new(fixture, runtime)
        .tick(now)
        .await;
}

async fn load_execution(fixture: &Fixture) -> TaskBoardWorkflowExecutionRecord {
    fixture
        .test
        .db
        .task_board_workflow_execution(&fixture.execution_id)
        .await
        .expect("load execution")
        .expect("execution exists")
}
