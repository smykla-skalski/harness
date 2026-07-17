use std::time::Duration;

use tokio::sync::mpsc;

use crate::daemon::db::AsyncDaemonDb;
use crate::daemon::protocol::CodexRunStatus;
use crate::session::storage as session_storage;
use crate::session::types::{SessionMetrics, SessionState, TaskStatus};
use crate::task_board::dispatch::{
    DispatchLifecycle, DispatchLifecyclePhase, DispatchLifecycleStatus, DispatchLifecycleStep,
};
use crate::task_board::{
    AgentMode, DispatchAppliedTask, TaskBoardItem, TaskBoardStatus, TaskBoardWorkflowStatus,
};

use super::super::worker::CodexRunWorker;
use super::test_support::{
    codex_run_snapshot, controller_with_async_session_state,
    sample_session_state_with_open_task_and_codex_agent, with_isolated_async_harness_env,
};

const SESSION_ID: &str = "eadbcb3e-6ef7-53d2-ad56-0347cb7189fc";
const TASK_ID: &str = "task-1";
const ITEM_ID: &str = "board-admission-recovery";
const WORKER_ID: &str = "codex-run-1";

#[tokio::test(flavor = "multi_thread")]
async fn rate_only_committed_worker_is_included_in_recovery_projection() {
    with_isolated_async_harness_env(|_| async move {
        let (_controller, db, _tempdir) =
            controller_with_async_session_state(bound_in_progress_state()).await;
        let (intent_id, dispatch) = seed_committed_admission(&db, &["rate"]).await;

        let recoveries = db
            .task_board_admission_worker_recoveries()
            .await
            .expect("load worker recovery projection");

        assert_eq!(recoveries.len(), 1);
        let recovery = &recoveries[0];
        assert_eq!(recovery.managed_worker_id, WORKER_ID);
        assert_eq!(recovery.intent_id, intent_id);
        assert_eq!(recovery.item_id, ITEM_ID);
        assert_eq!(recovery.session_id, SESSION_ID);
        assert_eq!(recovery.task_id, TASK_ID);
        assert_eq!(recovery.dispatch, dispatch);
    })
    .await;
}

#[tokio::test(flavor = "multi_thread")]
async fn missing_run_blocks_linked_task_and_board_without_refunding_rate_usage() {
    with_isolated_async_harness_env(|_| async move {
        let (controller, db, tempdir) =
            controller_with_async_session_state(bound_in_progress_state()).await;
        let (intent_id, _) = seed_committed_admission(&db, &["concurrency", "rate"]).await;
        let mut events = controller.state.sender.subscribe();

        controller
            .reconcile_task_board_admission_workers_after_restart()
            .await
            .expect("reconcile missing durable run");

        let resolved = db
            .resolve_session(SESSION_ID)
            .await
            .expect("load recovered session")
            .expect("recovered session");
        assert_blocked_task(&resolved.state);
        let layout =
            session_storage::layout_from_project_dir(&tempdir.path().join("project"), SESSION_ID)
                .expect("session layout");
        let mirrored = session_storage::load_state(&layout)
            .expect("load session mirror")
            .expect("mirrored session");
        assert_blocked_task(&mirrored);
        let board_item = db.task_board_item(ITEM_ID).await.expect("load board item");
        assert_eq!(board_item.status, TaskBoardStatus::Failed);
        assert_eq!(board_item.workflow.status, TaskBoardWorkflowStatus::Failed);
        assert_eq!(
            board_item.workflow.current_step_id.as_deref(),
            Some("blocked")
        );
        assert_eq!(
            ledger_state(&db, &intent_id, "concurrency").await.0,
            "released"
        );
        assert_eq!(
            ledger_state(&db, &intent_id, "rate").await,
            ("committed".into(), None)
        );
        let published = tokio::time::timeout(Duration::from_secs(2), async {
            loop {
                let event = events.recv().await.expect("receive session recovery event");
                if event.session_id.as_deref() == Some(SESSION_ID) {
                    return event;
                }
            }
        })
        .await
        .expect("session recovery broadcast");
        assert!(
            matches!(
                published.event.as_str(),
                "session_updated" | "sessions_updated_delta" | "session_extensions"
            ),
            "unexpected recovery event: {}",
            published.event
        );
    })
    .await;
}

#[tokio::test(flavor = "multi_thread")]
async fn terminal_save_releases_concurrency_before_board_reconciliation() {
    with_isolated_async_harness_env(|_| async move {
        let (controller, db, _tempdir) =
            controller_with_async_session_state(bound_in_progress_state()).await;
        let (intent_id, _) = seed_committed_admission(&db, &["concurrency", "rate"]).await;
        let mut run = codex_run_snapshot(CodexRunStatus::Running);
        run.task_id = Some(TASK_ID.into());
        run.board_item_id = Some(ITEM_ID.into());
        run.session_agent_id = Some("agent-1".into());
        let (_control, control_rx) = mpsc::unbounded_channel();
        let mut worker = CodexRunWorker::new(controller, run, control_rx);

        worker
            .handle_turn_completed(Some("failed"), Some("worker failed".into()))
            .expect("persist and reconcile terminal worker");

        assert_eq!(worker.snapshot.status, CodexRunStatus::Failed);
        let resolved = db
            .resolve_session(SESSION_ID)
            .await
            .expect("load reconciled session")
            .expect("reconciled session");
        assert_eq!(resolved.state.tasks[TASK_ID].status, TaskStatus::Blocked);
        let board_item = db.task_board_item(ITEM_ID).await.expect("load board item");
        assert_eq!(board_item.status, TaskBoardStatus::Failed);
        assert_eq!(
            ledger_state(&db, &intent_id, "concurrency").await.0,
            "released"
        );
        assert_eq!(
            ledger_state(&db, &intent_id, "rate").await,
            ("committed".into(), None)
        );
    })
    .await;
}

fn bound_in_progress_state() -> SessionState {
    let mut state = sample_session_state_with_open_task_and_codex_agent();
    let task = state.tasks.get_mut(TASK_ID).expect("open task");
    task.status = TaskStatus::InProgress;
    task.assigned_to = Some("agent-1".into());
    task.updated_at = "2026-07-17T10:00:01Z".into();
    state
        .agents
        .get_mut("agent-1")
        .expect("Codex agent")
        .current_task_id = Some(TASK_ID.into());
    state.metrics = SessionMetrics::recalculate(&state);
    state
}

fn assert_blocked_task(state: &SessionState) {
    let task = &state.tasks[TASK_ID];
    assert_eq!(task.status, TaskStatus::Blocked);
    assert_eq!(
        task.blocked_reason.as_deref(),
        Some("Codex worker was missing after daemon restart")
    );
    assert!(state.agents["agent-1"].current_task_id.is_none());
}

async fn seed_committed_admission(
    db: &AsyncDaemonDb,
    kinds: &[&str],
) -> (String, DispatchAppliedTask) {
    let item = TaskBoardItem::new(
        ITEM_ID.into(),
        "Admission recovery".into(),
        "Recover the missing worker".into(),
        "2026-07-17T10:00:00Z".into(),
    );
    db.create_task_board_item(item)
        .await
        .expect("create recovery item");
    let dispatch = db
        .link_and_enqueue_task_board_dispatch(ITEM_ID, SESSION_ID, TASK_ID, &applied_lifecycle())
        .await
        .expect("link recovery dispatch");
    let intent_id: String =
        sqlx::query_scalar("SELECT intent_id FROM task_board_dispatch_intents WHERE item_id = ?1")
            .bind(ITEM_ID)
            .fetch_one(db.pool())
            .await
            .expect("load recovery intent");
    db.update_task_board_item(ITEM_ID, |item| {
        item.workflow.current_step_id = Some("worker_running".into());
        Ok(true)
    })
    .await
    .expect("mark worker running");
    sqlx::query(
        "UPDATE task_board_dispatch_intents
         SET status = 'completed', updated_at = ?2, completed_at = ?2
         WHERE intent_id = ?1",
    )
    .bind(&intent_id)
    .bind("2026-07-17T10:00:02Z")
    .execute(db.pool())
    .await
    .expect("complete recovery intent");
    insert_allowed_decision(db, &intent_id).await;
    for kind in kinds {
        insert_committed_ledger(db, &intent_id, kind).await;
    }
    (intent_id, dispatch)
}

async fn insert_allowed_decision(db: &AsyncDaemonDb, intent_id: &str) {
    let item_revision: i64 =
        sqlx::query_scalar("SELECT revision FROM task_board_items WHERE item_id = ?1")
            .bind(ITEM_ID)
            .fetch_one(db.pool())
            .await
            .expect("load item revision");
    let settings_revision: i64 = sqlx::query_scalar(
        "SELECT revision FROM task_board_orchestrator_settings WHERE singleton = 1",
    )
    .fetch_one(db.pool())
    .await
    .expect("load settings revision");
    sqlx::query(
        "INSERT INTO task_board_dispatch_admission_decisions (
            decision_id, intent_id, generation, item_id, item_revision, settings_revision,
            decision, policy_json, context_json, requirements_json, blockers_json,
            launch_profile, evaluated_at, next_available_at, is_current, created_at
         ) VALUES (
            'decision-recovery', ?1, 1, ?2, ?3, ?4,
            'allowed', '{}', '{}', '[]', '[]',
            'workspace_write', ?5, NULL, 1, ?5
         )",
    )
    .bind(intent_id)
    .bind(ITEM_ID)
    .bind(item_revision)
    .bind(settings_revision)
    .bind("2026-07-17T10:00:00Z")
    .execute(db.pool())
    .await
    .expect("insert allowed recovery decision");
}

async fn insert_committed_ledger(db: &AsyncDaemonDb, intent_id: &str, kind: &str) {
    let (window_start, window_end, limit) = match kind {
        "concurrency" => (None, None, 1_i64),
        "rate" => (
            Some("2026-07-17T10:00:00Z"),
            Some("2026-07-17T11:00:00Z"),
            100_i64,
        ),
        other => panic!("unsupported test ledger kind {other}"),
    };
    sqlx::query(
        "INSERT INTO task_board_dispatch_admission_ledger (
            ledger_id, decision_id, decision, intent_id, generation, item_id,
            canonical_key, kind, scope, amount, limit_value,
            window_started_at, window_ends_at, state, managed_worker_id,
            expires_at, reserved_at, committed_at, released_at
         ) VALUES (
            ?1, 'decision-recovery', 'allowed', ?2, 1, ?3,
            ?4, ?5, 'global', 1, ?6,
            ?7, ?8, 'committed', ?9,
            NULL, ?10, ?11, NULL
         )",
    )
    .bind(format!("ledger-{kind}"))
    .bind(intent_id)
    .bind(ITEM_ID)
    .bind(format!("{kind}:global"))
    .bind(kind)
    .bind(limit)
    .bind(window_start)
    .bind(window_end)
    .bind(WORKER_ID)
    .bind("2026-07-17T10:00:00Z")
    .bind("2026-07-17T10:00:01Z")
    .execute(db.pool())
    .await
    .expect("insert committed recovery ledger");
}

async fn ledger_state(db: &AsyncDaemonDb, intent_id: &str, kind: &str) -> (String, Option<String>) {
    sqlx::query_as(
        "SELECT state, released_at FROM task_board_dispatch_admission_ledger
         WHERE intent_id = ?1 AND kind = ?2",
    )
    .bind(intent_id)
    .bind(kind)
    .fetch_one(db.pool())
    .await
    .expect("load recovery ledger state")
}

fn applied_lifecycle() -> DispatchLifecycle {
    DispatchLifecycle {
        worker: lifecycle_step(
            DispatchLifecyclePhase::Worker,
            DispatchLifecycleStatus::SessionTaskLinked,
            Some(AgentMode::Headless),
        ),
        reviewer: lifecycle_step(
            DispatchLifecyclePhase::Reviewer,
            DispatchLifecycleStatus::WaitingForWorkerReview,
            None,
        ),
        evaluator: lifecycle_step(
            DispatchLifecyclePhase::Evaluator,
            DispatchLifecycleStatus::WaitingForReviewCompletion,
            None,
        ),
    }
}

fn lifecycle_step(
    phase: DispatchLifecyclePhase,
    status: DispatchLifecycleStatus,
    mode: Option<AgentMode>,
) -> DispatchLifecycleStep {
    DispatchLifecycleStep {
        phase,
        status,
        mode,
        suggested_persona: None,
        required_consensus: None,
        native_signal: None,
    }
}
