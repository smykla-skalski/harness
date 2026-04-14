use std::sync::{Arc, Mutex, OnceLock};

use tokio::sync::broadcast;

use crate::daemon::agent_tui::{
    ActiveAgentTui, AgentTuiManagerHandle, AgentTuiSize, AgentTuiSnapshot, AgentTuiStartRequest,
    AgentTuiStatus, TerminalScreenSnapshot,
};
use crate::daemon::db::DaemonDb;
use crate::session::service as session_service;
use crate::session::types::SessionRole;
use crate::workspace::utc_now;

#[test]
fn sandboxed_stop_without_bridge_falls_back_to_local_cleanup() {
    let tmp = tempfile::tempdir().expect("tempdir");
    let project_dir = tmp.path().join("project");
    let daemon_home = tmp.path().join("daemon-home");
    fs_err::create_dir_all(&project_dir).expect("project dir");
    let db = DaemonDb::open_in_memory().expect("open db");
    let project = crate::daemon::index::DiscoveredProject {
        project_id: "project-stop-test".into(),
        name: "project".into(),
        project_dir: Some(project_dir.clone()),
        repository_root: Some(project_dir.clone()),
        checkout_id: "checkout-stop-test".into(),
        checkout_name: "Directory".into(),
        context_root: tmp.path().join("context-root"),
        is_worktree: false,
        worktree_name: None,
    };
    db.sync_project(&project).expect("sync project");
    let session_state = session_service::build_new_session(
        "stop test",
        "stop test",
        "sess-stop-test",
        "claude",
        None,
        &utc_now(),
    );
    db.sync_session(&project.project_id, &session_state)
        .expect("sync session");
    let now = utc_now();

    let snapshot = AgentTuiSnapshot {
        tui_id: "agent-tui-test-stop".into(),
        session_id: "sess-stop-test".into(),
        agent_id: "agent-stop-test".into(),
        runtime: "codex".into(),
        status: AgentTuiStatus::Running,
        argv: vec!["sh".into(), "-c".into(), "printf 'ready\\n'; cat".into()],
        project_dir: tmp.path().display().to_string(),
        size: AgentTuiSize { rows: 24, cols: 80 },
        screen: TerminalScreenSnapshot {
            rows: 24,
            cols: 80,
            cursor_row: 0,
            cursor_col: 0,
            text: String::new(),
        },
        transcript_path: tmp.path().join("transcript.jsonl").display().to_string(),
        exit_code: None,
        signal: None,
        error: None,
        created_at: now.clone(),
        updated_at: now,
    };
    db.save_agent_tui(&snapshot).expect("seed snapshot");

    let db_slot = Arc::new(OnceLock::new());
    db_slot
        .set(Arc::new(Mutex::new(db)))
        .expect("install test db");
    let (sender, mut receiver) = broadcast::channel(8);
    let manager = AgentTuiManagerHandle::new(sender, Arc::clone(&db_slot), true);

    let active = ActiveAgentTui::new(None);
    manager
        .active()
        .expect("active map")
        .insert("agent-tui-test-stop".into(), active);

    let stopped = temp_env::with_vars(
        [(
            "HARNESS_DAEMON_DATA_HOME",
            Some(daemon_home.to_str().expect("utf8 daemon home")),
        )],
        || manager.stop("agent-tui-test-stop"),
    )
    .expect("stop should succeed without bridge");

    assert_eq!(stopped.status, AgentTuiStatus::Stopped);
    assert_eq!(stopped.tui_id, "agent-tui-test-stop");

    let event = receiver.try_recv().expect("stopped event");
    assert_eq!(event.event, "agent_tui_stopped");
}

#[test]
fn sandboxed_start_without_bridge_does_not_join_agent() {
    let tmp = tempfile::tempdir().expect("tempdir");
    let project_dir = tmp.path().join("project");
    let context_root = tmp.path().join("context-root");
    let daemon_home = tmp.path().join("daemon-home");
    fs_err::create_dir_all(&project_dir).expect("project dir");
    let db = DaemonDb::open_in_memory().expect("open db");
    let project = crate::daemon::index::DiscoveredProject {
        project_id: "project-tui-manager".into(),
        name: "project".into(),
        project_dir: Some(project_dir.clone()),
        repository_root: Some(project_dir.clone()),
        checkout_id: "checkout-tui-manager".into(),
        checkout_name: "Directory".into(),
        context_root: context_root.clone(),
        is_worktree: false,
        worktree_name: None,
    };
    db.sync_project(&project).expect("sync project");
    let state = session_service::build_new_session(
        "managed tui test",
        "managed tui",
        "sess-tui-manager",
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
    let (sender, _) = broadcast::channel(8);
    let manager = AgentTuiManagerHandle::new(sender, Arc::clone(&db_slot), true);

    temp_env::with_vars(
        [(
            "HARNESS_DAEMON_DATA_HOME",
            Some(daemon_home.to_str().expect("utf8 daemon home")),
        )],
        || {
            let error = manager
                .start(
                    "sess-tui-manager",
                    &AgentTuiStartRequest {
                        runtime: "copilot".into(),
                        role: SessionRole::Worker,
                        capabilities: vec![],
                        name: Some("Copilot TUI".into()),
                        prompt: Some("hello".into()),
                        project_dir: None,
                        persona: None,
                        argv: vec![],
                        rows: 24,
                        cols: 80,
                    },
                )
                .expect_err("start should fail without bridge");

            assert!(error.message().contains("agent-tui.host-bridge"));
        },
    );

    let db_guard = db_slot.get().expect("db slot").lock().expect("db lock");
    let state = db_guard
        .load_session_state("sess-tui-manager")
        .expect("load state")
        .expect("state present");
    assert!(state.agents.values().all(|agent| {
        agent
            .capabilities
            .iter()
            .all(|capability| capability != "agent-tui")
    }));
}
