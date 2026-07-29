use std::path::PathBuf;
use std::sync::{Arc, Mutex, OnceLock};

use tokio::sync::broadcast;

use crate::daemon::agent_tui::{
    ActiveAgentTui, AgentTuiManagerHandle, AgentTuiStartRequest, AgentTuiStatus,
};
use crate::daemon::db::DaemonDb;
use crate::session::service as session_service;
use crate::session::types::SessionRole;

use super::support::sample_snapshot;

const SESSION_A: &str = "5d48fa82-b07a-5269-a876-9c8058399fd8";
const SESSION_B: &str = "7dc03f87-fd5b-57d7-bca7-6fa4f68f74f3";
const TUI_ID: &str = "agent-tui-durable-identity";

#[test]
fn start_with_id_returns_active_snapshot_for_same_session() {
    let (manager, expected) = manager_with_active_snapshot();

    let actual = manager
        .start_with_id(SESSION_A, &start_request(), TUI_ID.to_string())
        .expect("same-session durable retry");

    assert_eq!(actual, expected);
}

#[test]
fn start_with_id_rejects_active_identity_from_different_session() {
    let (manager, expected) = manager_with_active_snapshot();

    let error = manager
        .start_with_id(SESSION_B, &start_request(), TUI_ID.to_string())
        .expect_err("cross-session durable identity must conflict");

    assert_eq!(error.code(), "KSRCLI092");
    let message = error.to_string();
    assert!(message.contains(TUI_ID));
    assert!(message.contains(SESSION_A));
    assert!(message.contains(SESSION_B));
    let persisted = manager
        .load_snapshot(TUI_ID)
        .expect("original snapshot remains persisted");
    assert_eq!(persisted, expected);
    assert_eq!(persisted.status, AgentTuiStatus::Running);
}

fn manager_with_active_snapshot() -> (AgentTuiManagerHandle, super::super::AgentTuiSnapshot) {
    let db = DaemonDb::open_in_memory().expect("open db");
    let project = crate::daemon::index::DiscoveredProject {
        project_id: "project-tui-durable-identity".into(),
        name: "project".into(),
        project_dir: Some(PathBuf::from("/tmp/project")),
        repository_root: Some(PathBuf::from("/tmp/project")),
        checkout_id: "checkout-tui-durable-identity".into(),
        checkout_name: "Directory".into(),
        context_root: PathBuf::from("/tmp/context-root"),
        is_worktree: false,
        worktree_name: None,
    };
    db.sync_project(&project).expect("sync project");
    let state = session_service::build_new_session(
        "durable terminal identity",
        "durable terminal identity",
        SESSION_A,
        "claude",
        None,
        "2026-07-11T00:00:00Z",
    );
    db.sync_session(&project.project_id, &state)
        .expect("sync session");
    let snapshot = sample_snapshot(
        TUI_ID,
        SESSION_A,
        "",
        "codex",
        "2026-07-11T00:00:00Z",
        "2026-07-11T00:00:01Z",
    );
    db.save_agent_tui(&snapshot).expect("save active snapshot");
    let db_slot = Arc::new(OnceLock::new());
    db_slot.set(Arc::new(Mutex::new(db))).expect("install db");
    let (sender, _) = broadcast::channel(8);
    let manager = AgentTuiManagerHandle::new(sender, db_slot, true);
    manager
        .active()
        .expect("active map")
        .insert(TUI_ID.to_string(), ActiveAgentTui::new(None));
    (manager, snapshot)
}

fn start_request() -> AgentTuiStartRequest {
    AgentTuiStartRequest {
        runtime: "codex".into(),
        role: SessionRole::Worker,
        fallback_role: None,
        capabilities: Vec::new(),
        name: None,
        prompt: None,
        project_dir: None,
        argv: Vec::new(),
        rows: 24,
        cols: 80,
        persona: None,
        task_id: None,
        board_item_id: None,
        workflow_execution_id: None,
        model: None,
        effort: None,
        allow_custom_model: false,
    }
}
