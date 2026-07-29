use super::read_only_start_revision_tests::{
    admission_state_counts, claimed_read_only_dispatch, claimed_read_only_dispatch_without_policy,
    intent_status,
};
use super::settle_claimed_task_board_worker;
use super::test_support::{codex_snapshot, seed_session};
use crate::daemon::protocol::CodexRunStatus;
use crate::task_board::{
    TaskBoardAttemptState, TaskBoardExecutionAttemptCas, TaskBoardExecutionState,
    TaskBoardPolicyLimit, TaskBoardPolicyScope, TaskBoardTerminalOutcome,
    TaskBoardTerminalOutcomeKind, TaskBoardWorkflowExecutionCas,
    TaskBoardWorkflowExecutionCasOutcome,
};

#[tokio::test]
async fn confirmed_local_start_atomically_completes_prepared_admission() {
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
    let execution = select_first_local_target(&db, execution_id).await;
    let current_attempt = execution.attempts.first().expect("first attempt");
    let mut claimed_attempt = current_attempt.clone();
    claimed_attempt.state = TaskBoardAttemptState::Running;
    claimed_attempt.updated_at = crate::daemon::db::utc_now();
    db.claim_task_board_workflow_side_effect(
        &TaskBoardWorkflowExecutionCas::from(&execution),
        &TaskBoardExecutionAttemptCas::from(current_attempt),
        &claimed_attempt,
        &claimed_attempt.updated_at,
    )
    .await
    .expect("claim local target")
    .expect("new local target claim");
    let mut run = codex_snapshot(CodexRunStatus::Running, &claim.applied.session_id);
    run.run_id = claimed_attempt.idempotency_key.clone();
    run.board_item_id = Some(claim.applied.board_item_id.clone());
    run.workflow_execution_id = Some(execution_id.into());
    db.save_codex_run(&run)
        .await
        .expect("persist confirmed local run");

    assert!(
        db.complete_task_board_workflow_dispatch_start(execution_id)
            .await
            .expect("complete first local start")
    );
    assert!(
        !db.complete_task_board_workflow_dispatch_start(execution_id)
            .await
            .expect("repeat local start completion")
    );
    assert_eq!(intent_status(&db, &claim.intent_id).await, "completed");
    assert_eq!(admission_state_counts(&db, &claim.intent_id).await, (0, 1));
}

#[tokio::test]
async fn unconfigured_start_authorization_survives_policy_enablement() {
    let (state, mut claim, _worktree) = claimed_read_only_dispatch_without_policy().await;
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
    let frozen: (Option<String>, Option<i64>) = sqlx::query_as(
        "SELECT start_admission_outcome, start_admission_settings_revision
         FROM task_board_dispatch_intents WHERE intent_id = ?1",
    )
    .bind(&claim.intent_id)
    .fetch_one(db.pool())
    .await
    .expect("load frozen unconfigured admission");
    assert_eq!(frozen.0.as_deref(), Some("unconfigured"));
    assert!(frozen.1.is_some_and(|revision| revision > 0));

    set_concurrency_policy(&db, Some(1)).await;
    assert!(
        db.complete_task_board_workflow_dispatch_start(execution_id)
            .await
            .expect("complete frozen unconfigured start")
    );
    assert!(
        !db.complete_task_board_workflow_dispatch_start(execution_id)
            .await
            .expect("replay completed unconfigured start")
    );
    assert_eq!(intent_status(&db, &claim.intent_id).await, "completed");
    assert_eq!(admission_state_counts(&db, &claim.intent_id).await, (0, 0));
}

#[tokio::test]
async fn configured_start_rejects_missing_frozen_admission_evidence() {
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
    sqlx::query("DELETE FROM task_board_dispatch_admission_ledger WHERE intent_id = ?1")
        .bind(&claim.intent_id)
        .execute(db.pool())
        .await
        .expect("remove frozen ledger evidence");
    sqlx::query("DELETE FROM task_board_dispatch_admission_decisions WHERE intent_id = ?1")
        .bind(&claim.intent_id)
        .execute(db.pool())
        .await
        .expect("remove frozen decision evidence");

    let error = db
        .complete_task_board_workflow_dispatch_start(execution_id)
        .await
        .expect_err("missing configured evidence must fail closed");
    assert!(
        error
            .to_string()
            .contains("no exact frozen admission authorization")
    );
    assert_eq!(
        intent_status(&db, &claim.intent_id).await,
        "workflow_prepared"
    );
}

#[tokio::test]
async fn expired_first_start_reservation_is_reevaluated_before_local_target() {
    let (state, mut claim, _worktree) = claimed_read_only_dispatch().await;
    let db = state.async_db.get().cloned().expect("test async db");
    seed_session(&db, &claim.applied.session_id).await;
    settle_claimed_task_board_worker(&state, &db, &mut claim)
        .await
        .expect("prepare workflow dispatch");
    sqlx::query(
        "UPDATE task_board_dispatch_admission_ledger
         SET reserved_at = '1999-01-01T00:00:00Z',
             expires_at = '2000-01-01T00:00:00Z'
         WHERE intent_id = ?1 AND state = 'reserved'",
    )
    .bind(&claim.intent_id)
    .execute(db.pool())
    .await
    .expect("expire admission reservation");
    let execution_id = claim
        .applied
        .item
        .workflow
        .execution_id
        .as_deref()
        .expect("workflow execution id");
    let execution = select_first_local_target(&db, execution_id).await;
    let current_attempt = execution.attempts.first().expect("first attempt");
    let mut claimed_attempt = current_attempt.clone();
    claimed_attempt.state = TaskBoardAttemptState::Running;
    claimed_attempt.updated_at = crate::daemon::db::utc_now();

    let claimed = db
        .claim_task_board_workflow_side_effect(
            &TaskBoardWorkflowExecutionCas::from(&execution),
            &TaskBoardExecutionAttemptCas::from(current_attempt),
            &claimed_attempt,
            &claimed_attempt.updated_at,
        )
        .await
        .expect("reevaluate expired reservation")
        .expect("fresh admission permits local target");

    assert_eq!(claimed.state, TaskBoardAttemptState::Running);
    let updated = db
        .task_board_workflow_execution(execution_id)
        .await
        .expect("reload execution")
        .expect("retained execution");
    assert!(updated.ownership.host_id.is_none());
    assert_eq!(
        updated
            .ownership
            .resources
            .get("execution_target")
            .map(String::as_str),
        Some("local")
    );
    assert_eq!(admission_state_counts(&db, &claim.intent_id).await, (1, 0));
    let runs: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM codex_runs")
        .fetch_one(db.pool())
        .await
        .expect("count local starts");
    assert_eq!(runs, 0);
}

#[tokio::test]
async fn blocked_expired_first_start_settles_durably_without_io() {
    let (state, mut claim, _worktree) = claimed_read_only_dispatch().await;
    let db = state.async_db.get().cloned().expect("test async db");
    seed_session(&db, &claim.applied.session_id).await;
    settle_claimed_task_board_worker(&state, &db, &mut claim)
        .await
        .expect("prepare workflow dispatch");
    expire_admission(&db, &claim.intent_id).await;
    install_invalid_current_policy(&db).await;
    let execution_id = claim
        .applied
        .item
        .workflow
        .execution_id
        .as_deref()
        .expect("workflow execution id");
    let execution = select_first_local_target(&db, execution_id).await;
    let current_attempt = execution.attempts.first().expect("first attempt");
    let mut claimed_attempt = current_attempt.clone();
    claimed_attempt.state = TaskBoardAttemptState::Running;
    claimed_attempt.updated_at = crate::daemon::db::utc_now();

    assert!(
        db.claim_task_board_workflow_side_effect(
            &TaskBoardWorkflowExecutionCas::from(&execution),
            &TaskBoardExecutionAttemptCas::from(current_attempt),
            &claimed_attempt,
            &claimed_attempt.updated_at,
        )
        .await
        .expect("settle blocked first start")
        .is_none()
    );
    let stopped = db
        .task_board_workflow_execution(execution_id)
        .await
        .expect("reload execution")
        .expect("retained execution");
    assert_eq!(
        stopped.transition.execution_state,
        TaskBoardExecutionState::HumanRequired
    );
    assert_eq!(stopped.attempts[0].state, TaskBoardAttemptState::Cancelled);
    assert_eq!(intent_status(&db, &claim.intent_id).await, "failed");
    assert_eq!(admission_state_counts(&db, &claim.intent_id).await, (0, 0));
    let runs: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM codex_runs")
        .fetch_one(db.pool())
        .await
        .expect("count local starts");
    assert_eq!(runs, 0);
}

#[tokio::test]
async fn terminal_before_first_target_closes_prepared_dispatch_and_reservation() {
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
    let current = db
        .task_board_workflow_execution(execution_id)
        .await
        .expect("load execution")
        .expect("prepared execution");
    let ledger_rows_before: i64 = sqlx::query_scalar(
        "SELECT COUNT(*) FROM task_board_dispatch_admission_ledger WHERE intent_id = ?1",
    )
    .bind(&claim.intent_id)
    .fetch_one(db.pool())
    .await
    .expect("count prepared admission rows");
    let mut terminal = current.clone();
    terminal.transition.execution_state = crate::task_board::TaskBoardExecutionState::HumanRequired;
    terminal.blocked_reason = Some("local_start_exhausted".into());
    terminal.updated_at = crate::daemon::db::utc_now();
    terminal.artifacts.terminal_outcome = Some(TaskBoardTerminalOutcome {
        kind: TaskBoardTerminalOutcomeKind::HumanRequired,
        summary: "local start retries exhausted".into(),
        recorded_at: terminal.updated_at.clone(),
    });
    assert!(matches!(
        db.compare_and_set_task_board_workflow_execution(
            &TaskBoardWorkflowExecutionCas::from(&current),
            &terminal,
        )
        .await
        .expect("make execution terminal"),
        TaskBoardWorkflowExecutionCasOutcome::Updated(_)
    ));

    let first = db
        .project_task_board_read_only_workflow_terminal(execution_id)
        .await
        .expect("project terminal workflow");
    let second = db
        .project_task_board_read_only_workflow_terminal(execution_id)
        .await
        .expect("repeat terminal projection");

    assert!(first.admission_released);
    assert!(!second.admission_released);
    assert_eq!(intent_status(&db, &claim.intent_id).await, "failed");
    assert_eq!(admission_state_counts(&db, &claim.intent_id).await, (0, 0));
    let released: i64 = sqlx::query_scalar(
        "SELECT COUNT(*) FROM task_board_dispatch_admission_ledger
         WHERE intent_id = ?1 AND state = 'released'",
    )
    .bind(&claim.intent_id)
    .fetch_one(db.pool())
    .await
    .expect("count released admission rows");
    assert_eq!(released, ledger_rows_before);
}

async fn expire_admission(db: &crate::daemon::db::AsyncDaemonDb, intent_id: &str) {
    sqlx::query(
        "UPDATE task_board_dispatch_admission_ledger
         SET reserved_at = '1999-01-01T00:00:00Z',
             expires_at = '2000-01-01T00:00:00Z'
         WHERE intent_id = ?1 AND state = 'reserved'",
    )
    .bind(intent_id)
    .execute(db.pool())
    .await
    .expect("expire admission reservation");
}

async fn install_invalid_current_policy(db: &crate::daemon::db::AsyncDaemonDb) {
    let snapshot = db
        .task_board_orchestrator_settings_snapshot()
        .await
        .expect("load orchestrator settings");
    let mut settings = snapshot.settings;
    settings.admission_policy.limits = vec![TaskBoardPolicyLimit::Concurrency {
        scope: TaskBoardPolicyScope::Global,
        limit: 0,
        reservation: 1,
    }];
    sqlx::query(
        "UPDATE task_board_orchestrator_settings SET settings_json = ?1 WHERE singleton = 1",
    )
    .bind(serde_json::to_string(&settings).expect("encode invalid current policy"))
    .execute(db.pool())
    .await
    .expect("install invalid current policy without revision drift");
}

/// Selects the local target and reloads, so a first start's side-effect claim finds its target
/// (a targetless Preparing attempt cannot claim local runtime).
pub(super) async fn select_first_local_target(
    db: &crate::daemon::db::AsyncDaemonDb,
    execution_id: &str,
) -> crate::task_board::TaskBoardWorkflowExecutionRecord {
    let prepared = db
        .task_board_workflow_execution(execution_id)
        .await
        .expect("load prepared execution")
        .expect("prepared execution");
    let preparing_attempt = prepared.attempts.first().expect("first prepared attempt");
    assert!(
        db.select_task_board_local_execution_target(
            &TaskBoardWorkflowExecutionCas::from(&prepared),
            &TaskBoardExecutionAttemptCas::from(preparing_attempt),
            &crate::daemon::db::utc_now(),
        )
        .await
        .expect("select local target"),
        "first start must select the local target before its side effect",
    );
    db.task_board_workflow_execution(execution_id)
        .await
        .expect("reload selected execution")
        .expect("selected execution")
}

pub(super) async fn claim_local_target_and_start(
    db: &crate::daemon::db::AsyncDaemonDb,
    claim: &crate::daemon::db::ClaimedTaskBoardDispatch,
    execution_id: &str,
) {
    let execution = select_first_local_target(db, execution_id).await;
    let current_attempt = execution.attempts.first().expect("first attempt");
    let mut claimed_attempt = current_attempt.clone();
    claimed_attempt.state = TaskBoardAttemptState::Running;
    claimed_attempt.updated_at = crate::daemon::db::utc_now();
    db.claim_task_board_workflow_side_effect(
        &TaskBoardWorkflowExecutionCas::from(&execution),
        &TaskBoardExecutionAttemptCas::from(current_attempt),
        &claimed_attempt,
        &claimed_attempt.updated_at,
    )
    .await
    .expect("claim local target")
    .expect("new local target claim");
    let mut run = codex_snapshot(CodexRunStatus::Running, &claim.applied.session_id);
    run.run_id = claimed_attempt.idempotency_key;
    run.board_item_id = Some(claim.applied.board_item_id.clone());
    run.workflow_execution_id = Some(execution_id.into());
    db.save_codex_run(&run)
        .await
        .expect("persist confirmed local run");
}

async fn set_concurrency_policy(db: &crate::daemon::db::AsyncDaemonDb, limit: Option<u64>) {
    let mut settings = db
        .task_board_orchestrator_settings()
        .await
        .expect("load orchestrator settings");
    settings.admission_policy.limits = limit.map_or_else(Vec::new, |limit| {
        vec![TaskBoardPolicyLimit::Concurrency {
            scope: TaskBoardPolicyScope::Global,
            limit,
            reservation: 1,
        }]
    });
    db.replace_task_board_orchestrator_settings(&settings)
        .await
        .expect("replace admission policy");
}
