use super::read_only_start_revision_tests::{claimed_read_only_dispatch, intent_status};
use super::settle_claimed_task_board_worker;
use super::test_support::seed_session;
use super::workflow_prepared_terminal_tests::claim_local_target_and_start;
use crate::daemon::protocol::CodexRunStatus;
use crate::task_board::{
    TaskBoardAttemptState, TaskBoardExecutionAttemptCas, TaskBoardExecutionAttemptCasOutcome,
    TaskBoardExecutionState, TaskBoardTerminalOutcome, TaskBoardTerminalOutcomeKind,
    TaskBoardWorkflowExecutionCas, TaskBoardWorkflowExecutionCasOutcome,
};

#[tokio::test]
async fn terminal_local_start_charges_prepared_admission_before_release() {
    let (state, mut claim, _worktree) = claimed_read_only_dispatch().await;
    let db = state.async_db.get().cloned().expect("test async db");
    seed_session(&db, &claim.applied.session_id).await;
    settle_claimed_task_board_worker(&state, &db, &mut claim)
        .await
        .expect("prepare workflow dispatch");
    let execution_id = claim
        .applied
        .item
        .workflow
        .execution_id
        .as_deref()
        .expect("workflow execution id");
    claim_local_target_and_start(&db, &claim, execution_id).await;
    terminalize_started_attempt(&db, execution_id).await;

    let projection = db
        .project_task_board_read_only_workflow_terminal(execution_id)
        .await
        .expect("project terminal started workflow");
    assert!(projection.admission_released);
    assert_eq!(intent_status(&db, &claim.intent_id).await, "completed");
    let charged_and_released: i64 = sqlx::query_scalar(
        "SELECT COUNT(*) FROM task_board_dispatch_admission_ledger
         WHERE intent_id = ?1 AND kind = 'concurrency' AND state = 'released'
           AND managed_worker_id = ?2 AND committed_at IS NOT NULL",
    )
    .bind(&claim.intent_id)
    .bind(crate::daemon::db::workflow_owner(execution_id))
    .fetch_one(db.pool())
    .await
    .expect("load terminal admission evidence");
    assert_eq!(charged_and_released, 1);
    assert!(
        !db.complete_task_board_workflow_dispatch_start(execution_id)
            .await
            .expect("start completion already settled by terminal projection")
    );
}

async fn terminalize_started_attempt(db: &crate::daemon::db::AsyncDaemonDb, execution_id: &str) {
    let current = db
        .task_board_workflow_execution(execution_id)
        .await
        .expect("load started execution")
        .expect("started execution");
    let attempt = current.attempts.first().expect("started attempt");
    let now = crate::daemon::db::utc_now();
    let mut run = db
        .codex_run(&attempt.idempotency_key)
        .await
        .expect("load durable started Codex run")
        .expect("durable started Codex run");
    run.status = CodexRunStatus::Cancelled;
    run.error = Some("worker terminalized before dispatch start completion".into());
    run.updated_at.clone_from(&now);
    db.save_codex_run(&run)
        .await
        .expect("persist terminal Codex run evidence");
    let mut terminal = current.clone();
    terminal.transition.execution_state = TaskBoardExecutionState::HumanRequired;
    terminal.blocked_reason = Some("worker_finished_before_admission_completion".into());
    terminal.available_at = None;
    terminal.updated_at = now.clone();
    terminal.artifacts.terminal_outcome = Some(TaskBoardTerminalOutcome {
        kind: TaskBoardTerminalOutcomeKind::HumanRequired,
        summary: "worker terminalized before dispatch start completion".into(),
        recorded_at: now.clone(),
    });
    let mut cancelled = attempt.clone();
    cancelled.state = TaskBoardAttemptState::Cancelled;
    cancelled.available_at = None;
    cancelled.error = Some("worker terminalized before dispatch start completion".into());
    cancelled.completed_at = Some(now.clone());
    cancelled.updated_at = now;
    assert!(matches!(
        db.compare_and_set_task_board_execution_attempt(
            &TaskBoardExecutionAttemptCas::from(attempt),
            &cancelled,
        )
        .await
        .expect("settle admitted side effect before stopping its execution"),
        TaskBoardExecutionAttemptCasOutcome::Updated(_)
    ));

    let settled = db
        .task_board_workflow_execution(execution_id)
        .await
        .expect("reload settled execution")
        .expect("settled execution");
    terminal.attempts.clone_from(&settled.attempts);
    assert!(matches!(
        db.compare_and_set_task_board_workflow_execution(
            &TaskBoardWorkflowExecutionCas::from(&settled),
            &terminal,
        )
        .await
        .expect("stop execution after its side effect settles"),
        TaskBoardWorkflowExecutionCasOutcome::Updated(_)
    ));
}
