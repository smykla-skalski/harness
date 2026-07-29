//! Harvesting a finished attempt must not depend on the prompt catalog. The
//! prompt is configuration and the result is already durable, so a template an
//! operator has since broken cannot be allowed to stand between the two.

use crate::daemon::protocol::CodexRunStatus;
use crate::task_board::prompt_catalog::{
    PromptCatalog, prompt_catalog_test_lock, scoped_prompt_catalog,
};
use crate::task_board::{
    TaskBoardAttemptState, TaskBoardExecutionState, TaskBoardFailureClass, TaskBoardWorkflowKind,
};

use super::super::task_board_read_only_coordinator::reconcile_task_board_read_only_workflows_with_runtime;
use super::fixture::{AttemptSeed, NOW, seed_execution};
use super::load_execution;
use super::runtime::{FakeReadOnlyRuntime, PlannedReport};

/// The failure this pins: reconciliation rendered the attempt request before it
/// loaded the run, purely to learn the mode. A review that had already finished
/// under the shipped prompt then stalled in `Running` forever the moment the
/// operator customized `read_only_review` to name a fact this execution has no
/// value for, and the error was swallowed into the pass report.
#[tokio::test]
async fn a_finished_attempt_is_harvested_when_its_prompt_cannot_render() {
    let _lock = prompt_catalog_test_lock();
    let fixture = seed_execution(
        "report-unrenderable-harvest",
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
    let runtime = FakeReadOnlyRuntime::new([PlannedReport::running_review()]);

    reconcile_task_board_read_only_workflows_with_runtime(&fixture.test.db, &runtime, NOW, 8)
        .await
        .expect("start the review under the shipped prompt");
    assert_eq!(
        load_execution(&fixture).await.attempts[0].state,
        TaskBoardAttemptState::Running
    );

    runtime.set_all_run_statuses(CodexRunStatus::Completed);
    // A Review workflow has no pull request, so this template renders for
    // nothing this execution can supply.
    let _installed = scoped_prompt_catalog(
        PromptCatalog::from_json(br#"{"read_only_review": "Review {{ pull_request }}"}"#)
            .expect("parse overrides"),
    );

    reconcile_task_board_read_only_workflows_with_runtime(&fixture.test.db, &runtime, NOW, 8)
        .await
        .expect("harvest the finished review");

    assert_eq!(
        load_execution(&fixture).await.attempts[0].state,
        TaskBoardAttemptState::Completed
    );
}

/// Starting a run is the one thing that genuinely needs the prompt. It refuses
/// where an operator can see it rather than stalling the attempt every tick,
/// and it refuses before claiming the side effect, so nothing was launched.
#[tokio::test]
async fn an_attempt_whose_prompt_cannot_render_refuses_visibly() {
    let _lock = prompt_catalog_test_lock();
    let fixture = seed_execution(
        "report-unrenderable-start",
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
    let runtime = FakeReadOnlyRuntime::new([]);
    let _installed = scoped_prompt_catalog(
        PromptCatalog::from_json(br#"{"read_only_review": "Review {{ pull_request }}"}"#)
            .expect("parse overrides"),
    );

    let report =
        reconcile_task_board_read_only_workflows_with_runtime(&fixture.test.db, &runtime, NOW, 8)
            .await
            .expect("refuse the unrenderable attempt");

    assert!(report.failures.is_empty(), "{:?}", report.failures);
    let execution = load_execution(&fixture).await;
    assert_eq!(execution.attempts[0].state, TaskBoardAttemptState::Failed);
    assert_eq!(
        execution.attempts[0].failure_class,
        Some(TaskBoardFailureClass::Permanent)
    );
    assert!(
        execution.attempts[0]
            .error
            .as_deref()
            .is_some_and(|error| error.contains("pull_request")),
        "{:?}",
        execution.attempts[0].error
    );
    assert_eq!(
        execution.transition.execution_state,
        TaskBoardExecutionState::HumanRequired
    );
    assert_eq!(runtime.start_count(), 0);
}
