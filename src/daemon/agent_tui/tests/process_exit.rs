use std::sync::{Arc, Mutex, OnceLock};

use tokio::sync::broadcast;

use crate::daemon::agent_tui::{AgentTuiManagerHandle, AgentTuiSnapshot, AgentTuiStatus};
use crate::daemon::db::DaemonDb;
use crate::session::service as session_service;
use crate::session::types::SessionRole;
use crate::workspace::utc_now;

use super::support::{
    WAIT_TIMEOUT, recv_broadcast_events, sample_snapshot, wait_until, with_agent_tui_home,
};

#[test]
fn final_tui_snapshot_disconnects_registered_agent_and_broadcasts_session_refresh() {
    let db = DaemonDb::open_in_memory().expect("open db");
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
        "sess-tui-exit",
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
            last_activity_at: Some("2026-04-13T09:00:00Z".into()),
            current_task_id: None,
            runtime_capabilities: crate::agents::runtime::RuntimeCapabilities::default(),
            persona: None,
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
        .load_session_state("sess-tui-exit")
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
        .any(|event| event.event == "sessions_updated");
    let saw_session_updated = follow_up_events.iter().any(|event| {
        event.event == "session_updated" && event.session_id.as_deref() == Some("sess-tui-exit")
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
        let project = crate::daemon::index::DiscoveredProject {
            project_id: "project-tui-child-exit".into(),
            name: "project".into(),
            project_dir: Some(project_dir.clone()),
            repository_root: Some(project_dir.clone()),
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
            "sess-tui-child-exit",
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
                "sess-tui-child-exit",
                &crate::daemon::agent_tui::AgentTuiStartRequest {
                    runtime: "codex".into(),
                    role: SessionRole::Worker,
                    fallback_role: None,
                    capabilities: vec![],
                    name: Some("Fast exit".into()),
                    prompt: None,
                    project_dir: None,
                    persona: None,
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
                .load_session_state("sess-tui-child-exit")
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
                    agent_session_id: Some("joined-worker-session".into()),
                    last_activity_at: Some("2026-04-22T09:00:00Z".into()),
                    current_task_id: None,
                    runtime_capabilities: crate::agents::runtime::RuntimeCapabilities::default(),
                    persona: None,
                },
            );
            db_guard
                .save_session_state(&project.project_id, &state)
                .expect("persist joined agent");
        }

        wait_until(WAIT_TIMEOUT, || {
            manager
                .load_snapshot(&snapshot.tui_id)
                .map(|persisted| persisted.status == AgentTuiStatus::Exited)
                .unwrap_or(false)
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
                .load_session_state("sess-tui-child-exit")
                .expect("load state")
                .expect("state present");
            session_state
                .agents
                .get(&joined_agent_id)
                .is_some_and(|agent| agent.status.is_disconnected())
        });
    });
}
