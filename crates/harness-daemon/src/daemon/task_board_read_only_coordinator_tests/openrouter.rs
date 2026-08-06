use crate::daemon::db::{AgentTurnRunStatus, AsyncDaemonDb};
use crate::daemon::protocol::TaskBoardGetItemRequest;
use crate::task_board::{
    TaskBoardAiReviewReportResponse, TaskBoardAiReviewReportStatus, TaskBoardAttemptState,
    TaskBoardExecutionState,
};

use super::fixture::{NOW, RETRY_AT, seed_execution_with_reviewer_runtime};
use super::runtime::FakeReadOnlyRuntime;
use crate::daemon::db::task_board::prelude::*;
use crate::daemon::db_open::AsyncDaemonDbConnect;

#[path = "openrouter/recovery.rs"]
mod recovery;
#[path = "openrouter/support.rs"]
mod support;

use crate::daemon::db::prelude::*;
use crate::daemon::db_handle::AsyncDaemonDbHandle;
use support::{finish_run, load, reconcile};

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
    let db = AsyncDaemonDbHandle(db);
    let store = AsyncDaemonDb::connect(&fixture.test.path)
        .await
        .expect("open runtime store");
    let store = AsyncDaemonDbHandle(store);
    let runtime = FakeReadOnlyRuntime::new([]).with_durable_db(store);

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
    assert!(
        db.codex_run(&attempt_key)
            .await
            .expect("codex run lookup")
            .is_none()
    );
    let reopened = AsyncDaemonDb::connect(&fixture.test.path)
        .await
        .expect("reopen database for ticket report");
    let reopened = AsyncDaemonDbHandle(reopened);
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

    reconcile(&db, &runtime, NOW).await;
    assert_eq!(runtime.start_count(), 1);
}

#[tokio::test]
async fn an_unknown_reviewer_runtime_is_refused_by_name_not_run_as_codex() {
    let fixture = Box::pin(seed_execution_with_reviewer_runtime("or-unknown", "gemini")).await;
    let db = AsyncDaemonDb::connect(&fixture.test.path)
        .await
        .expect("open coordinator database");
    let db = AsyncDaemonDbHandle(db);
    let store = AsyncDaemonDb::connect(&fixture.test.path)
        .await
        .expect("open runtime store");
    let store = AsyncDaemonDbHandle(store);
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
async fn missing_immutable_content_fails_before_agent_work_and_schedules_retry() {
    let fixture = Box::pin(seed_execution_with_reviewer_runtime(
        "or-missing-content",
        "openrouter",
    ))
    .await;
    let db = AsyncDaemonDb::connect(&fixture.test.path)
        .await
        .expect("open coordinator database");
    let db = AsyncDaemonDbHandle(db);
    let store = AsyncDaemonDb::connect(&fixture.test.path)
        .await
        .expect("open runtime store");
    let store = AsyncDaemonDbHandle(store);
    let runtime = FakeReadOnlyRuntime::new([]).with_durable_db(store);
    runtime.fail_immutable_content("exact pull request diff is unavailable");

    reconcile(&db, &runtime, NOW).await;
    reconcile(&db, &runtime, NOW).await;

    let execution = load(&fixture, &db).await;
    assert_eq!(
        execution.transition.execution_state,
        TaskBoardExecutionState::RetryWait
    );
    assert_eq!(
        execution.attempts[0].state,
        TaskBoardAttemptState::RetryWait
    );
    assert_eq!(runtime.start_count(), 0);
    assert_eq!(runtime.immutable_content_load_count(), 1);
    assert!(
        db.agent_turn_run(&execution.attempts[0].idempotency_key)
            .await
            .expect("agent turn lookup")
            .is_none()
    );
}

#[tokio::test]
async fn mismatched_frozen_head_is_rejected_and_retained_before_harvest() {
    let fixture = Box::pin(seed_execution_with_reviewer_runtime(
        "or-head-mismatch",
        "openrouter",
    ))
    .await;
    let db = AsyncDaemonDb::connect(&fixture.test.path)
        .await
        .expect("open coordinator database");
    let db = AsyncDaemonDbHandle(db);
    let store = AsyncDaemonDb::connect(&fixture.test.path)
        .await
        .expect("open runtime store");
    let store = AsyncDaemonDbHandle(store);
    let runtime = FakeReadOnlyRuntime::new([]).with_durable_db(store);

    reconcile(&db, &runtime, NOW).await;
    reconcile(&db, &runtime, NOW).await;
    let run_id = load(&fixture, &db).await.attempts[0]
        .idempotency_key
        .clone();
    let mut run = db
        .agent_turn_run(&run_id)
        .await
        .expect("load agent-turn run")
        .expect("agent-turn run exists");
    run.source_revision = Some("ffffffffffffffffffffffffffffffffffffffff".into());
    run.report = Some("untrusted output from a mismatched source".into());
    db.save_agent_turn_run(&run)
        .await
        .expect("save mismatched agent-turn run");

    reconcile(&db, &runtime, RETRY_AT).await;

    let execution = load(&fixture, &db).await;
    assert_eq!(
        execution.transition.execution_state,
        TaskBoardExecutionState::HumanRequired
    );
    assert_eq!(execution.attempts[0].state, TaskBoardAttemptState::Failed);
    assert_eq!(
        db.agent_turn_run(&run_id)
            .await
            .expect("load rejected run")
            .expect("rejected run")
            .status,
        AgentTurnRunStatus::Failed
    );
    let reports = db
        .task_board_ai_review_reports(&fixture.item_id)
        .await
        .expect("load retained reports");
    assert_eq!(reports.len(), 1);
    assert_eq!(reports[0].status, TaskBoardAiReviewReportStatus::Failed);
    assert_eq!(
        reports[0].partial_output.as_deref(),
        Some("untrusted output from a mismatched source")
    );
    assert!(
        reports[0]
            .terminal_reason
            .as_deref()
            .is_some_and(|reason| reason.contains("frozen workflow attempt binding"))
    );
}

#[tokio::test]
async fn completed_openrouter_review_is_harvested_once_with_structured_findings() {
    let fixture = Box::pin(seed_execution_with_reviewer_runtime(
        "or-completed",
        "openrouter",
    ))
    .await;
    let db = AsyncDaemonDb::connect(&fixture.test.path)
        .await
        .expect("open coordinator database");
    let db = AsyncDaemonDbHandle(db);
    let store = AsyncDaemonDb::connect(&fixture.test.path)
        .await
        .expect("open runtime store");
    let store = AsyncDaemonDbHandle(store);
    let runtime = FakeReadOnlyRuntime::new([]).with_durable_db(store);

    reconcile(&db, &runtime, NOW).await;
    reconcile(&db, &runtime, NOW).await;
    let run_id = load(&fixture, &db).await.attempts[0]
        .idempotency_key
        .clone();
    finish_run(
        &db,
        &run_id,
        AgentTurnRunStatus::Completed,
        Some(
            r#"{"summary":"One actionable defect.","findings":[{"severity":"high","location":{"path":"src/review.rs","line":41},"evidence":"The branch bypasses validation."}]}"#,
        ),
        None,
    )
    .await;

    reconcile(&db, &runtime, RETRY_AT).await;
    reconcile(&db, &runtime, RETRY_AT).await;

    let execution = load(&fixture, &db).await;
    assert_eq!(
        execution.attempts[0].state,
        TaskBoardAttemptState::Completed
    );
    let reports = db
        .task_board_ai_review_reports(&fixture.item_id)
        .await
        .expect("load retained reports");
    assert_eq!(reports.len(), 1);
    assert_eq!(reports[0].status, TaskBoardAiReviewReportStatus::Completed);
    assert_eq!(reports[0].correlation_id, run_id);
    assert_eq!(reports[0].findings.len(), 1);
    assert_eq!(
        reports[0].effective_model.as_deref(),
        Some("deepseek/deepseek-v4-flash")
    );
    assert_eq!(runtime.start_count(), 1);
}

#[tokio::test]
async fn malformed_openrouter_completion_retains_output_and_rejection_reason() {
    let fixture = Box::pin(seed_execution_with_reviewer_runtime(
        "or-invalid",
        "openrouter",
    ))
    .await;
    let db = AsyncDaemonDb::connect(&fixture.test.path)
        .await
        .expect("open coordinator database");
    let db = AsyncDaemonDbHandle(db);
    let store = AsyncDaemonDb::connect(&fixture.test.path)
        .await
        .expect("open runtime store");
    let store = AsyncDaemonDbHandle(store);
    let runtime = FakeReadOnlyRuntime::new([]).with_durable_db(store);

    reconcile(&db, &runtime, NOW).await;
    reconcile(&db, &runtime, NOW).await;
    let run_id = load(&fixture, &db).await.attempts[0]
        .idempotency_key
        .clone();
    finish_run(
        &db,
        &run_id,
        AgentTurnRunStatus::Completed,
        Some(r#"{"summary":"missing findings"}"#),
        None,
    )
    .await;

    reconcile(&db, &runtime, RETRY_AT).await;
    reconcile(&db, &runtime, RETRY_AT).await;

    let execution = load(&fixture, &db).await;
    assert_eq!(
        execution.transition.execution_state,
        TaskBoardExecutionState::HumanRequired
    );
    assert_eq!(execution.attempts[0].state, TaskBoardAttemptState::Failed);
    let reports = db
        .task_board_ai_review_reports(&fixture.item_id)
        .await
        .expect("load retained reports");
    assert_eq!(reports.len(), 1);
    assert_eq!(reports[0].status, TaskBoardAiReviewReportStatus::Failed);
    assert_eq!(
        reports[0].partial_output.as_deref(),
        Some(r#"{"summary":"missing findings"}"#)
    );
    assert!(
        reports[0]
            .terminal_reason
            .as_deref()
            .is_some_and(|reason| reason.contains("invalid"))
    );
    assert_eq!(runtime.start_count(), 1);
}
