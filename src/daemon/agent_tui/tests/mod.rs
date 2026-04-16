mod backend;
mod live_refresh;
mod manager;
mod sandboxed;
mod spawn;
mod support;

use std::path::PathBuf;
use std::sync::{Arc, Mutex, OnceLock};

use tokio::sync::broadcast;

use crate::agents::runtime::{InitialPromptDelivery, runtime_for_name};
use crate::daemon::agent_tui::{
    AgentTuiInput, AgentTuiInputRequest, AgentTuiKey, AgentTuiManagerHandle, AgentTuiResizeRequest,
    AgentTuiStartRequest, AgentTuiStatus,
};
use crate::daemon::db::DaemonDb;
use crate::session::service as session_service;
use crate::session::types::SessionRole;
use crate::workspace::utc_now;

use self::support::{WAIT_TIMEOUT, wait_until};

#[test]
fn manager_starts_registers_steers_and_stops_tui() {
    let tmp = tempfile::tempdir().expect("tempdir");
    let project_dir = tmp.path().join("project");
    let context_root = tmp.path().join("context-root");
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
    let (sender, mut receiver) = broadcast::channel(8);
    let manager = AgentTuiManagerHandle::new(sender, Arc::clone(&db_slot), false);
    let snapshot = manager
        .start(
            "sess-tui-manager",
            &AgentTuiStartRequest {
                runtime: "codex".into(),
                role: SessionRole::Worker,
                fallback_role: None,
                capabilities: vec!["test-harness".into()],
                name: Some("PTY worker".into()),
                prompt: None,
                project_dir: None,
                persona: None,
                argv: vec!["sh".into(), "-c".into(), "printf 'ready\\n'; cat".into()],
                rows: 5,
                cols: 40,
            },
        )
        .expect("start manager TUI");

    assert_eq!(snapshot.status, AgentTuiStatus::Running);
    assert_eq!(snapshot.runtime, "codex");
    assert_eq!(snapshot.argv, vec!["sh", "-c", "printf 'ready\\n'; cat"]);
    assert!(PathBuf::from(&snapshot.transcript_path).exists());
    assert!(PathBuf::from(&snapshot.transcript_path).starts_with(&context_root));
    assert!(
        snapshot.agent_id.is_empty(),
        "agent_id should be empty before join"
    );

    let started_event = receiver.try_recv().expect("started event");
    assert_eq!(started_event.event, "agent_tui_started");
    assert_eq!(
        started_event.session_id.as_deref(),
        Some("sess-tui-manager")
    );
    manager
        .signal_ready(&snapshot.tui_id)
        .expect("signal ready");
    wait_until(WAIT_TIMEOUT, || {
        receiver
            .try_recv()
            .is_ok_and(|event| event.event == "agent_tui_ready")
    });

    {
        let db_guard = db_slot.get().expect("db slot").lock().expect("db lock");
        let state = db_guard
            .load_session_state("sess-tui-manager")
            .expect("load state")
            .expect("state present");
        let has_tui_agent = state.agents.values().any(|agent| {
            agent
                .capabilities
                .iter()
                .any(|capability| capability.starts_with("agent-tui:"))
        });
        assert!(
            !has_tui_agent,
            "no TUI agent should be in session state yet"
        );
    }

    manager
        .input(
            &snapshot.tui_id,
            &AgentTuiInputRequest {
                input: AgentTuiInput::Text {
                    text: "hello from manager".into(),
                },
            },
        )
        .expect("send text");
    manager
        .input(
            &snapshot.tui_id,
            &AgentTuiInputRequest {
                input: AgentTuiInput::Key {
                    key: AgentTuiKey::Enter,
                },
            },
        )
        .expect("send enter");

    wait_until(WAIT_TIMEOUT, || {
        manager
            .get(&snapshot.tui_id)
            .expect("refresh snapshot")
            .screen
            .text
            .contains("hello from manager")
    });

    let resized = manager
        .resize(
            &snapshot.tui_id,
            &AgentTuiResizeRequest { rows: 9, cols: 33 },
        )
        .expect("resize");
    assert_eq!(
        resized.size,
        crate::daemon::agent_tui::AgentTuiSize { rows: 9, cols: 33 }
    );

    let stopped = manager.stop(&snapshot.tui_id).expect("stop");
    assert_eq!(stopped.status, AgentTuiStatus::Stopped);
    let transcript = fs_err::read(&stopped.transcript_path).expect("read transcript file");
    let transcript_text = String::from_utf8_lossy(&transcript);
    assert!(transcript_text.contains("hello from manager"));
    assert_eq!(
        runtime_for_name("codex")
            .expect("codex runtime")
            .initial_prompt_delivery(),
        InitialPromptDelivery::CliPositional,
        "codex should use CliPositional delivery"
    );
}
