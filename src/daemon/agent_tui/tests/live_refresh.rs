use std::sync::{Arc, Mutex, OnceLock};

use tokio::sync::broadcast;

use crate::daemon::agent_tui::{
    AgentTuiManagerHandle, AgentTuiSize, AgentTuiSnapshot, AgentTuiStatus,
};
use crate::daemon::db::DaemonDb;
use crate::session::service as session_service;
use crate::session::types::SessionRole;
use crate::workspace::utc_now;

use super::support::{
    WAIT_TIMEOUT, recv_broadcast_events, sample_snapshot, wait_until, with_agent_tui_home,
};

#[test]
fn manager_publishes_terminal_output_without_manual_refresh() {
    let tmp = tempfile::tempdir().expect("tempdir");
    with_agent_tui_home(tmp.path(), || {
        let project_dir = tmp.path().join("project");
        let context_root = tmp.path().join("context-root");
        fs_err::create_dir_all(&project_dir).expect("project dir");
        let db = DaemonDb::open_in_memory().expect("open db");
        let project = crate::daemon::index::DiscoveredProject {
            project_id: "project-tui-live-refresh".into(),
            name: "project".into(),
            project_dir: Some(project_dir.clone()),
            repository_root: Some(project_dir.clone()),
            checkout_id: "checkout-tui-live-refresh".into(),
            checkout_name: "Directory".into(),
            context_root,
            is_worktree: false,
            worktree_name: None,
        };
        db.sync_project(&project).expect("sync project");
        let state = session_service::build_new_session(
            "live refresh tui test",
            "managed tui",
            "sess-tui-live-refresh",
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
                "sess-tui-live-refresh",
                &crate::daemon::agent_tui::AgentTuiStartRequest {
                    runtime: "codex".into(),
                    role: SessionRole::Worker,
                    fallback_role: None,
                    capabilities: vec![],
                    name: Some("Delayed output".into()),
                    prompt: None,
                    project_dir: None,
                    persona: None,
                    argv: vec![
                        "sh".into(),
                        "-c".into(),
                        "sleep 0.2; printf 'agent-ready\\n'; sleep 0.2".into(),
                    ],
                    rows: 30,
                    cols: 120,
                    model: None,
                    effort: None,
                    allow_custom_model: false,
                },
            )
            .expect("start manager TUI");

        let mut updated_snapshot: Option<AgentTuiSnapshot> = None;
        wait_until(WAIT_TIMEOUT, || {
            loop {
                match receiver.try_recv() {
                    Ok(event) if event.event == "agent_tui_updated" => {
                        if let Ok(event_snapshot) =
                            serde_json::from_value::<AgentTuiSnapshot>(event.payload)
                        {
                            if event_snapshot.tui_id == snapshot.tui_id
                                && event_snapshot.screen.text.contains("agent-ready")
                            {
                                updated_snapshot = Some(event_snapshot);
                                return true;
                            }
                        }
                    }
                    Ok(_) => {}
                    Err(tokio::sync::broadcast::error::TryRecvError::Lagged(_)) => {}
                    Err(_) => break,
                }
            }
            false
        });
        let updated_snapshot = updated_snapshot.expect("updated snapshot");
        assert_eq!(updated_snapshot.tui_id, snapshot.tui_id);
        assert!(updated_snapshot.screen.text.contains("agent-ready"));
    });
}

#[test]
fn live_refresh_step_skips_persist_when_db_updated_concurrently() {
    let tmp = tempfile::tempdir().expect("tempdir");
    let project_dir = tmp.path().join("project");
    let context_root = tmp.path().join("context-root");
    fs_err::create_dir_all(&project_dir).expect("project dir");
    let db = DaemonDb::open_in_memory().expect("open db");
    let project = crate::daemon::index::DiscoveredProject {
        project_id: "project-live-refresh".into(),
        name: "project".into(),
        project_dir: Some(project_dir.clone()),
        repository_root: Some(project_dir),
        checkout_id: "checkout-live-refresh".into(),
        checkout_name: "Directory".into(),
        context_root,
        is_worktree: false,
        worktree_name: None,
    };
    db.sync_project(&project).expect("sync project");
    let session_state = session_service::build_new_session(
        "live refresh concurrency",
        "managed tui",
        "sess-live-refresh",
        "claude",
        None,
        &utc_now(),
    );
    db.sync_session(&project.project_id, &session_state)
        .expect("sync session");

    let previous = sample_snapshot(
        "concurrent-live-refresh",
        "sess-live-refresh",
        "agent-live-refresh",
        "codex",
        "2026-04-13T07:00:00Z",
        "2026-04-13T07:00:01Z",
    );
    db.save_agent_tui(&previous)
        .expect("seed previous snapshot");

    let db_slot = Arc::new(OnceLock::new());
    db_slot
        .set(Arc::new(Mutex::new(db)))
        .expect("install test db");
    let (sender, mut receiver) = broadcast::channel(4);
    let manager = AgentTuiManagerHandle::new(sender, Arc::clone(&db_slot), false);

    let mut refreshed = previous.clone();
    refreshed.screen.text = "ready\nlive output".to_string();
    refreshed.updated_at = "2026-04-13T07:00:02Z".to_string();

    let mut concurrent_resize = previous.clone();
    concurrent_resize.size = AgentTuiSize { rows: 48, cols: 80 };
    concurrent_resize.screen.rows = 48;
    concurrent_resize.updated_at = "2026-04-13T07:00:03Z".to_string();
    manager
        .db()
        .expect("manager db")
        .lock()
        .expect("db lock")
        .save_agent_tui(&concurrent_resize)
        .expect("save concurrent resize");

    let skip_status = manager
        .live_refresh_skip_status(&previous.tui_id, &previous.updated_at)
        .expect("live refresh guard");
    if skip_status.is_none() {
        manager
            .persist_refreshed_snapshot(&previous, &refreshed)
            .expect("persist refreshed snapshot");
    }

    assert_eq!(skip_status, Some(AgentTuiStatus::Running));
    assert!(
        receiver.try_recv().is_err(),
        "concurrent resize should suppress stale live-refresh broadcast"
    );
    let persisted = manager
        .load_snapshot(&previous.tui_id)
        .expect("load persisted snapshot");
    assert_eq!(persisted.size, concurrent_resize.size);
    assert_eq!(persisted.updated_at, concurrent_resize.updated_at);
}

#[test]
fn manager_list_prioritizes_leader_tui_over_worker_refresh_order() {
    let db = DaemonDb::open_in_memory().expect("open db");
    let tmp = tempfile::tempdir().expect("tempdir");
    let project_dir = tmp.path().join("project");
    let context_root = tmp.path().join("context-root");
    fs_err::create_dir_all(&project_dir).expect("project dir");
    let project = crate::daemon::index::DiscoveredProject {
        project_id: "project-tui-ordering".into(),
        name: "project".into(),
        project_dir: Some(project_dir.clone()),
        repository_root: Some(project_dir),
        checkout_id: "checkout-tui-ordering".into(),
        checkout_name: "Directory".into(),
        context_root,
        is_worktree: false,
        worktree_name: None,
    };
    db.sync_project(&project).expect("sync project");
    let mut state = session_service::build_new_session(
        "ordering test",
        "ordering",
        "sess-tui-ordering",
        "claude",
        None,
        &utc_now(),
    );
    let worker_id = "codex-worker".to_string();
    state.agents.insert(
        worker_id.clone(),
        crate::session::types::AgentRegistration {
            agent_id: worker_id.clone(),
            name: "Worker".into(),
            runtime: "codex".into(),
            role: SessionRole::Worker,
            capabilities: vec![],
            joined_at: "2026-04-12T09:00:00Z".into(),
            updated_at: "2026-04-12T09:00:00Z".into(),
            status: crate::session::types::AgentStatus::Active,
            agent_session_id: Some("codex-worker-session".into()),
            last_activity_at: Some("2026-04-12T09:00:00Z".into()),
            current_task_id: None,
            runtime_capabilities: crate::agents::runtime::RuntimeCapabilities::default(),
            persona: None,
        },
    );
    db.sync_session(&project.project_id, &state)
        .expect("sync session");

    let leader_id = state.leader_id.expect("leader id");
    db.save_agent_tui(&sample_snapshot(
        "leader-tui",
        &state.session_id,
        &leader_id,
        "claude",
        "2026-04-12T09:00:00Z",
        "2026-04-12T09:01:00Z",
    ))
    .expect("save leader tui");
    db.save_agent_tui(&sample_snapshot(
        "worker-tui",
        &state.session_id,
        &worker_id,
        "codex",
        "2026-04-12T09:02:00Z",
        "2026-04-12T09:05:00Z",
    ))
    .expect("save worker tui");

    let db_slot = Arc::new(OnceLock::new());
    db_slot
        .set(Arc::new(Mutex::new(db)))
        .expect("install test db");
    let (sender, _) = broadcast::channel(4);
    let manager = AgentTuiManagerHandle::new(sender, Arc::clone(&db_slot), false);

    let listed = manager
        .list("sess-tui-ordering")
        .expect("list tuis")
        .tuis
        .into_iter()
        .map(|item| item.tui_id)
        .collect::<Vec<_>>();
    assert_eq!(listed, vec!["leader-tui", "worker-tui"]);
}

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
        crate::session::types::AgentStatus::Disconnected
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
                .map(|agent| agent.status)
                == Some(crate::session::types::AgentStatus::Disconnected)
        });
    });
}
