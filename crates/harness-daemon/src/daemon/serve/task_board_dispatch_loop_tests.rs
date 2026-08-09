use super::recover_terminal_agent_tui_progress;
use crate::daemon::db::prelude::*;
use crate::daemon::db::task_board::prelude::*;
use crate::daemon::db::task_board::work_item_progress::TaskBoardWorkItemReportRequest;
use crate::daemon::db::{AsyncDaemonDb, TerminalScreenSnapshot};
use crate::daemon::db_handle::AsyncDaemonDbHandle;
use crate::daemon::db_open::AsyncDaemonDbConnect;
use crate::task_board::{
    AgentMode, TaskBoardItem, TaskBoardStatus, TaskBoardWorkItemState, TaskBoardWorkflowStatus,
};
use harness_daemon_managed_agents::{AgentTuiSize, AgentTuiSnapshot, AgentTuiStatus};

#[tokio::test]
async fn restart_replays_terminal_workspace_tui_into_exact_progress() {
    let directory = tempfile::tempdir().expect("tempdir");
    let path = directory.path().join("harness.db");
    let db = AsyncDaemonDbHandle(AsyncDaemonDb::connect(&path).await.expect("open database"));
    seed_running_interactive_progress(&db).await;
    seed_workspace(&db).await;
    db.save_agent_tui(&terminal_workspace_snapshot())
        .await
        .expect("save terminal workspace snapshot");
    drop(db);
    let reopened = AsyncDaemonDbHandle(
        AsyncDaemonDb::connect(&path)
            .await
            .expect("reopen database"),
    );

    recover_terminal_agent_tui_progress(&reopened).await;
    recover_terminal_agent_tui_progress(&reopened).await;

    let progress = reopened
        .task_board_work_item_progress("board-terminal-replay")
        .await
        .expect("read progress")
        .expect("progress exists");
    assert_eq!(progress.state, TaskBoardWorkItemState::Blocked);
    assert_eq!(
        progress.blocked_reason.as_deref(),
        Some("managed terminal agent exited before reporting completion")
    );
    let settlements = reopened
        .pending_task_board_work_item_worker_settlements(10)
        .await
        .expect("load worker settlement debt");
    assert_eq!(settlements.len(), 1);
    assert_eq!(
        settlements[0].worker_id,
        "agent-tui-dispatch-terminal-replay"
    );
}

#[tokio::test]
async fn restart_releases_terminal_workspace_admission_without_rewriting_review_handoff() {
    let directory = tempfile::tempdir().expect("tempdir");
    let path = directory.path().join("harness.db");
    let db = AsyncDaemonDbHandle(AsyncDaemonDb::connect(&path).await.expect("open database"));
    seed_running_interactive_progress(&db).await;
    db.report_task_board_work_item_progress(&TaskBoardWorkItemReportRequest {
        board_item_id: "board-terminal-replay".into(),
        work_item_id: "work-terminal-replay".into(),
        actor: "worker".into(),
        state: Some(TaskBoardWorkItemState::AwaitingReview),
        summary: Some("ready for review".into()),
        progress_percent: None,
        blocked_reason: None,
        sequence: None,
    })
    .await
    .expect("report review handoff");
    seed_workspace(&db).await;
    seed_committed_admission(&db).await;
    db.save_agent_tui(&terminal_workspace_snapshot())
        .await
        .expect("save terminal workspace snapshot");
    drop(db);
    let reopened = AsyncDaemonDbHandle(
        AsyncDaemonDb::connect(&path)
            .await
            .expect("reopen database"),
    );

    recover_terminal_agent_tui_progress(&reopened).await;

    let progress = reopened
        .task_board_work_item_progress("board-terminal-replay")
        .await
        .expect("read progress")
        .expect("progress exists");
    assert_eq!(progress.state, TaskBoardWorkItemState::AwaitingReview);
    assert_eq!(ledger_state(&reopened).await, "released");
}

#[tokio::test]
async fn stale_terminal_histories_do_not_starve_current_restart_recovery() {
    let directory = tempfile::tempdir().expect("tempdir");
    let db = AsyncDaemonDbHandle(
        AsyncDaemonDb::connect(&directory.path().join("harness.db"))
            .await
            .expect("open database"),
    );
    seed_running_interactive_progress(&db).await;
    seed_workspace(&db).await;
    for index in 0..16 {
        seed_stale_terminal_history(&db, index).await;
        seed_review_handoff_history(&db, index).await;
    }
    db.save_agent_tui(&terminal_workspace_snapshot())
        .await
        .expect("save current terminal workspace snapshot");

    recover_terminal_agent_tui_progress(&db).await;

    let progress = db
        .task_board_work_item_progress("board-terminal-replay")
        .await
        .expect("read current progress")
        .expect("current progress exists");
    assert_eq!(progress.state, TaskBoardWorkItemState::Blocked);
}

#[tokio::test]
async fn restart_releases_terminal_admission_for_later_review_states() {
    let directory = tempfile::tempdir().expect("tempdir");
    let db = AsyncDaemonDbHandle(
        AsyncDaemonDb::connect(&directory.path().join("harness.db"))
            .await
            .expect("open database"),
    );
    seed_workspace(&db).await;
    for (index, state) in [
        TaskBoardWorkItemState::InReview,
        TaskBoardWorkItemState::ChangesRequested,
    ]
    .into_iter()
    .enumerate()
    {
        seed_terminal_review_admission(&db, index, state).await;
    }

    recover_terminal_agent_tui_progress(&db).await;

    for (index, state) in [
        TaskBoardWorkItemState::InReview,
        TaskBoardWorkItemState::ChangesRequested,
    ]
    .into_iter()
    .enumerate()
    {
        let item_id = format!("terminal-review-{index}");
        let progress = db
            .task_board_work_item_progress(&item_id)
            .await
            .expect("read review progress")
            .expect("review progress exists");
        assert_eq!(progress.state, state);
        assert_eq!(ledger_state_for(&db, &item_id).await, "released");
    }
}

async fn seed_workspace(db: &AsyncDaemonDbHandle) {
    sqlx::query(
        "INSERT INTO agent_workspaces (
             workspace_id, daemon_id, project_scope_id, checkout_id, source_project_id,
             project_name, checkout_name, project_dir, repository_root, context_root,
             is_worktree, worktree_name, availability, selected_legacy_session_id,
             manifest_digest, shadow_digest, orchestration_authority, created_at, updated_at
         ) VALUES ('workspace-terminal-replay', 'daemon-test', 'project-test', 'checkout-test',
                   'source-project-test', 'Project', 'Checkout', '/tmp/project', '/tmp/project',
                   '/tmp/project', 0, NULL, 'available', NULL, 'manifest', 'shadow',
                   'workspace', '2026-08-08T00:00:00Z', '2026-08-08T00:00:00Z')",
    )
    .execute(db.pool())
    .await
    .expect("seed workspace");
}

async fn seed_running_interactive_progress(db: &AsyncDaemonDbHandle) {
    let mut item = TaskBoardItem::new(
        "board-terminal-replay".into(),
        "Interactive task".into(),
        "Body".into(),
        "2026-08-08T00:00:00Z".into(),
    );
    item.agent_mode = AgentMode::Interactive;
    item.status = TaskBoardStatus::InProgress;
    item.work_item_id = Some("work-terminal-replay".into());
    item.workflow.execution_id = Some("execution-terminal-replay".into());
    item.workflow.status = TaskBoardWorkflowStatus::Running;
    db.create_task_board_item(item).await.expect("create item");
    sqlx::query(
        "INSERT INTO task_board_dispatch_intents (
             intent_id, item_id, session_id, work_item_id, workflow_execution_id,
             payload_json, status, available_at, created_at, updated_at, completed_at
         ) VALUES ('dispatch-terminal-replay', 'board-terminal-replay', '',
                   'work-terminal-replay', 'execution-terminal-replay', '{}', 'completed',
                   'now', 'now', 'now', 'now')",
    )
    .execute(db.pool())
    .await
    .expect("seed dispatch intent");
    db.report_task_board_work_item_progress(&TaskBoardWorkItemReportRequest {
        board_item_id: "board-terminal-replay".into(),
        work_item_id: "work-terminal-replay".into(),
        actor: "worker".into(),
        state: Some(TaskBoardWorkItemState::Running),
        summary: None,
        progress_percent: None,
        blocked_reason: None,
        sequence: None,
    })
    .await
    .expect("seed running progress");
}

async fn seed_committed_admission(db: &AsyncDaemonDbHandle) {
    sqlx::query(
        "INSERT INTO task_board_dispatch_admission_decisions (
             decision_id, intent_id, generation, item_id, item_revision, settings_revision,
             decision, policy_json, context_json, requirements_json, blockers_json,
             launch_profile, evaluated_at, is_current, created_at
         ) VALUES ('decision-terminal-replay', 'dispatch-terminal-replay', 1,
                   'board-terminal-replay', 1, 1, 'allowed', '{}', '{}', '[]', '[]',
                   'workspace_write', '2026-08-08T00:00:00Z', 1,
                   '2026-08-08T00:00:00Z')",
    )
    .execute(db.pool())
    .await
    .expect("seed admission decision");
    sqlx::query(
        "INSERT INTO task_board_dispatch_admission_ledger (
             ledger_id, decision_id, decision, intent_id, generation, item_id,
             canonical_key, kind, scope, amount, limit_value, state, managed_worker_id,
             reserved_at, committed_at
         ) VALUES ('ledger-terminal-replay', 'decision-terminal-replay', 'allowed',
                   'dispatch-terminal-replay', 1, 'board-terminal-replay',
                   'admission:v1:concurrency:6:global:-:-', 'concurrency', 'global', 1, 1,
                   'committed', 'agent-tui-dispatch-terminal-replay',
                   '2026-08-08T00:00:00Z', '2026-08-08T00:00:00Z')",
    )
    .execute(db.pool())
    .await
    .expect("seed committed admission");
}

async fn seed_stale_terminal_history(db: &AsyncDaemonDbHandle, index: usize) {
    let item_id = format!("stale-terminal-{index:02}");
    let stale_work_item_id = format!("stale-work-{index:02}");
    let attempt_id = format!("agent-tui-stale-terminal-{index:02}");
    let mut item = TaskBoardItem::new(
        item_id.clone(),
        "Stale terminal history".into(),
        "Body".into(),
        "2026-08-07T00:00:00Z".into(),
    );
    item.agent_mode = AgentMode::Interactive;
    item.status = TaskBoardStatus::InProgress;
    item.work_item_id = Some(format!("current-work-{index:02}"));
    db.create_task_board_item(item)
        .await
        .expect("create stale-history item");
    sqlx::query(
        "INSERT INTO task_board_work_item_progress (
             item_id, work_item_id, agent_mode, state, attempt_id,
             report_sequence, created_at, updated_at
         ) VALUES (?1, ?2, 'interactive', 'pending', ?3, 0, ?4, ?4)",
    )
    .bind(&item_id)
    .bind(&stale_work_item_id)
    .bind(&attempt_id)
    .bind(format!("2026-08-07T00:{index:02}:00Z"))
    .execute(db.pool())
    .await
    .expect("seed stale progress");
    let mut snapshot = terminal_workspace_snapshot();
    snapshot.tui_id = attempt_id;
    snapshot.updated_at = format!("2026-08-07T00:{index:02}:00Z");
    db.save_agent_tui(&snapshot)
        .await
        .expect("save stale terminal snapshot");
}

async fn seed_review_handoff_history(db: &AsyncDaemonDbHandle, index: usize) {
    let item_id = format!("review-handoff-{index:02}");
    let work_item_id = format!("review-work-{index:02}");
    let attempt_id = format!("agent-tui-review-handoff-{index:02}");
    seed_progress_row(
        db,
        &item_id,
        &work_item_id,
        &attempt_id,
        TaskBoardWorkItemState::AwaitingReview,
        &format!("2026-08-07T01:{index:02}:00Z"),
    )
    .await;
}

async fn seed_terminal_review_admission(
    db: &AsyncDaemonDbHandle,
    index: usize,
    state: TaskBoardWorkItemState,
) {
    let item_id = format!("terminal-review-{index}");
    let work_item_id = format!("terminal-review-work-{index}");
    let intent_id = format!("terminal-review-intent-{index}");
    let attempt_id = format!("agent-tui-{intent_id}");
    seed_progress_row(
        db,
        &item_id,
        &work_item_id,
        &attempt_id,
        state,
        &format!("2026-08-07T02:0{index}:00Z"),
    )
    .await;
    sqlx::query(
        "INSERT INTO task_board_dispatch_intents (
             intent_id, item_id, session_id, work_item_id, workflow_execution_id,
             payload_json, status, available_at, created_at, updated_at, completed_at
         ) VALUES (?1, ?2, '', ?3, ?4, '{}', 'completed', 'now', 'now', 'now', 'now')",
    )
    .bind(&intent_id)
    .bind(&item_id)
    .bind(&work_item_id)
    .bind(format!("terminal-review-execution-{index}"))
    .execute(db.pool())
    .await
    .expect("seed review dispatch intent");
    seed_named_committed_admission(db, &item_id, &intent_id, &attempt_id).await;
}

async fn seed_progress_row(
    db: &AsyncDaemonDbHandle,
    item_id: &str,
    work_item_id: &str,
    attempt_id: &str,
    state: TaskBoardWorkItemState,
    updated_at: &str,
) {
    let mut item = TaskBoardItem::new(
        item_id.into(),
        "Terminal review history".into(),
        "Body".into(),
        updated_at.into(),
    );
    item.agent_mode = AgentMode::Interactive;
    item.status = TaskBoardStatus::InProgress;
    item.work_item_id = Some(work_item_id.into());
    db.create_task_board_item(item)
        .await
        .expect("create review-history item");
    sqlx::query(
        "INSERT INTO task_board_work_item_progress (
             item_id, work_item_id, agent_mode, state, attempt_id,
             report_sequence, created_at, updated_at
         ) VALUES (?1, ?2, 'interactive', ?3, ?4, 1, ?5, ?5)",
    )
    .bind(item_id)
    .bind(work_item_id)
    .bind(state.as_str())
    .bind(attempt_id)
    .bind(updated_at)
    .execute(db.pool())
    .await
    .expect("seed review progress");
    let mut snapshot = terminal_workspace_snapshot();
    snapshot.tui_id = attempt_id.into();
    snapshot.updated_at = updated_at.into();
    db.save_agent_tui(&snapshot)
        .await
        .expect("save terminal review snapshot");
}

async fn seed_named_committed_admission(
    db: &AsyncDaemonDbHandle,
    item_id: &str,
    intent_id: &str,
    attempt_id: &str,
) {
    let decision_id = format!("decision-{item_id}");
    sqlx::query(
        "INSERT INTO task_board_dispatch_admission_decisions (
             decision_id, intent_id, generation, item_id, item_revision, settings_revision,
             decision, policy_json, context_json, requirements_json, blockers_json,
             launch_profile, evaluated_at, is_current, created_at
         ) VALUES (?1, ?2, 1, ?3, 1, 1, 'allowed', '{}', '{}', '[]', '[]',
                   'workspace_write', '2026-08-08T00:00:00Z', 1,
                   '2026-08-08T00:00:00Z')",
    )
    .bind(&decision_id)
    .bind(intent_id)
    .bind(item_id)
    .execute(db.pool())
    .await
    .expect("seed named admission decision");
    sqlx::query(
        "INSERT INTO task_board_dispatch_admission_ledger (
             ledger_id, decision_id, decision, intent_id, generation, item_id,
             canonical_key, kind, scope, amount, limit_value, state, managed_worker_id,
             reserved_at, committed_at
         ) VALUES (?1, ?2, 'allowed', ?3, 1, ?4,
                   'admission:v1:concurrency:6:global:-:-', 'concurrency', 'global', 1, 1,
                   'committed', ?5, '2026-08-08T00:00:00Z', '2026-08-08T00:00:00Z')",
    )
    .bind(format!("ledger-{item_id}"))
    .bind(&decision_id)
    .bind(intent_id)
    .bind(item_id)
    .bind(attempt_id)
    .execute(db.pool())
    .await
    .expect("seed named committed admission");
}

async fn ledger_state(db: &AsyncDaemonDbHandle) -> String {
    sqlx::query_scalar(
        "SELECT state FROM task_board_dispatch_admission_ledger
         WHERE ledger_id = 'ledger-terminal-replay'",
    )
    .fetch_one(db.pool())
    .await
    .expect("read admission state")
}

async fn ledger_state_for(db: &AsyncDaemonDbHandle, item_id: &str) -> String {
    sqlx::query_scalar(
        "SELECT state FROM task_board_dispatch_admission_ledger WHERE ledger_id = ?1",
    )
    .bind(format!("ledger-{item_id}"))
    .fetch_one(db.pool())
    .await
    .expect("read named admission state")
}

fn terminal_workspace_snapshot() -> AgentTuiSnapshot {
    AgentTuiSnapshot {
        tui_id: "agent-tui-dispatch-terminal-replay".into(),
        session_id: "workspace-terminal-replay".into(),
        workspace_id: Some("workspace-terminal-replay".into()),
        agent_id: String::new(),
        runtime: "codex".into(),
        status: AgentTuiStatus::Exited,
        argv: vec!["codex".into()],
        project_dir: "/tmp/project".into(),
        size: AgentTuiSize {
            rows: 30,
            cols: 120,
        },
        screen: TerminalScreenSnapshot {
            rows: 30,
            cols: 120,
            cursor_row: 0,
            cursor_col: 0,
            text: String::new(),
        },
        transcript_path: "/tmp/transcript".into(),
        exit_code: Some(0),
        signal: None,
        error: None,
        created_at: "2026-08-08T00:00:00Z".into(),
        updated_at: "2026-08-08T00:01:00Z".into(),
    }
}
