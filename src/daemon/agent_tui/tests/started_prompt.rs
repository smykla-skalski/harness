//! A terminal agent's prompt is delivered into a PTY, so unlike a Codex run
//! it has no persisted `prompt` column. It is recorded next to the transcript
//! instead, which keeps what the agent ran with recoverable alongside what it
//! did.

use std::sync::{Arc, Mutex, OnceLock};

use tokio::sync::broadcast;

use crate::daemon::agent_tui::{AgentTuiManagerHandle, AgentTuiStartRequest};
use crate::daemon::db::DaemonDb;
use crate::session::service as session_service;
use crate::session::types::SessionRole;
use crate::workspace::utc_now;

use super::support::with_agent_tui_home;

const SESSION_ID: &str = "0d1f9b0e-4b25-5f37-9b0f-9a1a6a4c9e21";

fn start_request(prompt: Option<&str>) -> AgentTuiStartRequest {
    AgentTuiStartRequest {
        runtime: "codex".into(),
        role: SessionRole::Worker,
        fallback_role: None,
        capabilities: Vec::new(),
        name: Some("Prompt recorder".into()),
        prompt: prompt.map(ToString::to_string),
        project_dir: None,
        persona: None,
        task_id: None,
        board_item_id: None,
        workflow_execution_id: None,
        argv: vec!["sh".into(), "-c".into(), "cat".into()],
        rows: 5,
        cols: 40,
        model: None,
        effort: None,
        allow_custom_model: false,
    }
}

fn manager_with_project(root: &std::path::Path) -> AgentTuiManagerHandle {
    let project_dir = root.join("project");
    let context_root = root.join("context-root");
    fs_err::create_dir_all(&project_dir).expect("project dir");
    let db = DaemonDb::open_in_memory().expect("open db");
    let project = crate::daemon::index::DiscoveredProject {
        project_id: "project-tui-prompt".into(),
        name: "project".into(),
        project_dir: Some(project_dir.clone()),
        repository_root: Some(project_dir),
        checkout_id: "checkout-tui-prompt".into(),
        checkout_name: "Directory".into(),
        context_root,
        is_worktree: false,
        worktree_name: None,
    };
    db.sync_project(&project).expect("sync project");
    let state = session_service::build_new_session(
        "prompt recording test",
        "prompt recording",
        SESSION_ID,
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
    AgentTuiManagerHandle::new(broadcast::channel(8).0, db_slot, false)
}

#[test]
fn the_prompt_a_terminal_agent_started_with_is_recorded_beside_its_transcript() {
    let tmp = tempfile::tempdir().expect("tempdir");
    with_agent_tui_home(tmp.path(), || {
        let manager = manager_with_project(tmp.path());
        let prompt = "Work on task-board item 'Ship it'.\n\nBoard item: board-1";

        let snapshot = manager
            .start(SESSION_ID, &start_request(Some(prompt)))
            .expect("start terminal agent");

        let recorded = crate::daemon::agent_tui::recorded_prompt_path(std::path::Path::new(
            &snapshot.transcript_path,
        ));
        assert_eq!(
            fs_err::read_to_string(&recorded).expect("read recorded prompt"),
            prompt
        );
        let _ = manager.stop(&snapshot.tui_id);
    });
}

#[test]
fn a_terminal_agent_started_without_a_prompt_records_nothing() {
    let tmp = tempfile::tempdir().expect("tempdir");
    with_agent_tui_home(tmp.path(), || {
        let manager = manager_with_project(tmp.path());

        let snapshot = manager
            .start(SESSION_ID, &start_request(None))
            .expect("start terminal agent");

        let recorded = crate::daemon::agent_tui::recorded_prompt_path(std::path::Path::new(
            &snapshot.transcript_path,
        ));
        assert!(!recorded.exists(), "no prompt means no recording");
        let _ = manager.stop(&snapshot.tui_id);
    });
}
