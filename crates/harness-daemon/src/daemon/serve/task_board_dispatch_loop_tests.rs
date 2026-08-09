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
