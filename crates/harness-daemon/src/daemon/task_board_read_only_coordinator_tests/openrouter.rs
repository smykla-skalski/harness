//! Coordinator-level proof of slice A of #1001: a local board review whose
//! reviewer profile names an agent-turn runtime starts on that runtime, is
//! recorded durably in `agent_turn_runs` the moment it starts, and resumes
//! exactly once across a daemon restart without duplicating agent work. A
//! Codex profile is left on the unchanged Codex path (covered elsewhere).
//!
//! These run against a real on-disk database and the real coordinator; the
//! fake runtime stands in only for the runtime handle that would spawn the
//! provider, recording the run exactly as the production adapter does.

use crate::daemon::db::{AgentTurnRunStatus, AsyncDaemonDb};
use crate::daemon::protocol::TaskBoardGetItemRequest;
use crate::task_board::{
    TaskBoardAiReviewReportResponse, TaskBoardAttemptState, TaskBoardExecutionState,
};

use super::fixture::{Fixture, NOW, RETRY_AT, seed_execution_with_reviewer_runtime};
use super::runtime::FakeReadOnlyRuntime;

async fn reconcile(db: &AsyncDaemonDb, runtime: &FakeReadOnlyRuntime, now: &str) {
    let report = super::super::task_board_read_only_coordinator::
        reconcile_task_board_read_only_workflows_with_runtime(db, runtime, now, 8)
            .await
            .expect("reconcile agent-turn workflow");
    assert!(report.failures.is_empty(), "{:?}", report.failures);
}

async fn load(
    fixture: &Fixture,
    db: &AsyncDaemonDb,
) -> crate::task_board::TaskBoardWorkflowExecutionRecord {
    db.task_board_workflow_execution(&fixture.execution_id)
        .await
        .expect("load execution")
        .expect("execution exists")
}

#[tokio::test]
async fn openrouter_reviewer_starts_and_durably_tracks_an_agent_turn() {
    let fixture = Box::pin(seed_execution_with_reviewer_runtime(
        "or-start",
        "openrouter",
    ))
    .await;
    let db = AsyncDaemonDb::connect(&fixture.test.path)
        .await
        .expect("open coordinator database");
    let store = AsyncDaemonDb::connect(&fixture.test.path)
        .await
        .expect("open runtime store");
    let runtime = FakeReadOnlyRuntime::new([]).with_durable_db(store);

    // Schedule the review attempt, then claim and start it.
    reconcile(&db, &runtime, NOW).await;
    reconcile(&db, &runtime, NOW).await;

    let execution = load(&fixture, &db).await;
    assert_eq!(execution.attempts.len(), 1);
    assert_eq!(execution.attempts[0].state, TaskBoardAttemptState::Running);
    assert_eq!(
        execution.transition.execution_state,
        TaskBoardExecutionState::Running
    );
    assert_eq!(runtime.start_count(), 1);

    let attempt_key = execution.attempts[0].idempotency_key.clone();
    let run = db
        .agent_turn_run(&attempt_key)
        .await
        .expect("load durable run")
        .expect("run recorded at start");
    assert_eq!(run.requested_runtime, "openrouter");
    assert_eq!(run.actual_runtime.as_deref(), Some("openrouter"));
    assert_eq!(run.status, AgentTurnRunStatus::Running);
    assert_eq!(run.board_item_id.as_deref(), Some(fixture.item_id.as_str()));
    assert_eq!(
        run.workflow_execution_id.as_deref(),
        Some(fixture.execution_id.as_str())
    );
    // The turn is tracked in the provider-neutral agent turn store.
    assert!(
        db.codex_run(&attempt_key)
            .await
            .expect("codex run lookup")
            .is_none()
    );
    let reopened = AsyncDaemonDb::connect(&fixture.test.path)
        .await
        .expect("reopen database for ticket report");
    let report = crate::daemon::service::get_task_board_ai_review_report_db(
        &reopened,
        &TaskBoardGetItemRequest {
            id: fixture.item_id.clone(),
        },
    )
    .await
    .expect("load originating ticket report after reopen");
    assert!(matches!(
        report,
        TaskBoardAiReviewReportResponse::Running {
            runtime,
            requested_runtime,
            actual_runtime: Some(actual_runtime),
            ..
        } if runtime == "openrouter"
            && requested_runtime == "openrouter"
            && actual_runtime == "openrouter"
    ));

    // Re-reconciling the running attempt is idempotent: no second turn starts.
    reconcile(&db, &runtime, NOW).await;
    assert_eq!(runtime.start_count(), 1);
}

#[tokio::test]
async fn an_unknown_reviewer_runtime_is_refused_by_name_not_run_as_codex() {
    let fixture = Box::pin(seed_execution_with_reviewer_runtime("or-unknown", "gemini")).await;
    let db = AsyncDaemonDb::connect(&fixture.test.path)
        .await
        .expect("open coordinator database");
    let store = AsyncDaemonDb::connect(&fixture.test.path)
        .await
        .expect("open runtime store");
    let runtime = FakeReadOnlyRuntime::new([]).with_durable_db(store);

    // Schedule the attempt, then reconcile it: an unsupported runtime is refused.
    reconcile(&db, &runtime, NOW).await;
    reconcile(&db, &runtime, NOW).await;

    let execution = load(&fixture, &db).await;
    assert_eq!(
        execution.transition.execution_state,
        TaskBoardExecutionState::HumanRequired
    );
    assert_eq!(execution.attempts.len(), 1);
    assert_eq!(execution.attempts[0].state, TaskBoardAttemptState::Failed);
    assert!(
        execution.attempts[0]
            .error
            .as_deref()
            .is_some_and(|error| error.contains("gemini")),
        "{execution:?}"
    );
    assert_eq!(
        execution.blocked_reason.as_deref(),
        Some("reviewer_runtime_unsupported")
    );
    // Nothing was started: no turn and no durable agent-turn run.
    assert_eq!(runtime.start_count(), 0);
    let attempt_key = execution.attempts[0].idempotency_key.clone();
    assert!(
        db.codex_run(&attempt_key)
            .await
            .expect("codex run lookup")
            .is_none()
    );
    assert!(
        db.agent_turn_run(&attempt_key)
            .await
            .expect("agent turn run lookup")
            .is_none()
    );
}

#[tokio::test]
async fn interrupted_openrouter_review_resumes_exactly_once_across_a_restart() {
    let fixture = Box::pin(seed_execution_with_reviewer_runtime(
        "or-restart",
        "openrouter",
    ))
    .await;
    let db = AsyncDaemonDb::connect(&fixture.test.path)
        .await
        .expect("open coordinator database");
    let store = AsyncDaemonDb::connect(&fixture.test.path)
        .await
        .expect("open runtime store");
    let runtime = FakeReadOnlyRuntime::new([]).with_durable_db(store);

    reconcile(&db, &runtime, NOW).await;
    reconcile(&db, &runtime, NOW).await;
    let first_key = load(&fixture, &db).await.attempts[0]
        .idempotency_key
        .clone();
    assert_eq!(runtime.start_count(), 1);

    // A fresh runtime cannot observe the old provider turn and settles it once
    // when the coordinator reloads the durable run.
    runtime.evict_agent_turn_on_next_load();
    reconcile(&db, &runtime, NOW).await;
    assert_eq!(
        db.agent_turn_run(&first_key)
            .await
            .expect("load settled run")
            .expect("settled run")
            .status,
        AgentTurnRunStatus::Failed
    );

    // Seeing the failed run, the coordinator retries the review rather than
    // restarting the dead turn: no new turn starts for the same attempt.
    assert_eq!(runtime.start_count(), 1);
    assert_eq!(
        load(&fixture, &db).await.transition.execution_state,
        TaskBoardExecutionState::RetryWait
    );

    // Once the retry is due, the review resumes on a fresh attempt that starts
    // exactly one new turn.
    for _ in 0..8 {
        if runtime.start_count() == 2 {
            break;
        }
        reconcile(&db, &runtime, RETRY_AT).await;
    }
    let execution = load(&fixture, &db).await;
    assert_eq!(execution.attempts.len(), 2);
    assert_eq!(runtime.start_count(), 2);
    let second_key = execution.attempts[1].idempotency_key.clone();
    assert_ne!(second_key, first_key);
    assert_eq!(execution.attempts[1].state, TaskBoardAttemptState::Running);
    assert_eq!(
        db.agent_turn_run(&second_key)
            .await
            .expect("load resumed run")
            .expect("resumed run")
            .status,
        AgentTurnRunStatus::Running
    );
    // The original run stays terminal - settled exactly once.
    assert_eq!(
        db.agent_turn_run(&first_key)
            .await
            .expect("load original run")
            .expect("original run")
            .status,
        AgentTurnRunStatus::Failed
    );
}
