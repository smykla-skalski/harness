use std::sync::{Arc, Mutex, OnceLock};

use tokio::sync::broadcast;

use crate::daemon::agent_tui::{AgentTuiManagerHandle, AgentTuiSnapshot, AgentTuiStatus};
use crate::daemon::db::AsyncDaemonDb;
use crate::daemon::db::DaemonDb;
use crate::daemon::db::task_board::work_item_progress::TaskBoardWorkItemReportRequest;
use crate::daemon::db_open::AsyncDaemonDbConnect;
use crate::session::service as session_service;
use crate::session::types::SessionRole;
use crate::workspace::utc_now;

use super::support::{
    WAIT_TIMEOUT, recv_broadcast_events, sample_snapshot, wait_until, with_agent_tui_home,
};
use crate::daemon::db::prelude::*;
use crate::daemon::db::task_board::prelude::{ItemCoreQueries, WorkItemProgressQueries};
use crate::daemon::db_handle::{AsyncDaemonDbHandle, DaemonDbOwnedHandle};
use crate::task_board::{
    AgentMode, TaskBoardItem, TaskBoardStatus, TaskBoardWorkItemState, TaskBoardWorkflowStatus,
};

// `saw_sessions_updated`/`saw_session_updated` deliberately mirror the two
// event names under test (`sessions_updated_delta` and `session_updated`);
// renaming either to look less alike would obscure that correspondence.
#[allow(clippy::similar_names)]
#[test]
fn final_tui_snapshot_disconnects_registered_agent_and_broadcasts_session_refresh() {
    let db = DaemonDb::open_in_memory().expect("open db");
    let db = DaemonDbOwnedHandle(db);
    let tmp = tempfile::tempdir().expect("tempdir");
    let project_dir = tmp.path().join("project");
    let context_root = tmp.path().join("context-root");
    fs_err::create_dir_all(&project_dir).expect("project dir");
    let project = crate::daemon::index::DiscoveredProject {
        project_id: "project-tui-exit".into(),
        name: "project".into(),
        project_dir: Some(project_dir.clone()),
        repository_root: Some(project_dir.clone()),
        checkout_id: "checkout-tui-exit".into(),
        checkout_name: "Directory".into(),
        context_root,
        is_worktree: false,
        worktree_name: None,
    };
    db.sync_project(&project).expect("sync project");

    let mut state = session_service::build_new_session(
        "disconnect test",
        "managed tui exit",
        "3fab77f7-0bbd-50ab-aee2-d584f0bd024d",
        "claude",
        None,
        &utc_now(),
    );
    let worker_id = "codex-worker-exit".to_string();
    state.agents.insert(
        worker_id.clone(),
        crate::session::types::AgentRegistration {
            agent_id: worker_id.clone(),
            name: "Worker".into(),
            runtime: "codex".into(),
            role: SessionRole::Worker,
            capabilities: vec!["agent-tui".into(), "agent-tui:worker-tui-exit".into()],
            joined_at: "2026-04-13T09:00:00Z".into(),
            updated_at: "2026-04-13T09:00:00Z".into(),
            status: crate::session::types::AgentStatus::Active,
            agent_session_id: Some("codex-worker-exit-session".into()),
            managed_agent: None,
            last_activity_at: Some("2026-04-13T09:00:00Z".into()),
            current_task_id: None,
            runtime_capabilities: crate::agents::runtime::RuntimeCapabilities::default(),
            persona: None,
            runtime_session_title: None,
        },
    );
    db.sync_session(&project.project_id, &state)
        .expect("sync session");

    let db_slot = Arc::new(OnceLock::new());
    db_slot
        .set(Arc::new(Mutex::new(db)))
        .expect("install test db");
    let (sender, mut receiver) = broadcast::channel(16);
    let manager = AgentTuiManagerHandle::new(sender, Arc::clone(&db_slot), false);

    let mut exited = sample_snapshot(
        "worker-tui-exit",
        &state.session_id,
        "",
        "codex",
        "2026-04-13T09:00:00Z",
        "2026-04-13T09:01:00Z",
    );
    exited.status = AgentTuiStatus::Exited;
    exited.exit_code = Some(0);
    exited.project_dir = project_dir.display().to_string();

    manager
        .save_and_broadcast("agent_tui_updated", &exited)
        .expect("publish exited snapshot");

    let updated_event = receiver.try_recv().expect("agent tui event");
    assert_eq!(updated_event.event, "agent_tui_updated");
    let updated_snapshot: AgentTuiSnapshot =
        serde_json::from_value(updated_event.payload).expect("decode snapshot");
    assert_eq!(updated_snapshot.agent_id, worker_id);
    assert_eq!(updated_snapshot.status, AgentTuiStatus::Exited);

    let persisted = manager
        .load_snapshot("worker-tui-exit")
        .expect("load persisted snapshot");
    assert_eq!(persisted.agent_id, worker_id);
    assert_eq!(persisted.exit_code, Some(0));

    let db_guard = db_slot.get().expect("db slot").lock().expect("db lock");
    let refreshed_state = db_guard
        .load_session_state("3fab77f7-0bbd-50ab-aee2-d584f0bd024d")
        .expect("load session")
        .expect("session present");
    let worker = refreshed_state
        .agents
        .get(&worker_id)
        .expect("worker present");
    assert_eq!(
        worker.status,
        crate::session::types::AgentStatus::disconnected_unknown()
    );

    let follow_up_events = recv_broadcast_events(&mut receiver, 3, WAIT_TIMEOUT);
    let saw_sessions_updated = follow_up_events
        .iter()
        .any(|event| event.event == "sessions_updated_delta");
    let saw_session_updated = follow_up_events.iter().any(|event| {
        event.event == "session_updated"
            && event.session_id.as_deref() == Some("3fab77f7-0bbd-50ab-aee2-d584f0bd024d")
    });
    assert!(saw_sessions_updated, "expected global session refresh");
    assert!(saw_session_updated, "expected scoped session refresh");
}

#[test]
fn live_refresh_disconnects_joined_agent_when_child_process_exits() {
    let tmp = tempfile::tempdir().expect("tempdir");
    with_agent_tui_home(tmp.path(), || {
        let project_dir = tmp.path().join("project");
        let context_root = tmp.path().join("context-root");
        fs_err::create_dir_all(&project_dir).expect("project dir");
        let db = DaemonDb::open_in_memory().expect("open db");
        let db = DaemonDbOwnedHandle(db);
        let project = crate::daemon::index::DiscoveredProject {
            project_id: "project-tui-child-exit".into(),
            name: "project".into(),
            project_dir: Some(project_dir.clone()),
            repository_root: Some(project_dir),
            checkout_id: "checkout-tui-child-exit".into(),
            checkout_name: "Directory".into(),
            context_root,
            is_worktree: false,
            worktree_name: None,
        };
        db.sync_project(&project).expect("sync project");
        let state = session_service::build_new_session(
            "child exit test",
            "managed tui child exit",
            "4efbea5a-8396-599c-bf47-7bb8872f6612",
            "claude",
            None,
            &utc_now(),
        );
        db.sync_session(&project.project_id, &state)
            .expect("sync session");

        let db_slot = Arc::new(OnceLock::new());
        db_slot
            .set(Arc::new(Mutex::new(db)))
            .expect("install test db");
        let (sender, _receiver) = broadcast::channel(64);
        let manager = AgentTuiManagerHandle::new(sender, Arc::clone(&db_slot), false);

        let snapshot = manager
            .start(
                "4efbea5a-8396-599c-bf47-7bb8872f6612",
                &crate::daemon::agent_tui::AgentTuiStartRequest {
                    runtime: "codex".into(),
                    role: SessionRole::Worker,
                    fallback_role: None,
                    capabilities: vec![],
                    name: Some("Fast exit".into()),
                    prompt: None,
                    project_dir: None,
                    persona: None,
                    task_id: None,
                    board_item_id: None,
                    workflow_execution_id: None,
                    argv: vec![
                        "sh".into(),
                        "-c".into(),
                        "printf 'ready\\n'; sleep 0.1; exit 0".into(),
                    ],
                    rows: 5,
                    cols: 40,
                    model: None,
                    effort: None,
                    allow_custom_model: false,
                },
            )
            .expect("start manager TUI");

        let joined_agent_id = "joined-worker".to_string();
        {
            let db_arc = db_slot.get().expect("db slot");
            let db_guard = db_arc.lock().expect("db lock");
            let mut state = db_guard
                .load_session_state("4efbea5a-8396-599c-bf47-7bb8872f6612")
                .expect("load state")
                .expect("state present");
            state.agents.insert(
                joined_agent_id.clone(),
                crate::session::types::AgentRegistration {
                    agent_id: joined_agent_id.clone(),
                    name: "Joined worker".into(),
                    runtime: "codex".into(),
                    role: SessionRole::Worker,
                    capabilities: vec![format!("agent-tui:{}", snapshot.tui_id)],
                    joined_at: "2026-04-22T09:00:00Z".into(),
                    updated_at: "2026-04-22T09:00:00Z".into(),
                    status: crate::session::types::AgentStatus::Active,
                    agent_session_id: Some("joined-008d974f-c6a9-53e5-a62e-d331367c449a".into()),
                    managed_agent: None,
                    last_activity_at: Some("2026-04-22T09:00:00Z".into()),
                    current_task_id: None,
                    runtime_capabilities: crate::agents::runtime::RuntimeCapabilities::default(),
                    persona: None,
                    runtime_session_title: None,
                },
            );
            db_guard
                .save_session_state(&project.project_id, &state)
                .expect("persist joined agent");
        }

        wait_until(WAIT_TIMEOUT, || {
            manager
                .load_snapshot(&snapshot.tui_id)
                .is_ok_and(|persisted| persisted.status == AgentTuiStatus::Exited)
        });

        let persisted = manager
            .load_snapshot(&snapshot.tui_id)
            .expect("load snapshot");
        assert_eq!(persisted.status, AgentTuiStatus::Exited);
        assert_eq!(persisted.agent_id, joined_agent_id);

        wait_until(WAIT_TIMEOUT, || {
            let db_arc = db_slot.get().expect("db slot");
            let db_guard = db_arc.lock().expect("db lock");
            let session_state = db_guard
                .load_session_state("4efbea5a-8396-599c-bf47-7bb8872f6612")
                .expect("load state")
                .expect("state present");
            session_state
                .agents
                .get(&joined_agent_id)
                .is_some_and(|agent| agent.status.is_disconnected())
        });
    });
}

#[tokio::test(flavor = "multi_thread")]
async fn workspace_terminal_exit_blocks_pending_work_item_progress() {
    let directory = tempfile::tempdir().expect("tempdir");
    let async_db = Arc::new(AsyncDaemonDbHandle(
        AsyncDaemonDb::connect(&directory.path().join("harness.db"))
            .await
            .expect("open async db"),
    ));
    let mut item = TaskBoardItem::new(
        "board-tui-exit".into(),
        "Interactive task".into(),
        "Body".into(),
        "2026-08-08T00:00:00Z".into(),
    );
    item.agent_mode = AgentMode::Interactive;
    item.status = TaskBoardStatus::InProgress;
    item.work_item_id = Some("work-tui-exit".into());
    item.workflow.execution_id = Some("execution-tui-exit".into());
    item.workflow.status = TaskBoardWorkflowStatus::Running;
    async_db
        .create_task_board_item(item)
        .await
        .expect("create item");
    sqlx::query(
        "INSERT INTO task_board_dispatch_intents (
             intent_id, item_id, session_id, work_item_id, workflow_execution_id,
             payload_json, status, available_at, created_at, updated_at, completed_at
         ) VALUES ('dispatch-intent-tui-exit', 'board-tui-exit', '', 'work-tui-exit',
                   'execution-tui-exit', '{}', 'completed', 'now', 'now', 'now', 'now')",
    )
    .execute(async_db.pool())
    .await
    .expect("seed dispatch intent");
    async_db
        .report_task_board_work_item_progress(&TaskBoardWorkItemReportRequest {
            board_item_id: "board-tui-exit".into(),
            work_item_id: "work-tui-exit".into(),
            actor: "worker".into(),
            state: Some(TaskBoardWorkItemState::Running),
            summary: None,
            progress_percent: None,
            blocked_reason: None,
            sequence: None,
        })
        .await
        .expect("seed worker progress");

    let sync_slot = Arc::new(OnceLock::new());
    let async_slot = Arc::new(OnceLock::new());
    async_slot
        .set(Arc::clone(&async_db))
        .expect("install async db");
    let (sender, _) = broadcast::channel(8);
    let manager = AgentTuiManagerHandle::new_with_async_db(sender, sync_slot, async_slot, false);
    let mut exited = sample_snapshot(
        "agent-tui-dispatch-intent-tui-exit",
        "workspace-tui-exit",
        "",
        "codex",
        "2026-08-08T00:00:00Z",
        "2026-08-08T00:01:00Z",
    );
    exited.workspace_id = Some("workspace-tui-exit".into());
    exited.status = AgentTuiStatus::Exited;
    exited.exit_code = Some(0);

    manager
        .reconcile_terminal_agent_state(&exited)
        .expect("reconcile workspace terminal exit");

    let progress = async_db
        .task_board_work_item_progress("board-tui-exit")
        .await
        .expect("read progress")
        .expect("progress exists");
    assert_eq!(progress.state, TaskBoardWorkItemState::Blocked);
    assert!(
        progress
            .blocked_reason
            .as_deref()
            .is_some_and(|reason| reason.contains("before reporting completion"))
    );
}
